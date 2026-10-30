import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Colours and building blocks shared by every screen.
/// Violet is the teleport colour: anything on another Mac, and the portal itself.
enum Theme {
    static let remote = Color(nsColor: remoteNSColor)
    static let remoteNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.69, green: 0.59, blue: 0.99, alpha: 1) // #b197fc
            : NSColor(red: 0.44, green: 0.28, blue: 0.91, alpha: 1) // #7048e8
    }
    static let glow = Color(red: 0.55, green: 0.40, blue: 1.0)
    static let ok = Color.green
    static let warn = Color.orange
    static let bad = Color.red
}

// MARK: - The portal

/// Concentric rings that turn while something is happening and glow when it's done.
struct PortalRing: View {
    enum Mood { case idle, busy, live }
    var mood: Mood = .idle
    var size: CGFloat = 120
    @Local private var spin = false
    @Local private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.glow.opacity(mood == .idle ? 0.10 : 0.35), .clear], center: .center, startRadius: 0, endRadius: size * 0.6))
                .frame(width: size * 1.3, height: size * 1.3)
                .scaleEffect(pulse ? 1.08 : 0.92)
                .animation(mood == .idle ? .default : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)

            ring(radius: size * 0.50, width: size * 0.045, dash: [size * 0.30, size * 0.12], opacity: 0.9)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(spinAnimation(duration: mood == .busy ? 2.2 : 14), value: spin)
            ring(radius: size * 0.38, width: size * 0.03, dash: [size * 0.10, size * 0.08], opacity: 0.55)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(spinAnimation(duration: mood == .busy ? 3.0 : 20), value: spin)
            Circle()
                .strokeBorder(Theme.remote.opacity(mood == .idle ? 0.25 : 0.6), lineWidth: 1)
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size * 1.3, height: size * 1.3)
        .onAppear {
            spin = true
            pulse = true
        }
    }

    private func spinAnimation(duration: Double) -> Animation {
        .linear(duration: duration).repeatForever(autoreverses: false)
    }

    private func ring(radius: CGFloat, width: CGFloat, dash: [CGFloat], opacity: Double) -> some View {
        Circle()
            .strokeBorder(
                AngularGradient(colors: [Theme.remote.opacity(0), Theme.remote, Theme.glow, Theme.remote.opacity(0)], center: .center),
                style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
            )
            .opacity(mood == .idle ? opacity * 0.5 : opacity)
            .frame(width: radius * 2, height: radius * 2)
            .shadow(color: Theme.glow.opacity(mood == .live ? 0.6 : 0.2), radius: mood == .idle ? 0 : 8)
    }
}

/// A soft violet glow at the top of a window, so every screen feels like the same place.
struct BeamBackdrop: View {
    var strength: Double = 1

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [Theme.glow.opacity(0.22 * strength), .clear], center: .top, startRadius: 0, endRadius: 520)
            LinearGradient(colors: [Theme.glow.opacity(0.06 * strength), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Cards and chips

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

/// Lifts and glows under the pointer.
struct HoverLift: ViewModifier {
    @Local private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: Theme.glow.opacity(hovering ? 0.25 : 0), radius: 14, y: 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }

    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(Theme.remote)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false
    @Local private var on = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(pulsing ? 0.8 : 0), radius: on ? 5 : 1)
                .animation(pulsing ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: on)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .onAppear { on = true }
    }
}

struct Chip: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .system(.caption, design: .monospaced) : .caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

/// A copyable value, such as an address.
struct CopyChip: View {
    let text: String
    @Local private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 6) {
                Text(text).font(.system(.caption, design: .monospaced))
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

struct Notice: View {
    enum Kind { case info, warning, error, success }
    let text: String
    var kind: Kind = .info
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var icon: String {
        switch kind { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon"; case .success: "checkmark.circle" }
    }

    private var color: Color {
        switch kind { case .info: Theme.remote; case .warning: Theme.warn; case .error: Theme.bad; case .success: Theme.ok }
    }
}

// MARK: - Pairing codes

/// Six digits, revealed one after another.
struct CodeDisplay: View {
    let code: String
    @Local private var shown = 0

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                if index == 3 { Spacer().frame(width: 8) }
                Text(index < shown ? String(digit) : "•")
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(index < shown ? Color.primary : Color.secondary)
                    .frame(width: 48, height: 62)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.remote.opacity(index < shown ? 0.7 : 0.25)))
                    .shadow(color: Theme.glow.opacity(index < shown ? 0.3 : 0), radius: 8)
                    .scaleEffect(index < shown ? 1 : 0.92)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6).delay(Double(index) * 0.08), value: shown)
            }
        }
        .onAppear { shown = code.count }
        .onChange(of: code) { _, new in
            shown = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { shown = new.count }
        }
    }
}

