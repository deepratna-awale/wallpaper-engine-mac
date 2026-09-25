import SwiftUI
import AVKit

enum WallpaperPlacement: String, CaseIterable, Identifiable {
    case fill = "Fill"
    case fit = "Fit"
    case center = "Center"
    case stretch = "Stretch"
    case zoom = "Zoom"

    var id: Self { self }
}
