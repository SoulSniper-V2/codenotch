import XCTest
@testable import Codenotch

final class CopilotTests: XCTestCase {
    private let sampleResponse = """
    {
      "quota_reset_date": "2026-10-01T00:00:00Z",
      "quota_snapshots": {
        "premium_interactions": {
          "percent_remaining": 82.5,
          "entitlement": 100,
          "remaining": 82,
          "quota_id": "premium_interactions",
          "unlimited": false
        },
        "chat": {
          "percent_remaining": 95.0,
          "entitlement": 500,
          "remaining": 475,
          "quota_id": "chat",
          "unlimited": false
        }
      }
    }
    """

    func testParsesQuotaWindows() throws {
        let windows = try CopilotUsageParser.windows(fromJSON: sampleResponse)
        XCTAssertEqual(windows.count, 2)

        let premium = try XCTUnwrap(windows.first { $0.id == "premium" })
        XCTAssertEqual(premium.label, "Premium")
        XCTAssertEqual(premium.usedFraction ?? -1, 0.175, accuracy: 0.001)
        XCTAssertEqual(premium.remaining, 82)
        XCTAssertEqual(premium.used, 18)

        let chat = try XCTUnwrap(windows.first { $0.id == "chat" })
        XCTAssertEqual(chat.label, "Chat")
        XCTAssertEqual(chat.usedFraction ?? -1, 0.05, accuracy: 0.001)
        XCTAssertEqual(chat.remaining, 475)
        XCTAssertEqual(chat.used, 25)
    }

    func testUnlimitedQuotaSnapshot() throws {
        let json = """
        {
          "quota_reset_date": "2026-10-01T00:00:00Z",
          "quota_snapshots": {
            "chat": {
              "unlimited": true,
              "quota_id": "chat"
            }
          }
        }
        """
        let windows = try CopilotUsageParser.windows(fromJSON: json)
        XCTAssertEqual(windows.count, 1)
        let chat = try XCTUnwrap(windows.first)
        XCTAssertEqual(chat.customSummary, "Unlimited")
        XCTAssertEqual(chat.customHeadline, "Unlimited")
    }

    func testParsesHostsYAML() {
        let yaml = """
        github.com:
            user: octocat
            oauth_token: mock_oauth_value_for_hosts_yaml_12345
            git_protocol: https
        """
        let cred = CopilotCredentials.parseHostsYAML(yaml)
        XCTAssertNotNil(cred)
        XCTAssertEqual(cred?.token, "mock_oauth_value_for_hosts_yaml_12345")
        XCTAssertEqual(cred?.user, "octocat")
        XCTAssertEqual(cred?.source, "GitHub CLI")
    }

    func testDecodeKeyringBase64Token() {
        let raw = "go-keyring-base64:bW9ja19kZWNvZGVkX3ZhbHVlX25vdF9hX3JlYWxfa2V5XzAwMDAw"
        let decoded = CopilotCredentials.decodeTokenString(raw)
        XCTAssertEqual(decoded, "mock_decoded_value_not_a_real_key_00000")

        let plain = "mock_plain_value_12345"
        XCTAssertEqual(CopilotCredentials.decodeTokenString(plain), "mock_plain_value_12345")

        let invalidKeyring = "go-keyring-something-else"
        XCTAssertNil(CopilotCredentials.decodeTokenString(invalidKeyring))
    }

    func testExtractUsernameFromAccount() {
        XCTAssertEqual(CopilotCredentials.extractUsername(from: "https://github.com:octocat"), "octocat")
        XCTAssertEqual(CopilotCredentials.extractUsername(from: "octocat"), "octocat")
        XCTAssertNil(CopilotCredentials.extractUsername(from: nil))
        XCTAssertNil(CopilotCredentials.extractUsername(from: ""))
    }

    func testParsesQuotaResetDateOnly() throws {
        let json = """
        {
          "quota_reset_date": "2026-10-01",
          "quota_reset_date_utc": "2026-10-01T00:00:00.000Z",
          "quota_snapshots": {
            "premium_interactions": {
              "percent_remaining": 80.5,
              "entitlement": 200,
              "remaining": 161,
              "quota_id": "premium_interactions",
              "unlimited": false
            }
          }
        }
        """
        let windows = try CopilotUsageParser.windows(fromJSON: json)
        XCTAssertEqual(windows.count, 1)
        let premium = try XCTUnwrap(windows.first)
        XCTAssertEqual(premium.label, "Premium")
        XCTAssertNotNil(premium.resetsAt)
        XCTAssertEqual(premium.remaining, 161)
        XCTAssertEqual(premium.used, 39)
    }

    func testDeviceCodeResponseDecoding() throws {
        let json = """
        {
          "device_code": "dev123",
          "user_code": "ABCD-1234",
          "verification_uri": "https://github.com/login/device",
          "verification_uri_complete": "https://github.com/login/device?user_code=ABCD-1234",
          "expires_in": 900,
          "interval": 5
        }
        """
        let data = Data(json.utf8)
        let resp = try JSONDecoder().decode(CopilotDeviceFlow.DeviceCodeResponse.self, from: data)
        XCTAssertEqual(resp.deviceCode, "dev123")
        XCTAssertEqual(resp.userCode, "ABCD-1234")
        XCTAssertEqual(resp.verificationURLToOpen, "https://github.com/login/device?user_code=ABCD-1234")
        XCTAssertEqual(resp.expiresIn, 900)
        XCTAssertEqual(resp.interval, 5)
    }
}
