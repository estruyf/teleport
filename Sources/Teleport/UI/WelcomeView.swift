import SwiftUI
import TeleportCore

/// First launch: what is this Mac?
struct WelcomeView: View {
    @ObservedObject var app: AppModel
    @Local private var name: String

    init(app: AppModel) {
        self.app = app
        _name = Local(wrappedValue: app.config.deviceName)
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Teleport").font(.largeTitle.weight(.semibold))
                Text("Use apps from another Mac as if they were here.")
                    .font(.title3).foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ModeCard(
                    icon: "macmini",
                    title: "This Mac shares its apps",
                    detail: "Host. Runs on the Mac in the office, with or without a screen. Other Macs open its windows.",
                    action: "Set up as host"
                ) { choose(.host) }
                ModeCard(
                    icon: "macbook",
                    title: "This Mac shows remote apps",
                    detail: "Viewer. The Mac you work on. Remote windows appear here with their own Dock icons.",
                    action: "Set up as viewer"
                ) { choose(.viewer) }
            }
            .frame(maxWidth: 680)

            HStack {
                Text("This Mac's name").foregroundStyle(.secondary)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .font(.callout)

            Text("You can change this later in Settings.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose(_ mode: TeleportConfig.Mode) {
        app.config.deviceName = name.trimmingCharacters(in: .whitespaces).isEmpty ? app.config.deviceName : name
        app.setMode(mode)
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let run: () -> Void
    @Local private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Theme.remote)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: run).primaryAction()
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Theme.remote.opacity(0.6) : Color.primary.opacity(0.08)))
        .onHover { hovering = $0 }
    }
}
