import Foundation
import Darwin

public enum SessionPathResolver {
    public static func resolveSessions(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if arguments.count >= 2 {
            for index in 0..<(arguments.count - 1) {
                if arguments[index].caseInsensitiveCompare("--sessions") == .orderedSame,
                   !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return normalize(arguments[index + 1], homeDirectory: homeDirectory)
                }
            }
        }

        let codexHome = environment["CODEX_HOME"].flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        } ?? (homeDirectory as NSString).appendingPathComponent(".codex")

        return (normalize(codexHome, homeDirectory: homeDirectory) as NSString)
            .appendingPathComponent("sessions")
    }

    public static func resolveCodexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let configured = environment["CODEX_HOME"].flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        return normalize(configured ?? (homeDirectory as NSString).appendingPathComponent(".codex"),
                         homeDirectory: homeDirectory)
    }

    public static func ipcSocketCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        temporaryDirectory: String = FileManager.default.temporaryDirectory.path,
        userID: uid_t = getuid()
    ) -> [String] {
        var candidates: [String] = []

        if let explicitSocket = environment["CODEX_IPC_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitSocket.isEmpty {
            candidates.append(normalize(explicitSocket, homeDirectory: homeDirectory))
        }

        // 当前 Codex Desktop 将主 IPC Socket 放在 CODEX_HOME/ipc/ipc.sock。
        let codexHome = resolveCodexHome(environment: environment, homeDirectory: homeDirectory)
        candidates.append((codexHome as NSString).appendingPathComponent("ipc/ipc.sock"))

        // 兼容旧版或不同分发渠道曾使用的临时目录位置。
        let temporaryIPC = (temporaryDirectory as NSString).appendingPathComponent("codex-ipc")
        candidates.append((temporaryIPC as NSString).appendingPathComponent("ipc-\(userID).sock"))
        candidates.append((temporaryIPC as NSString).appendingPathComponent("ipc.sock"))
        candidates.append("/tmp/codex-ipc/ipc-\(userID).sock")
        candidates.append("/tmp/codex-ipc/ipc.sock")

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func normalize(_ rawPath: String, homeDirectory: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if path == "~" {
            path = homeDirectory
        } else if path.hasPrefix("~/") {
            path = (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }

        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
