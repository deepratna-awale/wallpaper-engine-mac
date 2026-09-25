import CoreMedia
import Cocoa
import ScreenCaptureKit
import Accelerate
import JavaScriptCore

final class BrowserMediaIntegration {
    static let shared = BrowserMediaIntegration()
    private let lock = NSLock()
    private(set) var title = ""
    private(set) var url = ""
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(refresh),
                                     userInfo: nil, repeats: true)
        refresh()
    }

    @objc private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let browsers = ["Safari", "Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge", "Vivaldi", "Firefox", "Zen"]
            let running = self.runningProcesses()
            let scripts = browsers.filter { running.contains($0) }.map { browser -> String in
                if browser == "Firefox" || browser == "Zen" {
                    return "tell application \"System Events\" to tell process \"\(browser)\" to {name of front window, \"\"}"
                }
                let tabTitle = browser == "Safari" ? "name of current tab of front window" : "title of active tab of front window"
                let tabURL = browser == "Safari" ? "URL of current tab of front window" : "URL of active tab of front window"
                return "tell application \"\(browser)\" to {\(tabTitle), \(tabURL)}"
            }
            let result = scripts.lazy.compactMap { self.runAppleScript($0) }.first
            guard let result, result.count >= 2 else { return }
            self.lock.lock()
            self.title = result[0]
            self.url = result[1]
            self.lock.unlock()
        }
    }

    private func runningProcesses() -> Set<String> {
        NSWorkspace.shared.runningApplications.compactMap(\.localizedName).reduce(into: Set<String>()) { result, name in
            result.insert(name)
        }
    }

    private func runAppleScript(_ source: String) -> [String]? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        // Imported as implicitly unwrapped but returns nil whenever the script fails (no front
        // window, Automation permission denied), so bind it explicitly instead of trapping.
        let descriptor: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        guard error == nil, let descriptor, descriptor.numberOfItems >= 2 else { return nil }
        return [descriptor.atIndex(1)?.stringValue ?? "", descriptor.atIndex(2)?.stringValue ?? ""]
    }

    func snapshot() -> (title: String, url: String) {
        lock.lock(); defer { lock.unlock() }
        return (title, url)
    }

    deinit { timer?.invalidate() }
}
