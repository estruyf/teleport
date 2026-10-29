import Foundation
import TeleportCore

/// Runs `livekit-server` (the open-source SFU) as a child process on this Mac.
final class LiveKitServer {
    private var process: Process?
    private let config: TeleportConfig

    init(config: TeleportConfig) {
        self.config = config
    }

    var signalURL: String { "ws://127.0.0.1:\(config.port)" }

    func start() async throws {
        guard let binary = locateBinary() else {
            throw HostError("livekit-server not found. Install it with `brew install livekit` or set livekitServerPath in \(TeleportConfig.fileURL.path)")
        }

        // Binds every interface, so LAN and Tailscale peers can reach it.
        // RTC media uses a single UDP port (and a TCP fallback) to keep firewalls simple.
        let yaml = """
        port: \(config.port)
        rtc:
          tcp_port: \(config.port + 1)
          udp_port: \(config.port + 2)
          use_external_ip: false
        keys:
          \(config.apiKey): \(config.apiSecret)
        logging:
          level: warn
        """
        let configURL = TeleportConfig.directory.appendingPathComponent("livekit.yaml")
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        killOrphan()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--config", configURL.path]
        let logURL = TeleportConfig.directory.appendingPathComponent("livekit-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { p in
            Log.error("livekit-server exited with status \(p.terminationStatus); see \(logURL.path)")
        }
        try process.run()
        self.process = process
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        Log.info("livekit-server \(binary) started (pid \(process.processIdentifier)) on port \(config.port)")

        try await waitUntilReady()
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminationHandler = nil
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        try? FileManager.default.removeItem(at: pidFile)
        Log.info("livekit-server stopped")
    }

    private var pidFile: URL { TeleportConfig.directory.appendingPathComponent("livekit.pid") }

    /// A livekit-server left behind by a host that died would hold the ports; stop it first.
    private func killOrphan() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        try? FileManager.default.removeItem(at: pidFile)
        guard kill(pid, 0) == 0 else { return }
        var name = [CChar](repeating: 0, count: 4096)
        proc_name(pid, &name, UInt32(name.count))
        guard String(cString: name).contains("livekit") else { return }
        Log.warn("stopping orphaned livekit-server (pid \(pid))")
        kill(pid, SIGTERM)
        usleep(300_000)
    }

    private func waitUntilReady() async throws {
        let url = URL(string: "http://127.0.0.1:\(config.port)/")!
        for _ in 0 ..< 50 {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw HostError("livekit-server did not come up on port \(config.port)")
    }

    private func locateBinary() -> String? {
        var candidates = ["/opt/homebrew/bin/livekit-server", "/usr/local/bin/livekit-server"]
        if let explicit = config.livekitServerPath { candidates.insert(explicit, at: 0) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "livekit-server")?.path {
            candidates.insert(bundled, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
