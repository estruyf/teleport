import Darwin
import Foundation

/// This Mac's hardware address and wake setting, which a host tells viewers so they can wake it.
enum NetworkIdentity {
    /// The first Ethernet or Wi-Fi interface's MAC address (en0, en1, …), as "aa:bb:cc:dd:ee:ff".
    static func macAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let mac = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
                guard link.pointee.sdl_alen == 6 else { return nil }
                return withUnsafeBytes(of: link.pointee.sdl_data) { raw in
                    let start = Int(link.pointee.sdl_nlen)
                    guard start + 6 <= raw.count else { return nil }
                    return raw[start ..< start + 6].map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            }
            if let mac, mac != "00:00:00:00:00:00" { found[name] = mac }
        }
        return found.keys.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }.first.flatMap { found[$0] }
    }

    /// Whether this Mac wakes for network access (System Settings › Energy, or `pmset -g` womp).
    static func wakesForNetwork() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("womp") }) else { return nil }
        return line.split(separator: " ").last == "1"
    }
}

/// Wakes a sleeping Mac on the same network with a magic packet: six 0xFF bytes, then its MAC address sixteen times.
/// Over Tailscale or the internet it can't reach a sleeping Mac; only the local network carries broadcasts.
enum WakeOnLAN {
    @discardableResult
    static func send(to mac: String) -> Bool {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        let packet = [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for target in ["255.255.255.255"] + subnetBroadcasts() {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, target, &address.sin_addr)
            let result = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if result == packet.count { sent = true }
        }
        return sent
    }

    /// The broadcast address of each IPv4 network this Mac is on; 255.255.255.255 alone stays on the default route's.
    private static func subnetBroadcasts() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_BROADCAST != 0, flags & IFF_UP != 0, let broadcast = entry.pointee.ifa_dstaddr,
                  broadcast.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(broadcast, socklen_t(broadcast.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return Array(Set(result))
    }
}
