import AppKit
import SwiftUI

/// Colours and small building blocks shared by every screen.
/// Violet is reserved for things on another Mac, as in Seshboard.
enum Theme {
    static let remote = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.69, green: 0.59, blue: 0.99, alpha: 1) // #b197fc
            : NSColor(red: 0.44, green: 0.28, blue: 0.91, alpha: 1) // #7048e8
    })
    static let ok = Color.green
    static let warn = Color.orange
    static let bad = Color.red

    static let remoteNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.69, green: 0.59, blue: 0.99, alpha: 1)
            : NSColor(red: 0.44, green: 0.28, blue: 0.91, alpha: 1)
    }
}

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
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
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
    enum Kind { case info, warning, error }
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
        switch kind { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }

    private var color: Color {
        switch kind { case .info: Theme.remote; case .warning: Theme.warn; case .error: Theme.bad }
    }
}

/// The big six digits used for pairing.
struct CodeDisplay: View {
    let code: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                if index == 3 { Spacer().frame(width: 8) }
                Text(String(digit))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 46, height: 60)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.remote.opacity(0.5)))
            }
        }
    }
}

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
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

extension View {
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(Theme.remote)
    }
}

enum SystemSettings {
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
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
