import Foundation
import Testing
@testable import Decant

@Suite("Deep links")
struct DeepLinkTests {
    let id = UUID()

    @Test func parsesWebAndAppLinks() {
        #expect(DeepLink(url: URL(string: "https://decant-diary.vercel.app/t/\(id.uuidString)")!) == .entry(id))
        #expect(DeepLink(url: URL(string: "decant://u/\(id.uuidString.lowercased())")!) == .user(id))
        #expect(DeepLink(url: URL(string: "decant://w/\(id.uuidString)")!) == .wine(id))
        #expect(DeepLink(url: URL(string: "https://decant-diary.vercel.app/invite/abc234")!) == .invite("ABC234"))
        #expect(DeepLink(url: URL(string: "https://www.getdecant.xyz/invite/abc234")!) == .invite("ABC234"))
        #expect(DeepLink(url: URL(string: "https://getdecant.xyz/t/\(id.uuidString)")!) == .entry(id))
        #expect(DeepLink.invite("ABC234").url.absoluteString == "https://www.getdecant.xyz/invite/ABC234")
        #expect(DeepLink(url: URL(string: "https://example.com/invite/abc234")!) == nil)
    }

    @Test func rejectsOtherHostsAndBadValues() {
        #expect(DeepLink(url: URL(string: "https://example.com/t/\(id.uuidString)")!) == nil)
        #expect(DeepLink(url: URL(string: "decant://t/not-a-uuid")!) == nil)
        #expect(DeepLink(url: URL(string: "decant://invite/ABC")!) == nil)
    }

    @Test func roundTripsThroughShareURL() {
        for link in [DeepLink.entry(id), .user(id), .wine(id), .invite("XYZ789")] {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func extractsInviteCodeFromPastedText() {
        #expect(extractInviteCode("ayu3vq") == "AYU3VQ")
        #expect(extractInviteCode("  AYU3VQ\n") == "AYU3VQ")
        #expect(extractInviteCode("https://decant-diary.vercel.app/invite/AYU3VQ") == "AYU3VQ")
        #expect(extractInviteCode("Join me on Decant: https://decant-diary.vercel.app/invite/ayu3vq") == "AYU3VQ")
        #expect(extractInviteCode("abc") == nil)
    }
}
