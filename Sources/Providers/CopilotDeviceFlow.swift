import Foundation

/// GitHub OAuth Device Flow client for Copilot.
///
/// Uses GitHub's public VS Code Client ID (`Iv1.b507a08c87ecfe98`) with scope `read:user`
/// to request a user verification code and poll for an access token.
struct CopilotDeviceFlow: Sendable {
    static let defaultHost = "github.com"
    private let clientID = "Iv1.b507a08c87ecfe98"
    private let scopes = "read:user"
    private let host: String

    struct DeviceCodeResponse: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String?
        let expiresIn: Int
        let interval: Int

        var verificationURLToOpen: String {
            verificationUriComplete ?? verificationUri
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    struct AccessTokenResponse: Decodable, Sendable {
        let accessToken: String
        let tokenType: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case scope
        }
    }

    struct GitHubUser: Decodable, Sendable {
        let login: String
        let id: Int64?
    }

    init(host: String = defaultHost) {
        self.host = host
    }

    var deviceCodeURL: URL? {
        URL(string: "https://\(host)/login/device/code")
    }

    var accessTokenURL: URL? {
        URL(string: "https://\(host)/login/oauth/access_token")
    }

    func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard let url = deviceCodeURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientID)&scope=\(scopes)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
        guard let url = accessTokenURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        request.httpBody = body.data(using: .utf8)

        var waitInterval = max(interval, 5)

        while true {
            try await Task.sleep(nanoseconds: UInt64(waitInterval) * 1_000_000_000)
            try Task.checkCancellation()

            let (data, _) = try await URLSession.shared.data(for: request)

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String {
                if error == "authorization_pending" {
                    continue
                }
                if error == "slow_down" {
                    waitInterval += 5
                    continue
                }
                if error == "expired_token" {
                    throw URLError(.timedOut)
                }
                throw URLError(.userAuthenticationRequired)
            }

            if let tokenResponse = try? JSONDecoder().decode(AccessTokenResponse.self, from: data) {
                return tokenResponse.accessToken
            }
        }
    }

    func fetchUser(token: String) async throws -> GitHubUser {
        guard let url = URL(string: "https://api.github.com/user") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }
}
