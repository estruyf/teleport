import SwiftUI
import TeleportCore

/// First launch: what is this Mac?
struct WelcomeView: View {
    @ObservedObject var app: AppModel
    @Local private var name: String
    @Local private var appeared = false

    init(app: AppModel) {
        self.app = app
        _name = Local(wrappedValue: app.config.deviceName)
    }

    var body: some View {
        ZStack {
            BeamBackdrop(strength: 1.4)
            VStack(spacing: 26) {
                ZStack {
                    PortalRing(mood: .live, size: 150)
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                        .shadow(color: Theme.glow.opacity(0.5), radius: 18, y: 6)
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Teleport").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Use the apps on another Mac as if they were right here.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .offset(y: appeared ? 0 : 12)
                .opacity(appeared ? 1 : 0)

                HStack(spacing: 16) {
                    ModeCard(
                        icon: "macmini.fill",
                        title: "Share this Mac's apps",
                        detail: "The Mac in the office, with or without a screen. Your other Macs open its windows.",
                        action: "Make it the host"
                    ) { choose(.host) }
                    ModeCard(
                        icon: "macbook",
                        title: "Use apps from another Mac",
                        detail: "The Mac you sit at. Remote windows show up here with their own Dock icons.",
                        action: "Make it the viewer"
                    ) { choose(.viewer) }
                }
                .frame(maxWidth: 700)
                .offset(y: appeared ? 0 : 20)
                .opacity(appeared ? 1 : 0)

                HStack(spacing: 8) {
                    Text("Call this Mac").foregroundStyle(.secondary)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                .font(.callout)
                .opacity(appeared ? 1 : 0)
            }
            .padding(40)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) { appeared = true }
        }
    }

    private func choose(_ mode: TeleportConfig.Mode) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { app.config.deviceName = trimmed }
        app.setMode(mode)
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Theme.remote)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: run).primaryAction()
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .hoverOutline(cornerRadius: 16)
    }
}
