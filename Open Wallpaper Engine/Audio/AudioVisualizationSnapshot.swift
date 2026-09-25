import CoreMedia
import Cocoa
import ScreenCaptureKit
import Accelerate
import JavaScriptCore

struct AudioVisualizationSnapshot {
    let level: Double
    let spectrum: [Double]
    let waveform: [Double]
    let bass: Double
    let mid: Double
    let treble: Double
}
