import XCTest
@testable import Codenotch

final class MistralTests: XCTestCase {
    private let sampleModelsJSON = """
    {
      "data": [
        {"id": "codestral-latest"},
        {"id": "mistral-large-latest"},
        {"id": "pixtral-12b"}
      ]
    }
    """

    func testParsesCodestralAndModels() throws {
        let data = try XCTUnwrap(sampleModelsJSON.data(using: .utf8))
        let windows = MistralProvider.parseModels(from: data)

        XCTAssertEqual(windows.count, 2)
        let codestral = try XCTUnwrap(windows.first { $0.id == "codestral" })
        XCTAssertEqual(codestral.customHeadline, "Available")

        let catalog = try XCTUnwrap(windows.first { $0.id == "models" })
        XCTAssertEqual(catalog.customHeadline, "3 models")
    }
}
