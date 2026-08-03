import Foundation
import PasteBuddyCore

private final class PasteBuddyMCPServer {
    func run() async {
        let token = ProcessInfo.processInfo.environment[MCPAuthenticationToken.environmentVariable]
        while let line = readLine() {
            guard let request = line.data(using: .utf8) else { continue }
            guard let token else {
                if let response = errorResponse(for: request, message: "PasteBuddy MCP authentication is not configured.") {
                    write(response)
                }
                continue
            }
            guard let response = await proxy(request, token: token) else { continue }
            write(response)
        }
    }

    private func proxy(_ body: Data, token: String) async -> Data? {
        do {
            guard let tokenData = Data(base64Encoded: token), tokenData.count == 32,
                  let sessionToken = try await authenticateServer(token: tokenData) else {
                return errorResponse(for: body, message: "PasteBuddy MCP server authentication failed.")
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18789/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(sessionToken, forHTTPHeaderField: "X-PasteBuddy-Session")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return errorResponse(for: body, message: "PasteBuddy MCP returned an invalid HTTP response.")
            }
            switch response.statusCode {
            case 200:
                return data
            case 202:
                return nil
            case 401:
                return errorResponse(for: body, message: "PasteBuddy MCP authentication was rejected.")
            default:
                return errorResponse(for: body, message: "PasteBuddy MCP is unavailable (HTTP \(response.statusCode)).")
            }
        } catch {
            return errorResponse(for: body, message: "PasteBuddy MCP is unavailable. Open PasteBuddy and enable Agent Connection.")
        }
    }

    private func authenticateServer(token: Data) async throws -> String? {
        let url = URL(string: "http://127.0.0.1:18789/mcp/auth")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (nonceResponseData, nonceResponse) = try await URLSession.shared.data(for: request)
        guard (nonceResponse as? HTTPURLResponse)?.statusCode == 200,
              let nonceObject = try JSONSerialization.jsonObject(with: nonceResponseData) as? [String: Any],
              let nonceValue = nonceObject["serverNonce"] as? String,
              let nonce = Data(base64Encoded: nonceValue), nonce.count == 32 else { return nil }

        let challenge = try MCPAuthenticationToken.randomChallenge()
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(nonceValue, forHTTPHeaderField: "X-PasteBuddy-Server-Nonce")
        request.setValue(challenge.base64EncodedString(), forHTTPHeaderField: "X-PasteBuddy-Challenge")
        request.setValue(
            MCPAuthenticationToken.clientProof(challenge: nonce + challenge, token: token),
            forHTTPHeaderField: "X-PasteBuddy-Client-Proof"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proof = object["proof"] as? String,
              let sessionToken = object["sessionToken"] as? String,
              let sessionData = Data(base64Encoded: sessionToken), sessionData.count == 32 else { return nil }
        guard MCPAuthenticationToken.constantTimeMatches(
            proof,
            expected: MCPAuthenticationToken.serverProof(
                challenge: nonce + challenge + sessionData,
                token: token
            )
        ) else { return nil }
        return sessionToken
    }

    private func errorResponse(for request: Data, message: String) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let id = object["id"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32_000, "message": message]
        ], options: [.sortedKeys])
    }

    private func write(_ response: Data) {
            FileHandle.standardOutput.write(response)
            FileHandle.standardOutput.write(Data([0x0A]))
    }
}

@main
private struct PasteBuddyMCPMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            handleCommandLine(arguments)
            return
        }

        await PasteBuddyMCPServer().run()
    }

    private static func handleCommandLine(_ arguments: [String]) {
        switch arguments.first {
        case "--help", "-h":
            printUsage()
        case "--list-client-configs":
            print(MCPClientConfigurationTarget.allCases.map(\.rawValue).joined(separator: "\n"))
        case "--print-client-config":
            printClientConfiguration(arguments: Array(arguments.dropFirst()))
        default:
            writeError("Unknown option: \(arguments.first ?? "")")
            printUsage()
            Foundation.exit(2)
        }
    }

    private static func printClientConfiguration(arguments: [String]) {
        guard let clientArgument = arguments.first,
              let target = MCPClientConfigurationTarget(argument: clientArgument) else {
            writeError("Missing or unknown client. Use --list-client-configs to see supported clients.")
            Foundation.exit(2)
        }

        let options = parseOptions(Array(arguments.dropFirst()))
        let guide: MCPClientConfigurationGuide
        if let executablePath = options["executable-path"] {
            guide = MCPClientConfigurationGuideBuilder.packagedGuide(
                for: target,
                executablePath: executablePath
            )
        } else {
            guide = MCPClientConfigurationGuideBuilder.developmentGuide(
                for: target,
                packagePath: options["package-path"] ?? FileManager.default.currentDirectoryPath
            )
        }

        print("# \(guide.target.displayName) PasteBuddy MCP Configuration")
        print("")
        print("Configuration location: \(guide.configurationHint)")
        print("Command: \(guide.command)")
        print("Arguments: \(guide.arguments.isEmpty ? "(none)" : guide.arguments.joined(separator: " "))")
        if let installationCommand = guide.installationCommand {
            print("Install command: \(installationCommand)")
        }
        if let installationURL = guide.installationURL {
            print("Install link: \(installationURL)")
        }
        print("")
        print("```")
        print(guide.configurationSnippet)
        print("```")
        print("")
        print("Notes:")
        for note in guide.setupNotes {
            print("- \(note)")
        }
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[key] = arguments[index + 1]
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }
        return options
    }

    private static func printUsage() {
        print("""
        PasteBuddyMCP

        Usage:
          PasteBuddyMCP
          PasteBuddyMCP --list-client-configs
          PasteBuddyMCP --print-client-config <claude|claude-code|codex|cursor|vscode|windsurf|gemini|opencode|kiro|custom> [--package-path <path>]
          PasteBuddyMCP --print-client-config <client> --executable-path <path-to-PasteBuddyMCP>

        With no arguments, PasteBuddyMCP starts the local stdio MCP server.
        """)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
