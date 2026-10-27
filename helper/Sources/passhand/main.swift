import Foundation

// One binary, several roles:
//   - Chrome starts it as a native messaging host (first argument is the extension origin)
//   - An MCP client (e.g. Claude desktop) starts it as an MCP server ("mcp")
//   - You run it in a terminal to manage saved logins ("add", "list", ...)

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "help"
let rest = Array(arguments.dropFirst(2))

if command.hasPrefix("chrome-extension://") {
    NativeHost.run()
}

switch command {
case "add": CLI.add(rest)
case "auto": CLI.setAuto(rest)
case "list": CLI.list()
case "remove": CLI.remove(rest)
case "doctor": CLI.doctor()
case "mcp": MCPServer.run()
case "install-claude-config": CLI.installClaudeConfig(rest)
case "uninstall-claude-config": CLI.uninstallClaudeConfig()
case "purge": CLI.purge()
default: CLI.help()
}
