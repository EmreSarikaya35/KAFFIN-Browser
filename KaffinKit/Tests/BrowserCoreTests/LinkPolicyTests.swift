import BrowserCore
import Testing

struct LinkPolicyTests {
    @Test(arguments: ["http", "https", "about", "blob", "HTTPS"])
    func webPagesLoad(scheme: String) {
        #expect(LinkPolicy.decision(scheme: scheme, isMainFrame: true, isLinkClick: false) == .allow)
    }

    @Test func dataAddressMayFillAFrameButNotTheWindow() {
        #expect(LinkPolicy.decision(scheme: "data", isMainFrame: false, isLinkClick: false) == .allow)
        #expect(LinkPolicy.decision(scheme: "data", isMainFrame: true, isLinkClick: true) == .block)
    }

    @Test(arguments: ["file", "FILE", "javascript", "vbscript"])
    func localAndScriptAddressesNeverOpen(scheme: String) {
        #expect(LinkPolicy.decision(scheme: scheme, isMainFrame: true, isLinkClick: true) == .block)
    }

    @Test(arguments: ["mailto", "tel", "zoommtg", "slack"])
    func otherAppsNeedAClickAndAConfirmation(scheme: String) {
        #expect(LinkPolicy.decision(scheme: scheme, isMainFrame: true, isLinkClick: true) == .askToOpenApp)
        #expect(LinkPolicy.decision(scheme: scheme, isMainFrame: true, isLinkClick: false) == .block)
    }
}
