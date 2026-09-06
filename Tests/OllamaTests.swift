import XCTest
@testable import Codenotch

final class OllamaTests: XCTestCase {
    private let samplePSJSON = """
    {
      "models": [
        {
          "name": "qwen2.5-coder:7b",
          "model": "qwen2.5-coder:7b",
          "size": 4682455040,
          "size_vram": 4682455040,
          "details": {
            "format": "gguf",
            "family": "qwen2",
            "parameter_size": "7.6B",
            "quantization_level": "Q4_K_M"
          }
        }
      ]
    }
    """

    private let sampleTagsJSON = """
    {
      "models": [
        {
          "name": "qwen2.5-coder:7b",
          "model": "qwen2.5-coder:7b",
          "size": 4682455040
        },
        {
          "name": "llama3.2:3b",
          "model": "llama3.2:3b",
          "size": 2019393152
        }
      ]
    }
    """

    func testParsesRunningAndInstalledModels() throws {
        let ps = try JSONDecoder().decode(OllamaPSResponse.self, from: XCTUnwrap(samplePSJSON.data(using: .utf8)))
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: XCTUnwrap(sampleTagsJSON.data(using: .utf8)))

        let windows = OllamaProvider.buildWindows(ps: ps, tags: tags)
        XCTAssertEqual(windows.count, 2)

        let running = try XCTUnwrap(windows.first { $0.id == "running" })
        XCTAssertEqual(running.customHeadline, "qwen2.5-coder:7b")
        XCTAssertTrue(running.customSummary?.contains("7.6B") == true)

        let library = try XCTUnwrap(windows.first { $0.id == "library" })
        XCTAssertEqual(library.customHeadline, "2 models")
    }

    func testIdleStateWhenNoRunningModels() throws {
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: XCTUnwrap(sampleTagsJSON.data(using: .utf8)))
        let windows = OllamaProvider.buildWindows(ps: nil, tags: tags)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, "library")
    }
}
