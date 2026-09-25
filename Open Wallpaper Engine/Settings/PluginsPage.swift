//
//  PluginsPage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct PluginsPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    
    @State var bigGearAngle = 0.0
    @State var smallGearAngle = 0.0
    
    @AppStorage("TestAnimates") var animates = false
    
    @State var isExpanded = false
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 20) {
                    Toggle("Animates", isOn: $animates)
                    if isExpanded {
                        HStack {
                            GifImage("maxwell-cat", animates: animates)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 100, maxHeight: 100)
                                .padding(4)
                                .background(Material.thin)
                                .clipShape(RoundedRectangle(cornerRadius: 16.0))
                            VStack(alignment: .leading, spacing: 10) {
                                Text("This plugin enables animation of GIF thumbnail images in wallpaper explorer")
                                Spacer()
                                Text("􀄪 You can toggle this to have a preview")
                                Spacer()
                                Text("!!! Notice that this may affects performance !!!")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Button {
                        withAnimation {
                            isExpanded.toggle()
                        }
                    } label: {
                        VStack {
                            if isExpanded {
                                Image(systemName: "chevron.up")
                                    .bold()
                                    .imageScale(.large)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Description...")
                            }
                        }
                    }
                    .tint(.accentColor)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                }
                Text("Come out soon...")
            } header: {
                Label("Internal", systemImage: "square.dashed.inset.filled")
            }
            Section {
                Text("None")
            } header: {
                Label("Third-party", systemImage: "person.3.fill")
            } footer: {
                Text("Those all settings above don't have to be saved for taking effect.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PluginPage_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject({ () -> GlobalSettingsViewModel in
                let viewModel = GlobalSettingsViewModel()
                viewModel.selection = 2
                return viewModel
            }())
            .frame(width: 500, height: 600)
    }
}
