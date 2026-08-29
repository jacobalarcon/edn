import AppKit
import ApplicationServices
import Testing
@testable import EDNCore

/// Batched attribute reads report a missing attribute as an AXValue wrapping an
/// AXError, where an individual read simply returns nothing. Decoding has to collapse
/// that placeholder back to nil, or a window with no title would appear to have one.
@Suite("AX attribute decoding")
struct AXAttributeDecodingTests {

    private func axError(_ error: AXError) -> CFTypeRef {
        var value = error
        return AXValueCreate(.axError, &value)! as CFTypeRef
    }

    @Test("Point and size values decode to their geometry")
    func decodesGeometry() {
        var point = CGPoint(x: 12, y: 34)
        var size = CGSize(width: 56, height: 78)
        let pointValue = AXValueCreate(.cgPoint, &point)! as CFTypeRef
        let sizeValue = AXValueCreate(.cgSize, &size)! as CFTypeRef

        #expect(AXWindow.unwrapPoint(pointValue) == CGPoint(x: 12, y: 34))
        #expect(AXWindow.unwrapSize(sizeValue) == CGSize(width: 56, height: 78))
    }

    @Test("An AXError placeholder decodes to nil, not to zeroed geometry")
    func errorPlaceholderDecodesToNil() {
        let placeholder = axError(.noValue)

        #expect(AXWindow.unwrapPoint(placeholder) == nil)
        #expect(AXWindow.unwrapSize(placeholder) == nil)
    }

    @Test("A value of the wrong kind decodes to nil rather than reinterpreting bytes")
    func mismatchedKindDecodesToNil() {
        var size = CGSize(width: 10, height: 20)
        let sizeValue = AXValueCreate(.cgSize, &size)! as CFTypeRef

        #expect(AXWindow.unwrapPoint(sizeValue) == nil)
        #expect(AXWindow.unwrapSize("not an AXValue" as CFTypeRef) == nil)
        #expect(AXWindow.unwrapPoint(nil) == nil)
    }

    @Test("Foreground and accessory apps are presentable workspace members")
    func presentableApplicationPolicies() {
        #expect(AXWindowManager.isPresentableApplicationPolicy(.regular))
        #expect(AXWindowManager.isPresentableApplicationPolicy(.accessory))
    }

    @Test("Headless and background processes cannot impersonate workspace apps")
    func prohibitedApplicationPolicy() {
        #expect(!AXWindowManager.isPresentableApplicationPolicy(.prohibited))
    }
}
