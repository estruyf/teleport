import AppKit
import AVFoundation
import CoreAudio
import LiveKit
import ScreenCaptureKit
import TeleportCore

// The host's sound, both ways.
//
// Out: ScreenCaptureKit captures the shared apps' audio, and LiveKit's mixer sends it in the
// host's one audio track. The host's audio engine runs in manual rendering mode, so it touches no
// audio device: a headless Mac needs no microphone, and nothing plays out of its speakers.
//
// In: the viewer's microphone track is played into a virtual audio device (BlackHole, say), which
// the shared apps use as their microphone. The viewer only sends it while one of them is listening
// to a microphone, which Core Audio's process list tells.

/// Captures the sound of the shared apps and hands it to LiveKit's mixer.
@MainActor
final class AppAudioCapture {
    private var stream: SCStream?
    private let output = AppAudioOutput()
    private var allowedApps: [String] = []
    /// The processes the running stream includes, to tell when the filter needs an update.
    private var capturedPIDs: Set<pid_t> = []
    private var observers: [NSObjectProtocol] = []
    /// SCK calls one at a time.
    private var queue: Task<Void, Never>?

    var isRunning: Bool { stream != nil }

    func start(allowedApps: [String]) {
        self.allowedApps = allowedApps
        if observers.isEmpty {
            // A shared app that starts (or quits) later joins (or leaves) the capture. A new app takes
            // ScreenCaptureKit a moment to list, so look again shortly after.
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let bundleID = app?.bundleIdentifier
                    MainActor.assumeIsolated {
                        guard let self, let bundleID, SharedApp.match(bundleID, in: self.allowedApps) != nil else { return }
                        for delay: UInt64 in [0, 1, 3] {
                            Task { @MainActor [weak self] in
                                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                                self?.enqueue { await $0.apply() }
                            }
                        }
                    }
                })
            }
        }
        enqueue { await $0.apply() }
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        enqueue { await $0.halt() }
    }

    private func enqueue(_ work: @escaping @MainActor (AppAudioCapture) async -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Starts the stream, or points it at the shared apps that run now.
    private func apply() async {
        guard !observers.isEmpty else { return }
        do {
            // All apps, not only those with a window on screen: a minimised Teams still rings.
            let content = try await screenCaptureKit("shareable content for audio") { done in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                    done(content.map(Result.success) ?? .failure(error ?? HostError("ScreenCaptureKit returned no shareable content")))
                }
            }
            let apps = content.applications.filter { SharedApp.match($0.bundleIdentifier, in: allowedApps) != nil }
            let pids = Set(apps.map(\.processID))
            guard let display = content.displays.first else { throw HostError("no display to capture audio from") }
            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            if let stream {
                guard pids != capturedPIDs else { return }
                try await stream.update(filter: filter)
            } else {
                let stream = SCStream(filter: filter, configuration: Self.configuration(), delegate: output)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                // Video can't be turned off; a tiny, slow one keeps ScreenCaptureKit from logging dropped frames.
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                output.onStop = { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stream = nil
                        self.capturedPIDs = []
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.enqueue { await $0.apply() }
                    }
                }
                try await stream.start()
                self.stream = stream
                Log.info("sound: capturing the shared apps' audio")
            }
            if pids != capturedPIDs {
                Log.info("sound: capturing \(apps.isEmpty ? "nothing yet; no shared app runs" : apps.map(\.applicationName).joined(separator: ", "))")
            }
            capturedPIDs = pids
        } catch {
            Log.warn("sound: could not capture the shared apps' audio: \(error)")
        }
    }

    private func halt() async {
        guard let stream else { return }
        self.stream = nil
        capturedPIDs = []
        output.onStop = nil
        try? await stream.stop()
        Log.info("sound: stopped capturing")
    }

    private static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }
}

final class AppAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "teleport.app-audio", qos: .userInteractive)
    var onStop: (() -> Void)?

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.formatDescription != nil, sampleBuffer.numSamples > 0,
              let pcm = sampleBuffer.toAVAudioPCMBuffer()
        else { return }
        AudioManager.shared.mixer.capture(appAudio: pcm)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        Log.warn("sound: audio capture stopped: \(error)")
        onStop?()
    }
}

// MARK: - Microphone

enum MicrophoneUse {
    /// The first shared app that is reading from a microphone now, if any. The reading process can
    /// be a helper: WebKit records in its own process for the app it works for, and Electron apps
    /// have helpers named after them.
    static func listeningApp(among allowedApps: [String]) -> String? {
        for process in CoreAudioObject.system.objects(kAudioHardwarePropertyProcessObjectList)
            where process.uint32(kAudioProcessPropertyIsRunningInput) == 1
        {
            var candidates = [process.string(kAudioProcessPropertyBundleID)]
            if let pid = process.uint32(kAudioProcessPropertyPID).map({ pid_t(bitPattern: $0) }) {
                candidates.append(NSRunningApplication(processIdentifier: responsiblePID(for: pid))?.bundleIdentifier)
            }
            for case let bundleID? in candidates {
                if let app = SharedApp.match(bundleID, in: allowedApps) { return app }
            }
        }
        return nil
    }

    /// The process macOS holds responsible for `pid`: the app, for one of its XPC helpers.
    private static func responsiblePID(for pid: pid_t) -> pid_t {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return pid }
        let responsible = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return responsible > 0 ? responsible : pid
    }
}

