//
//  PerformancePage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct PerformancePage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        Form {
            Section {
                Picker("Other Application Focused:", selection: $viewModel.settings.otherApplicationFocused) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                }
                
                Picker("Other Application Fullscreen:", selection: $viewModel.settings.otherApplicationFullscreen) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                Picker("Other Application Playing Audio:", selection: $viewModel.settings.otherApplicationPlayingAudio) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Mute").tag(GSPlayback.mute)
                    Text("Pause").tag(GSPlayback.pause)
                }
                
                Picker("Display asleep", selection: $viewModel.settings.displayAsleep) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                Picker("Laptop on battery", selection: $viewModel.settings.laptopOnBattery) {
                    Text("Keep Running").tag(GSPlayback.keepRunning)
                    Text("Pause").tag(GSPlayback.pause)
                    Text("Stop (free memory)").tag(GSPlayback.stop)
                }
                
                HStack {
                    Text("Application Rules")
                    Spacer()
                    Button {
                        
                    } label: {
                        Text("Edit").frame(width: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                }
            } header: {
                Label("Playback", systemImage: "play.fill")
            }
            Section {
                HStack(spacing: 1) {
                    Button {
                        viewModel.setQuality(.low)
                    } label: {
                        Text("Low").frame(maxWidth: .infinity)
                    }
                    Divider()
                    Button {
                        viewModel.setQuality(.medium)
                    } label: {
                        Text("Medium").frame(maxWidth: .infinity)
                    }
                    Divider()
                    Button {
                        viewModel.setQuality(.high)
                    } label: {
                        Text("High").frame(maxWidth: .infinity)
                    }
                    Divider()
                    Button {
                        viewModel.setQuality(.ultra)
                    } label: {
                        Text("Ultra").frame(maxWidth: .infinity)
                    }
                }
                .padding(6)
                .background(Color(nsColor: NSColor.unemphasizedSelectedContentBackgroundColor))
                .buttonStyle(.borderless)
                .clipShape(RoundedRectangle(cornerRadius: 5.0))
                Picker("Anti-aliasing", selection: $viewModel.settings.antiAliasing) {
                    Text("None").tag(GSAntiAliasingQuality.none)
                    Text("MSAA x2").tag(GSAntiAliasingQuality.msaa_x2)
                    Text("MSAA x4").tag(GSAntiAliasingQuality.msaa_x4)
                    Text("MSAA x8").tag(GSAntiAliasingQuality.msaa_x8)
                }
                .overlay {
                    HStack {
                        Spacer(); Spacer()
                        if viewModel.settings.antiAliasing == .msaa_x8 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .help("×8 MSAA is only recommended for powerful high-end desktop graphics cards.")
                        }
                        Spacer()
                    }
                    
                }
                Picker("Post-Processing", selection: $viewModel.settings.postProcessing) {
                    Text("Disabled").tag(GSPostProcessingQuality.disabled)
                    Text("Enabled").tag(GSPostProcessingQuality.enabled)
                    Text("Ultra").tag(GSPostProcessingQuality.ultra)
                }
                .overlay {
                    HStack {
                        Spacer(); Spacer()
                        if viewModel.settings.postProcessing == .ultra {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("Ultra mode adds HDR bloom to supported wallpapers and is only recommended for powerful high-end desktop graphics cards.")
                        }
                        Spacer()
                    }
                    
                }
                Picker("Texture Resolution", selection: $viewModel.settings.textureResolution) {
                    Text("High Quality").tag(GSTextureResolutionQuality.highQuality)
                    Text("High Performance").tag(GSTextureResolutionQuality.highPerformance)
                    Text("Automatic").tag(GSTextureResolutionQuality.automatic)
                }
                Picker("Volumetrics", selection: $viewModel.settings.volumetrics) {
                    Text("Disabled").tag(GSLightingQuality.disabled)
                    Text("Low").tag(GSLightingQuality.low)
                    Text("Medium").tag(GSLightingQuality.medium)
                    Text("High").tag(GSLightingQuality.high)
                    Text("Ultra").tag(GSLightingQuality.ultra)
                }
                .help("Light shafts from wallpapers' volumetric lights. Higher qualities march more samples at a finer resolution; low and medium blur a coarser buffer.")
                HStack {
                    Text("FPS")
                    Spacer()
                    NumericSliderInput(value: $viewModel.settings.fps, range: 10...120,
                                       defaultValue: 30, step: 1, fractionDigits: 0,
                                       sliderWidth: 150, fieldWidth: 44)
                }
                .overlay {
                    HStack {
                        Spacer(); Spacer()
                        if viewModel.settings.fps > 60 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .help("High FPS may slow down your PC! We're serious, this is too much 🔥.")
                        } else if viewModel.settings.fps > 30 {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("High FPS may slow down your PC!")
                        }
                        Spacer()
                    }
                    
                }
                Picker("Particle Budget", selection: $viewModel.settings.particleBudget) {
                    Text("Low (10,000)").tag(GSParticleBudget.low)
                    Text("Medium (25,000)").tag(GSParticleBudget.medium)
                    Text("High (50,000)").tag(GSParticleBudget.high)
                    Text("Unlimited").tag(GSParticleBudget.unlimited)
                }
                .help("The most particles one wallpaper may hold. A wallpaper made with more draws every particle system thinner, keeping its look.")
                HStack {
                    Text("Reflections")
                    Spacer()
                    Toggle("Reflection", isOn: $viewModel.settings.reflections)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
            } header: {
                Label("Quality", systemImage: "memorychip.fill")
                Text("Currently, these settings below are designed for scene wallpapers \nand may not work as expect ")
            }
        }
        .formStyle(.grouped)
    }
}
