//
//  FirstLaunchView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/4.
//

import SwiftUI

struct FirstLaunchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var globalSettingsViewModel: GlobalSettingsViewModel

    @State private var pageIndex = 0
    @State private var checked = false

    private var pages: [Page] { Page.all }
    private var isLastPage: Bool { pageIndex == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pageBody(pages[pageIndex])
                .frame(height: 320)
            Divider()
            footer
        }
        .textSelection(.enabled)
        .frame(width: 620)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(pages[pageIndex].title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(pages[pageIndex].subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func pageBody(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                ForEach(page.sections) { section in
                    NewSection(title: section.title,
                               text: section.text,
                               systemImage: section.systemImage,
                               imageColor: section.imageColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Rows keep their text left aligned, but the block as a whole sits centred.
            .frame(maxWidth: 470)
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
        }
        .id(pageIndex)
        .transition(.opacity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                Toggle("Never show this again until next update", isOn: $checked)
                Spacer()
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.15)) { pageIndex -= 1 }
                }
                .disabled(pageIndex == 0)
                Button(isLastPage ? "Finish" : "Next") {
                    if isLastPage {
                        UserDefaults.standard.set(!checked, forKey: "IsFirstLaunch")
                        dismiss()
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) { pageIndex += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

extension FirstLaunchView {
    struct Section: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let text: LocalizedStringKey
        let systemImage: String
        var imageColor: Color = .accentColor
    }

    struct Page {
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let sections: [Section]

        static let all: [Page] = [
            Page(title: "Welcome to Open Wallpaper Engine",
                 subtitle: "A live wallpaper engine for macOS",
                 sections: [
                    Section(title: "Every Wallpaper Type",
                            text: "Play scene, video, web and image wallpapers, with a familiar layout if you already know Wallpaper Engine.",
                            systemImage: "photo.on.rectangle.angled"),
                    Section(title: "Steam Workshop Built In",
                            text: "Browse, search and subscribe to Workshop items without leaving the app, then set them as your wallpaper in one click.",
                            systemImage: "square.and.arrow.down",
                            imageColor: .blue),
                    Section(title: "One Wallpaper Per Display",
                            text: "Assign a different wallpaper to each screen, or mirror one across all of them.",
                            systemImage: "display.2",
                            imageColor: .purple)
                 ]),
            Page(title: "Scenes, Effects and Music",
                 subtitle: "Powered by a Metal renderer",
                 sections: [
                    Section(title: "Full Effect Stack",
                            text: "Scene wallpapers render through Metal with their authored effects. Videos render the same way, so blur, bloom, tint and the rest apply to them too.",
                            systemImage: "wand.and.stars",
                            imageColor: .purple),
                    Section(title: "Sync to Music",
                            text: "Zoom, pace, tilt and saturation can pulse with audio. A wallpaper with its own soundtrack follows that; when it is silent, it follows whatever else is playing.",
                            systemImage: "waveform",
                            imageColor: .pink),
                    Section(title: "Scene Inspector",
                            text: "Inspect every layer, texture and effect in a wallpaper, tweak parameters live, and nudge or align objects.",
                            systemImage: "square.stack.3d.up",
                            imageColor: .orange)
                 ]),
            Page(title: "Make It Yours",
                 subtitle: "Playlists, favourites and your own media",
                 sections: [
                    Section(title: "Add Video or Image URLs",
                            text: "Paste a link to any video or image. Images are turned into a scene, so the effect stack applies to them as well.",
                            systemImage: "link",
                            imageColor: .teal),
                    Section(title: "Playlists and Favourites",
                            text: "Rotate through a playlist on a timer or when a video ends, and keep the wallpapers you love a click away.",
                            systemImage: "heart.fill",
                            imageColor: .red),
                    Section(title: "Tune Every Property",
                            text: "Adjust volume, playback speed, placement and any property the wallpaper's author exposed, right from the details sidebar.",
                            systemImage: "slider.horizontal.3",
                            imageColor: .indigo)
                 ]),
            Page(title: "Runs Quietly in the Background",
                 subtitle: "You stay in control of resources",
                 sections: [
                    Section(title: "Kind to Your Battery",
                            text: "Choose what happens on battery, when another app goes fullscreen, or when your displays sleep — from lowering the frame rate to pausing entirely.",
                            systemImage: "battery.75",
                            imageColor: .green),
                    Section(title: "Performance You Set",
                            text: "Pick the frame rate, anti-aliasing and texture quality that suit your Mac, and check the Diagnostics page to see the impact.",
                            systemImage: "speedometer",
                            imageColor: .red),
                    Section(title: "Always a Menu Bar Away",
                            text: "Pause, mute or switch wallpapers from the menu bar at any time. Open Settings to fine-tune the rest.",
                            systemImage: "menubar.arrow.up.rectangle",
                            imageColor: .yellow)
                 ])
        ]
    }

    struct NewSection: View {
        var title: LocalizedStringKey
        var text: LocalizedStringKey
        var textColor: Color = .primary
        var systemImage: String
        var imageColor: Color = .accentColor

        var body: some View {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: systemImage)
                    .frame(width: 50, height: 50)
                    .font(.largeTitle)
                    .foregroundStyle(imageColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(textColor)
                        .font(.title3)
                        .bold()
                    Text(text)
                        .foregroundStyle(textColor)
                }
                .multilineTextAlignment(.leading)
                Spacer()
            }
        }
    }
}

extension AppDelegate {
    @objc func resetFirstLaunch() {
        UserDefaults.standard.set(true, forKey: "IsFirstLaunch")
    }
}

struct FirstLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        FirstLaunchView()
    }
}
