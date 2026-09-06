import Foundation
import os

/// Monitors locally running and installed Ollama models via its HTTP API (`127.0.0.1:11434`).
///
/// Discovers active loaded models (VRAM consumption, parameter size, architecture) and
/// installed model libraries without needing any accounts, tokens, or external network requests.
actor OllamaProvider: UsageProvider {
    nonisolated let id = "ollama"
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollama

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
                  let url = URL(string: host.hasPrefix("http") ? host : "http://\(host)") {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "http://127.0.0.1:11434")!
        }
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.electron.ollama", name: "Ollama")
    }

    nonisolated func forgetCachedCredential() {}

    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(
            label: "Local Instance",
            plan: "Ollama (Offline)",
            source: baseURL.absoluteString,
            manageURL: URL(string: "https://ollama.com")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Query running models first
        let runningURL = baseURL.appendingPathComponent("api/ps")
        var psRequest = URLRequest(url: runningURL)
        psRequest.timeoutInterval = 3

        let psData: Data
        do {
            let (data, response) = try await session.data(for: psRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UsageProviderError.needsAuth
            }
            psData = data
        } catch {
            throw UsageProviderError.needsAuth
        }

        // Query installed models
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        var tagsRequest = URLRequest(url: tagsURL)
        tagsRequest.timeoutInterval = 3
        let tagsData = (try? await session.data(for: tagsRequest).0) ?? Data()

        let psResponse = try? JSONDecoder().decode(OllamaPSResponse.self, from: psData)
        let tagsResponse = try? JSONDecoder().decode(OllamaTagsResponse.self, from: tagsData)

        let windows = Self.buildWindows(ps: psResponse, tags: tagsResponse)
        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: 200)
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id
        )
    }

    static func buildWindows(ps: OllamaPSResponse?, tags: OllamaTagsResponse?) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        let running = ps?.models ?? []
        let installed = tags?.models ?? []

        if let firstRunning = running.first {
            let name = firstRunning.name ?? firstRunning.model ?? "Local Model"
            let vramStr = Self.formatBytes(firstRunning.sizeVRAM ?? firstRunning.size ?? 0)
            let paramStr = firstRunning.details?.parameterSize.map { " · \($0)" } ?? ""

            windows.append(LimitWindow(
                id: "running",
                label: "Active: \(name)",
                usedFraction: 1.0,
                customSummary: "\(vramStr) VRAM\(paramStr)",
                customHeadline: name
            ))
        }

        if !installed.isEmpty {
            let totalDisk = installed.compactMap(\.size).reduce(0, +)
            windows.append(LimitWindow(
                id: "library",
                label: "Installed models",
                remaining: installed.count,
                customSummary: "\(Self.formatBytes(totalDisk)) on local disk",
                customHeadline: "\(installed.count) models"
            ))
        } else if running.isEmpty {
            windows.append(LimitWindow(
                id: "status",
                label: "Ollama status",
                customSummary: "No models currently loaded in memory",
                customHeadline: "Engine ready"
            ))
        }

        return windows
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}

public struct OllamaPSResponse: Codable, Sendable {
    public let models: [OllamaRunningModel]
}

public struct OllamaRunningModel: Codable, Sendable {
    public let name: String?
    public let model: String?
    public let size: Int64?
    public let sizeVRAM: Int64?
    public let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case name, model, size
        case sizeVRAM = "size_vram"
        case details
    }
}

public struct OllamaModelDetails: Codable, Sendable {
    public let format: String?
    public let family: String?
    public let parameterSize: String?
    public let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case format, family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

public struct OllamaTagsResponse: Codable, Sendable {
    public let models: [OllamaInstalledModel]
}

public struct OllamaInstalledModel: Codable, Sendable {
    public let name: String?
    public let model: String?
    public let size: Int64?
}
