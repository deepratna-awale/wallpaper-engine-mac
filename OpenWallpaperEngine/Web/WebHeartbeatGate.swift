import Foundation

/// Decides whether a web wallpaper should be posting heartbeats: only while its page says it is
/// visible, its window is on screen and the displays are awake. WebKit stops or throttles a
/// page's timers otherwise, so silence then is not a hang.
struct WebHeartbeatGate: Equatable {
    var pageVisible = true
    var windowVisible = true
    var displaysAwake = true

    var expectsHeartbeats: Bool { pageVisible && windowVisible && displaysAwake }
}
