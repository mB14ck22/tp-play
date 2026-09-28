import Foundation

// Compiles the exact app transport on macOS; never embeds a credential.
@main struct DiagnosticSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: link-diagnostic-smoke host token-file")
        }
        let token = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for direction in ["download", "upload"] {
            let result = try LinkProbe.run(host: CommandLine.arguments[1], token: token, rate: 3, direction: direction)
            print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
            guard result.sent > 0, result.received > 0, result.rttP95Ms != nil else {
                fatalError("No measured UDP traffic")
            }
            guard let d = result.receiverDiagnostics,
                  d.originalReceiveBufferBytes > 0,
                  d.actualReceiveBufferBytes >= d.originalReceiveBufferBytes,
                  d.activeLoopGapMaxMs >= d.activeLoopGapP95Ms,
                  d.largestReceiveBatch > 0,
                  d.socketOverflowPackets == nil else {
                fatalError("Invalid receiver diagnostics")
            }
        }
    }
}
