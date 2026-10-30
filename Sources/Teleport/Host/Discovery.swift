import Foundation
import Network
import TeleportCore

/// Announces this host on the LAN (Bonjour) so viewers see it by name.
final class BonjourAdvertiser {
    private var listener: NWListener?

    func start(name: String, port: Int, publicKey: String) {
        stop()
        do {
            // A listener on a fixed port we never accept on; Bonjour needs one to advertise.
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port + 4)))
            let txt = NWTXTRecord(["name": name, "port": String(port), "key": String(publicKey.prefix(16)), "v": TeleportVersion.string])
            listener.service = NWListener.Service(name: name, type: Discovery.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state { Log.warn("bonjour advertise failed: \(error)") }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            Log.info("advertising \(Discovery.serviceType) as \(name)")
        } catch {
            Log.warn("bonjour advertise failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// A host found on the LAN or the tailnet, before pairing.
struct DiscoveredHost: Identifiable, Hashable {
    enum Source: String { case lan = "Local network", tailnet = "Tailscale" }
    let name: String
    let address: String
    let port: Int
    let keyPrefix: String
    let source: Source
    var id: String { "\(source.rawValue)|\(address)|\(name)" }
}

/// Finds hosts: Bonjour on the LAN, and Tailscale peers that answer the control endpoint.
@MainActor
final class HostBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var searching = false

    private var browser: NWBrowser?
    private var tailnetTask: Task<Void, Never>?
    private var lanHosts: [String: DiscoveredHost] = [:]
    private var tailnetHosts: [DiscoveredHost] = []

    func start() {
        stop()
        searching = true
        startBonjour()
        tailnetTask = Task { await sweepTailnet() }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        tailnetTask?.cancel()
        tailnetTask = nil
        searching = false
    }

    private func publish() {
        hosts = (Array(lanHosts.values) + tailnetHosts).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Bonjour

    private func startBonjour() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Discovery.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.bonjourResults(results) }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state { Log.warn("bonjour browse failed: \(error)") }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func bonjourResults(_ results: Set<NWBrowser.Result>) {
        var found: [String: DiscoveredHost] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  case let .bonjour(txt) = result.metadata
            else { continue }
            let port = Int(txt.dictionary["port"] ?? "") ?? 7880
            let key = txt.dictionary["key"] ?? ""
            // Resolve the service to an address so the pair sheet can use it directly.
            found[name] = DiscoveredHost(name: txt.dictionary["name"] ?? name, address: "", port: port, keyPrefix: key, source: .lan)
            resolve(result.endpoint, name: name)
        }
        for (name, host) in found where lanHosts[name] == nil { lanHosts[name] = host }
        for name in lanHosts.keys where found[name] == nil { lanHosts.removeValue(forKey: name) }
        publish()
    }

    /// Prefers IPv4: Network.framework otherwise picks an IPv6 link-local address, which is
    /// useless without its interface suffix and means nothing to the person reading it.
    private func resolve(_ endpoint: NWEndpoint, name: String, ipv4Only: Bool = true) {
        let parameters = NWParameters.tcp
        if ipv4Only, let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: break
            case .failed, .waiting:
                connection.stateUpdateHandler = nil
                connection.cancel()
                // No IPv4 route to it (an IPv6-only network): take what there is.
                if ipv4Only { Task { @MainActor in self?.resolve(endpoint, name: name, ipv4Only: false) } }
                return
            default: return
            }
            if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                let address = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                // Link-local IPv6 can't be dialled without its scope; leave the field for the user.
                guard !address.lowercased().hasPrefix("fe80:") else {
                    connection.cancel()
                    return
                }
                Task { @MainActor in
                    guard let self, var entry = self.lanHosts[name] else { return }
                    entry = DiscoveredHost(name: entry.name, address: address, port: entry.port, keyPrefix: entry.keyPrefix, source: .lan)
                    self.lanHosts[name] = entry
                    self.publish()
                }
            }
            connection.cancel()
        }
        connection.start(queue: .global(qos: .utility))
    }

    // MARK: - Tailscale

    private func sweepTailnet() async {
        let peers = TailscalePeers.list()
        guard !peers.isEmpty else { return }
        var found: [DiscoveredHost] = []
        await withTaskGroup(of: DiscoveredHost?.self) { group in
            for peer in peers {
                group.addTask {
                    guard let info = try? await HostClient.info(address: peer.address, port: 7880, timeout: 2) else { return nil }
                    return DiscoveredHost(name: info.name, address: peer.address, port: info.port, keyPrefix: String(info.publicKey.prefix(16)), source: .tailnet)
                }
            }
            for await host in group { if let host { found.append(host) } }
        }
        guard !Task.isCancelled else { return }
        tailnetHosts = found
        publish()
        searching = false
    }
}

/// Reads the tailnet's machines from the Tailscale CLI when it's installed.
enum TailscalePeers {
    struct Peer { let name: String; let address: String }

    static func list() -> [Peer] {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: [String: Any]]
        else { return [] }
        return peers.values.compactMap { peer in
            guard peer["Online"] as? Bool == true,
                  let ips = peer["TailscaleIPs"] as? [String], let ip = ips.first(where: { !$0.contains(":") }) ?? ips.first,
                  let name = peer["HostName"] as? String
            else { return nil }
            return Peer(name: name, address: ip)
        }
    }
}
