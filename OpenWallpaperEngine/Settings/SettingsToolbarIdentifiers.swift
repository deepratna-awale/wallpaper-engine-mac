import Cocoa
import SwiftUI
import AVKit
import WebKit

enum SettingsToolbarIdentifiers {
    static let performance = NSToolbarItem.Identifier(rawValue: "performance")
    static let general = NSToolbarItem.Identifier(rawValue: "general")
    static let plugins = NSToolbarItem.Identifier(rawValue: "plugins")
    static let permissions = NSToolbarItem.Identifier(rawValue: "permissions")
    static let diagnostics = NSToolbarItem.Identifier(rawValue: "diagnostics")
    static let about = NSToolbarItem.Identifier(rawValue: "about")
}