enum SharedApp {
    /// The shared app `bundleID` belongs to: itself, or a helper named after it ("<app>.helper").
    static func match(_ bundleID: String, in allowedApps: [String]) -> String? {
        allowedApps.first { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}

/// An audio device a shared app can use as its microphone: virtual, with an input side for the
/// app to listen to and an output side for the viewer's voice.
struct VirtualAudioDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }

    static func all() -> [VirtualAudioDevice] {
        CoreAudioObject.system.objects(kAudioHardwarePropertyDevices).compactMap { device in
            guard device.uint32(kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual,
                  device.channels(kAudioObjectPropertyScopeInput) > 0, device.channels(kAudioObjectPropertyScopeOutput) > 0,
                  let uid = device.string(kAudioDevicePropertyDeviceUID), let name = device.string(kAudioObjectPropertyName),
                  // Teams' own device, for sharing the computer's sound in a meeting.
                  !uid.hasPrefix("MSLoopbackDriver")
            else { return nil }
            return VirtualAudioDevice(uid: uid, name: name)
        }
    }

    /// The configured device: an explicit UID, nothing for "", or a BlackHole device when unset.
    static func resolve(_ setting: String?, in devices: [VirtualAudioDevice]) -> VirtualAudioDevice? {
        switch setting {
        case "": return nil
        case nil: return devices.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
        case let uid?: return devices.first { $0.uid == uid }
        }
    }

    var deviceID: AudioDeviceID? {
        CoreAudioObject.system.objects(kAudioHardwarePropertyDevices).first { $0.string(kAudioDevicePropertyDeviceUID) == uid }?.id
    }
}

/// Plays the viewer's microphone into a virtual audio device.
///
/// Buffers are played as they arrive. When the device's clock runs slower than the network's,
/// they would pile up and the voice would lag further and further, so past a fifth of a second
/// queued, new ones are dropped.
final class VirtualMicrophone: AudioRenderer, @unchecked Sendable {
    let device: VirtualAudioDevice
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Recursive: stopping the player calls the completion handlers of queued buffers right away.
    private let lock = NSRecursiveLock()
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var queued = 0
    private static let maxQueued: AVAudioFrameCount = 9600

    init(device: VirtualAudioDevice) throws {
        self.device = device
        guard let id = device.deviceID else { throw HostError("\(device.name) is gone") }
        try engine.outputNode.auAudioUnit.setDeviceID(id)
        engine.attach(player)
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard pcmBuffer.frameLength > 0, let buffer = floatCopy(of: pcmBuffer) else { return }
        do {
            if format != buffer.format {
                engine.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                format = buffer.format
                queued = 0
            }
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.warn("sound: could not play the viewer's microphone into \(device.name): \(error)")
            return
        }
        guard queued + Int(buffer.frameLength) <= Int(Self.maxQueued) else { return }
        queued += Int(buffer.frameLength)
        let frames = Int(buffer.frameLength)
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued = max(0, self.queued - frames)
            self.lock.unlock()
        }
        if !player.isPlaying { player.play() }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        player.stop()
        engine.stop()
    }

    /// WebRTC reuses its buffer after render returns; the player needs its own, in float.
    private func floatCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: source.format.sampleRate, channels: source.format.channelCount),
              let copy = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: source.frameLength)
        else { return nil }
        if converter?.inputFormat != source.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: source.format, to: target)
        }
        guard let converter else { return nil }
        do {
            try converter.convert(to: copy, from: source)
        } catch {
            return nil
        }
        return copy
    }
}

// MARK: - Installing a virtual device

/// BlackHole 2ch, the free virtual audio device the Sound section helps install.
enum VirtualDeviceInstall {
    static let command = "brew install --cask blackhole-2ch"
    static let project = URL(string: "https://github.com/ExistentialAudio/BlackHole")!

    static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens Terminal running the install. A `.command` file opens in Terminal by itself, so
    /// Teleport doesn't need permission to control Terminal; Homebrew asks for the admin password there.
    static func runInTerminal() throws {
        guard let brew = homebrew else { throw HostError("Homebrew is not installed") }
        let script = """
        #!/bin/zsh
        clear
        echo "Installing BlackHole 2ch, a virtual audio device, so the viewer's microphone can reach apps on this Mac."
        echo "Homebrew asks for your administrator password."
        echo
        if "\(brew)" \(command.dropFirst("brew ".count)); then
          echo
          echo "Done. Teleport picks up BlackHole 2ch by itself."
          echo "Now choose BlackHole 2ch as the microphone in the app, such as Teams › Settings › Devices."
        else
          echo
          echo "The install did not finish. A company-managed Mac may block it; ask IT, or see \(project.absoluteString)"
        fi
        echo
        echo "You can close this window."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Install BlackHole for Teleport.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Core Audio

/// Just enough of Core Audio's object properties for the above.
struct CoreAudioObject {
    let id: AudioObjectID
    static let system = CoreAudioObject(id: AudioObjectID(kAudioObjectSystemObject))

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func objects(_ selector: AudioObjectPropertySelector) -> [CoreAudioObject] {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(CoreAudioObject.init(id:))
    }

    func uint32(_ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func channels(_ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
