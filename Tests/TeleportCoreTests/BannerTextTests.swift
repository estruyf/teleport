import Foundation
@testable import TeleportCore
import Testing

/// Descriptions as Notification Center on macOS 27 gives them: "App, title, subtitle, body".
@Suite struct BannerTextTests {
    @Test func appNameComesBeforeTheTexts() {
        #expect(BannerText.appName(description: "Microsoft Teams, Ada Lovelace, Are you free?", title: "Ada Lovelace", subtitle: "", body: "Are you free?") == "Microsoft Teams")
        #expect(BannerText.appName(description: "Script Editor, Hello title, Sub, Body text here", title: "Hello title", subtitle: "Sub", body: "Body text here") == "Script Editor")
    }

    @Test func commasInTheTextsDontSplitTheName() {
        let name = BannerText.appName(description: "Script Editor, Third, also comma, Third body, with comma",
                                      title: "Third, also comma", subtitle: "", body: "Third body, with comma")
        #expect(name == "Script Editor")
        #expect(BannerText.appName(description: "Me, Myself and I, Hi, there", title: "Hi", subtitle: "", body: "there") == "Me, Myself and I")
    }

    @Test func fallsBackWhenTheTextsDontLineUp() {
        // The body was cut short in the description.
        #expect(BannerText.appName(description: "Mail, Invoice, Please find…", title: "Invoice", subtitle: "", body: "Please find attached") == "Mail")
        #expect(BannerText.appName(description: "Calendar", title: "", subtitle: "", body: "") == "Calendar")
        #expect(BannerText.appName(description: "", title: "x", subtitle: "", body: "") == nil)
    }

    @Test func namesMatchIgnoringCase() {
        #expect(BannerText.matches("microsoft teams", any: ["Microsoft Teams"]))
        #expect(!BannerText.matches("Microsoft Outlook", any: ["Microsoft Teams", "Teams"]))
    }

    @Test func longNotificationsFitADataPacket() throws {
        let long = RemoteNotification(id: "id", bundleID: "a.b", app: "App", title: "t", subtitle: "", body: String(repeating: "é", count: 20000))
        let data = try JSONEncoder().encode(long.trimmed())
        #expect(data.count < 15_000)
        #expect(long.trimmed().body.hasSuffix("…"))
    }
}
