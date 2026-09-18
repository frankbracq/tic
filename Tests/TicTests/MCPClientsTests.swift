import Testing
@testable import Tic

@Suite("MCP client instructions")
struct MCPClientsTests {
    @Test("every client embeds the live executable path and launches with --mcp")
    func snippetsCarryTheExecutable() {
        let exe = "/Applications/Tic.app/Contents/MacOS/Tic"
        let clients = MCPClients.all(executablePath: exe)
        #expect(clients.contains { $0.name == "Claude Desktop" })
        #expect(clients.contains { $0.name == "Claude Code" })
        for client in clients {
            #expect(client.snippet.contains(exe), "\(client.name) is missing the executable path")
            #expect(client.snippet.contains("--mcp"), "\(client.name) is missing the --mcp flag")
        }
    }

    @Test("file-based clients name a config path; command-based ones don't")
    func installKinds() {
        let clients = MCPClients.all(executablePath: "/x/Tic")
        let claudeDesktop = clients.first { $0.name == "Claude Desktop" }
        #expect(claudeDesktop?.configPath?.contains("claude_desktop_config.json") == true)
        let claudeCode = clients.first { $0.name == "Claude Code" }
        #expect(claudeCode?.configPath == nil)                       // CLI install
        #expect(claudeCode?.snippet.hasPrefix("claude mcp add tic") == true)
    }
}
