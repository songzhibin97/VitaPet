import XCTest
@testable import ChatUI

final class MCPSettingsSummaryTests: XCTestCase {
    func testStatusText_returnsNotConfiguredForBlankJSON() {
        XCTAssertEqual(MCPSettingsSummary.statusText(for: "   \n  "), "未配置")
    }

    func testStatusText_returnsConfiguredForNonBlankJSON() {
        XCTAssertEqual(MCPSettingsSummary.statusText(for: "{\"mcpServers\":{}}"), "已配置")
    }

    func testStatusText_returnsInvalidForMalformedJSON() {
        XCTAssertEqual(MCPSettingsSummary.statusText(for: "{\"mcpServers\":"), "配置无效")
    }

    func testDescriptionText_promptsToConfigureWhenBlank() {
        XCTAssertEqual(MCPSettingsSummary.descriptionText(for: ""), "点击设置 MCP Servers")
    }

    func testDescriptionText_promptsToEditWhenConfigured() {
        XCTAssertEqual(MCPSettingsSummary.descriptionText(for: "{\n  \"mcpServers\": {}\n}"), "点击查看或编辑 MCP Servers")
    }

    func testDescriptionText_promptsToFixWhenJSONIsInvalid() {
        XCTAssertEqual(MCPSettingsSummary.descriptionText(for: "{\"mcpServers\":"), "JSON 格式或字段无效，点击修正")
    }
}