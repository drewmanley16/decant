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
}
