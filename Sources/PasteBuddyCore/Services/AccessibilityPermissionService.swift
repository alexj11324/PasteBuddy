#if os(macOS)
import ApplicationServices
#endif
import Foundation

public enum AccessibilityPermissionService {
    public static var isTrusted: Bool {
        #if os(macOS)
        AXIsProcessTrusted()
        #else
        false
        #endif
    }

    @discardableResult
    public static func requestTrustPrompt() -> Bool {
        #if os(macOS)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #else
        false
        #endif
    }
}
