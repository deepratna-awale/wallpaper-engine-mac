import Foundation
import Security

/// Whether JavaScriptCore can compile scripts in this process. On current macOS it JIT-compiles
/// only in a process signed with `com.apple.security.cs.allow-jit` (hardened runtime or not);
/// without it every script runs in its interpreter, about ten times slower (measured: a 2·10⁷
/// iteration loop takes 1.3 s interpreted, 0.11–0.14 s with the entitlement). The app's
/// entitlements grant it; unsigned test hosts (CI builds with `CODE_SIGNING_ALLOWED=NO`) don't.
enum SceneScriptJIT {
    static let entitlement = "com.apple.security.cs.allow-jit"

    /// Whether this process carries the entitlement.
    static var isEnabled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }
}
