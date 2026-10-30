import Foundation
import TeleportCore

/// Runs `livekit-server` (the open-source SFU) as a child process on this Mac.
final class LiveKitServer {
    private var process: Process?
    private let config: TeleportConfig
    /// Called off the main thread when livekit-server exits without being asked to.
    var onUnexpectedExit: (() -> Void)?

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
        process.terminationHandler = { [weak self] p in
            Log.error("livekit-server exited with status \(p.terminationStatus); see \(logURL.path)")
            self?.onUnexpectedExit?()
        }
        try process.run()
        self.process = process
        try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        Log.info("livekit-server \(binary) started (pid \(process.processIdentifier)) on port \(config.port)")

        do {
            try await waitUntilReady(process, logURL: logURL)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminationHandler = nil
        process.terminate()
        // On SIGTERM livekit drains until its rooms are empty, and our own participant is still
        // in there; waiting without a limit hangs the quit. Give it a moment, then kill it.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(50000) }
        if process.isRunning {
            Log.warn("livekit-server did not stop; killing it")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        self.process = nil
        try? FileManager.default.removeItem(at: pidFile)
        Log.info("livekit-server stopped")
    }

    private var pidFile: URL { TeleportConfig.directory.appendingPathComponent("livekit.pid") }

    /// A livekit-server left behind by a host that died would hold the ports, and it still has
    /// the keys it was started with; stop it first. The pid file can be missing or stale, so
    /// also stop any livekit-server listening on our port.
    private func killOrphan() {
        var pids = Set(listeners(onPort: config.port))
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            pids.insert(pid)
        }
        try? FileManager.default.removeItem(at: pidFile)

        let orphans = pids.filter { pid in
            guard kill(pid, 0) == 0 else { return false }
            var name = [CChar](repeating: 0, count: 4096)
            proc_name(pid, &name, UInt32(name.count))
            return String(cString: name).contains("livekit")
        }
        guard !orphans.isEmpty else { return }
        for pid in orphans {
            Log.warn("stopping orphaned livekit-server (pid \(pid))")
            kill(pid, SIGTERM)
        }
        // Like stop(): a draining server can hang on to its rooms, so don't wait forever.
        let deadline = Date().addingTimeInterval(2)
        while orphans.contains(where: { kill($0, 0) == 0 }), Date() < deadline { usleep(50000) }
        for pid in orphans where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        usleep(100_000)
    }

    /// Pids of processes listening on a TCP port.
    private func listeners(onPort port: Int) -> [Int32] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }

    /// Something else answering on the port does not count: only our own process being up does.
    private func waitUntilReady(_ process: Process, logURL: URL) async throws {
        let url = URL(string: "http://127.0.0.1:\(config.port)/")!
        for _ in 0 ..< 50 {
            if !process.isRunning {
                let lastLine = (try? String(contentsOf: logURL, encoding: .utf8))?
                    .split(separator: "\n").last.map(String.init) ?? ""
                throw HostError("livekit-server exited during startup\(lastLine.isEmpty ? "" : ": \(lastLine)") (see \(logURL.path))")
            }
            if let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               listeners(onPort: config.port).contains(process.processIdentifier)
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
