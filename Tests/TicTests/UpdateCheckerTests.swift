import AppKit
import Foundation
import Testing
@testable import Tic

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    @Test("detects newer versions numerically")
    func newer() {
        #expect(UpdateChecker.isNewer("0.6.0", than: "0.5.0"))
        #expect(UpdateChecker.isNewer("v0.6.0", than: "0.5.0"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))   // not lexical
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))
    }

    @Test("same, older, or unparseable is not an update")
    func notNewer() {
        #expect(!UpdateChecker.isNewer("0.5.0", than: "0.5.0"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("0.4.9", than: "0.5.0"))
        #expect(!UpdateChecker.isNewer("garbage", than: "0.5.0"))
    }

    @Test("parses the GitHub latest-release payload and strips the tag's v")
    func parse() throws {
        let json = #"""
            {"tag_name":"v0.6.0","name":"Tic v0.6.0","assets":[],
             "html_url":"https://github.com/kasvith/tic/releases/tag/v0.6.0"}
            """#
        let release = try UpdateChecker.parse(Data(json.utf8))
        #expect(release.version == "0.6.0")
        #expect(release.url.absoluteString == "https://github.com/kasvith/tic/releases/tag/v0.6.0")
        #expect(throws: (any Error).self) { try UpdateChecker.parse(Data("{}".utf8)) }
    }
}

/// The stateful side: menu item, dot, and banner bookkeeping, with GitHub and the notification
/// center stubbed out.
@Suite("UpdateChecker state")
@MainActor
struct UpdateCheckerStateTests {
    /// Banners the stubbed notifier "posted" (by version).
    final class Banners { var posted: [String] = [] }

    private nonisolated static let releasePage = URL(string: "https://github.com/kasvith/tic/releases/tag/v0.6.0")!

    private static func freshDefaults() -> UserDefaults {
        let name = "UpdateCheckerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func makeChecker(
        current: String? = "0.5.0", latest: String? = "0.6.0",
        defaults: UserDefaults = freshDefaults(), banners: Banners = Banners()
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersion: current, defaults: defaults,
            fetch: {
                guard let latest else { throw URLError(.notConnectedToInternet) }
                return .init(version: latest, url: releasePage)
            },
            notify: { release, _ in banners.posted.append(release.version) }
        )
    }

    @Test("a newer release sets the item and the dot, and posts one banner even across re-checks")
    func newerRelease() async {
        let banners = Banners()
        let checker = Self.makeChecker(banners: banners)
        await checker.check()
        #expect(checker.menuTitle == "Update Available: v0.6.0…")
        #expect(checker.isUnseen)
        #expect(banners.posted == ["0.6.0"])

        await checker.check()   // the daily re-check
        #expect(checker.menuTitle == "Update Available: v0.6.0…")
        #expect(banners.posted == ["0.6.0"])
    }

    @Test("up to date (or ahead) shows nothing")
    func upToDate() async {
        let banners = Banners()
        for latest in ["0.5.0", "0.4.0"] {
            let checker = Self.makeChecker(latest: latest, banners: banners)
            await checker.check()
            #expect(checker.menuTitle == nil)
            #expect(!checker.isUnseen)
        }
        #expect(banners.posted.isEmpty)
    }

    @Test("the banner is remembered per version across launches")
    func bannerOncePerVersion() async {
        let defaults = Self.freshDefaults()
        let banners = Banners()
        await Self.makeChecker(defaults: defaults, banners: banners).check()
        await Self.makeChecker(defaults: defaults, banners: banners).check()   // relaunch
        #expect(banners.posted == ["0.6.0"])
        await Self.makeChecker(latest: "0.7.0", defaults: defaults, banners: banners).check()
        #expect(banners.posted == ["0.6.0", "0.7.0"])
    }

    @Test("markSeen clears the dot, keeps the item, and is remembered across launches")
    func seen() async {
        let defaults = Self.freshDefaults()
        let checker = Self.makeChecker(defaults: defaults)
        await checker.check()
        checker.markSeen()
        #expect(!checker.isUnseen)
        #expect(checker.menuTitle != nil)

        let relaunched = Self.makeChecker(defaults: defaults)
        await relaunched.check()
        #expect(!relaunched.isUnseen)
        #expect(relaunched.menuTitle != nil)

        let newer = Self.makeChecker(latest: "0.7.0", defaults: defaults)   // a newer one re-dots
        await newer.check()
        #expect(newer.isUnseen)
    }

    @Test("closing a menu that showed the item counts as seen; other menus don't")
    func menuTracking() async throws {
        let checker = Self.makeChecker()
        await checker.check()
        #expect(checker.isUnseen)

        let other = NSMenu()
        other.addItem(withTitle: "Quit Tic", action: nil, keyEquivalent: "")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other)
        try await Task.sleep(for: .milliseconds(50))
        #expect(checker.isUnseen)

        let ours = NSMenu()
        ours.addItem(withTitle: checker.menuTitle!, action: nil, keyEquivalent: "")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: ours)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!checker.isUnseen)
    }

    @Test("a failed fetch is silent and leaves the last result alone")
    func fetchFailure() async {
        let banners = Banners()
        let checker = Self.makeChecker(latest: nil, banners: banners)
        await checker.check()
        #expect(checker.menuTitle == nil)
        #expect(!checker.isUnseen)
        #expect(banners.posted.isEmpty)
    }

    @Test("no bundle version (swift run) disables the check")
    func noBundleVersion() async {
        let banners = Banners()
        let checker = Self.makeChecker(current: nil, banners: banners)
        await checker.check()
        #expect(checker.menuTitle == nil)
        #expect(banners.posted.isEmpty)
    }
}