/// Six boxes for typing a code. Click a box to select it and type to overwrite it; Delete clears
/// the selected box, or the one just typed; the arrows move; ⌘V pastes a whole code.
/// Boxes are fixed slots, so clearing one never shifts the digits after it.
struct CodeEntry: View {
    static let length = 6
    @Binding var code: String
    var focused: FocusState<Bool>.Binding
    /// Kept here rather than read back from `code`: that only catches up on the next render,
    /// so keys pressed in quick succession would each see the old value and drop digits.
    @Local private var slots = [Character?](repeating: nil, count: CodeEntry.length)
    /// The box typing goes into; `length` means past the last box.
    @Local private var cursor = 0
    /// The box was clicked or arrowed to, so Delete clears it instead of the one before.
    @Local private var picked = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0 ..< Self.length, id: \.self) { index in
                if index == 3 { Spacer().frame(width: 8) }
                box(index)
            }
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused(focused)
        .onKeyPress(phases: .down) { handle($0) }
        .onPasteCommand(of: [.plainText]) { _ in
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            let digits = text.filter { $0.isASCII && $0.isNumber }.prefix(Self.length)
            guard !digits.isEmpty else { return }
            fill(String(digits))
        }
        .onAppear { fill(code) }
        .onChange(of: code) { _, new in if new != joined { fill(new) } }
        .onHover { inside in inside ? NSCursor.iBeam.push() : NSCursor.pop() }
        .accessibilityElement()
        .accessibilityLabel("Pairing code")
        .accessibilityValue(code)
    }

    private var joined: String { String(slots.compactMap { $0 }) }

    private func box(_ index: Int) -> some View {
        let digit = slots[index]
        let isSelected = focused.wrappedValue && index == cursor
        return ZStack {
            if let digit {
                Text(String(digit))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            } else if isSelected {
                // A blinking caret, so it's obvious typing will land here.
                TimelineView(.periodic(from: .now, by: 0.53)) { context in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.remote)
                        .frame(width: 2, height: 26)
                        .opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0 ? 1 : 0)
                }
            }
        }
        .frame(width: 44, height: 56)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(isSelected && digit != nil ? Theme.remote.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Theme.remote : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            focused.wrappedValue = true
            cursor = index
            picked = true
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘V, ⌘W and friends belong to the menus; Return and Escape to the sheet's buttons.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        // Backspace arrives as U+007F, which SwiftUI matches to neither .delete nor .deleteForward.
        case .delete, KeyEquivalent("\u{7F}"):
            if picked, cursor < Self.length, slots[cursor] != nil {
                slots[cursor] = nil
            } else if cursor > 0 {
                cursor -= 1
                slots[cursor] = nil
            }
            picked = false
        case .deleteForward:
            if cursor < Self.length { slots[cursor] = nil }
        case .leftArrow:
            cursor = max(0, cursor - 1)
            picked = true
            return .handled
        case .rightArrow:
            cursor = min(Self.length - 1, cursor + 1)
            picked = true
            return .handled
        default:
            guard press.characters.count == 1, let digit = press.characters.first, digit.isASCII, digit.isNumber else { return .ignored }
            guard cursor < Self.length else { return .handled }
            slots[cursor] = digit
            cursor += 1
            picked = false
        }
        code = joined
        return .handled
    }

    /// Replaces every box, from a paste or a code set from outside.
    private func fill(_ digits: String) {
        let digits = Array(digits.prefix(Self.length))
        slots = (0 ..< Self.length).map { $0 < digits.count ? digits[$0] : nil }
        cursor = digits.count
        picked = false
        code = joined
    }
}

// MARK: - Small parts

struct AppIconView: View {
    let image: NSImage?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary).padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Covers the window, and swallows its clicks, while a mode switch or quit stops services.
struct StoppingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 14) {
                PortalRing(mood: .busy, size: 70)
                Text(message).font(.headline)
                Text("This takes a few seconds.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .transition(.opacity)
    }
}

/// A Mac glyph for pairing illustrations.
struct MacGlyph: View {
    let symbol: String
    let label: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 110)
    }
}

enum SystemSettings {
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

/// Per-view local state without SwiftUI's `@State` macro, whose compiler plugin the
/// Command Line Tools don't ship. Same semantics: survives view updates, projects a Binding.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
