//
//  GeneralPage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel
    @ObservedObject private var media = ExternalMediaService.shared
    
    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        Form {
            // MARK: Automatic Startup
            Section {
                Toggle("Start with macOS", isOn: $viewModel.settings.autoStart)
//                Toggle("Safe start after hibernation", isOn: $viewModel.settings.safeMode)
            } header: {
                Label("Automatic Startup", systemImage: "star.fill")
            }
            // MARK: Basic Setup
            Section {
                Picker("Language", selection: $viewModel.settings.language) {
                    Text("Follow System").tag(GSLocalization.followSystem)
                    Text("English").tag(GSLocalization.en_US)
                    Text("Chinese Simplified").tag(GSLocalization.zh_CN)
                }.disabled(true)
            } header: {
                Label("Basic Setup", systemImage: "gearshape.fill")
            }
            // MARK: macOS
            Section {
                Toggle("Adjust Menu Bar Color", isOn: $viewModel.settings.adjustMenuBarTint)
            } header: {
                Label("macOS", systemImage: "apple.logo")
            }
            // MARK: Appearance
            Section {
                Picker("Theme", selection: $viewModel.settings.appearance) {
                    Text("Light").tag(GSAppearance.light)
                    Text("Dark").tag(GSAppearance.dark)
                    Text("Auto").tag(GSAppearance.followSystem)
                }
            } header: {
                Label("Appearance", systemImage: "paintpalette.fill")
            }
            // MARK: Audio
            Section {
                Toggle(isOn: $viewModel.settings.audioOutput) {
                    Text("Audio Output")
                }.disabled(true)
                Toggle(isOn: $viewModel.settings.reloadWhenChangingOutputDevice) {
                    Text("Reload when changing output device")
                }.disabled(true)
            } header: {
                Label("Audio", systemImage: "speaker.3.fill")
            }
            EngineAssetsSettingsSection(assets: .shared, steam: AppDelegate.shared.contentViewModel.steamCmd)
            ExternalMediaSettingsSection(media: media)
            // MARK: Video
            Section {
                Picker("Video Framework", selection: $viewModel.settings.videoFramework) {
                    Text("Apple AVKit").tag(GSVideoFramework.avkit)
                }
            } header: {
                Label("Video", systemImage: "film")
            }
            // MARK: Advanced
            Section {
                Picker("Process Piority", selection: $viewModel.settings.processPiority) {
                    Text("Normal").tag(GSProcessPiority.normal)
                    Text("Below Normal").tag(GSProcessPiority.belowNormal)
                }
                Toggle("Pause when VRAM is exhausted", isOn: $viewModel.settings.pauseOnVRAMExhausted)
                Toggle("Restart after crashing", isOn: $viewModel.settings.restartAfterCrashing)
            } header: {
                Label("Advanced", systemImage: "wrench.and.screwdriver.fill")
            }
            // MARK: Developers
            Section {
                Picker("Log Level", selection: $viewModel.settings.logLevel) {
                    Text("None").tag(GSLogLevel.none)
                    Text("Errors Only").tag(GSLogLevel.error)
                    Text("Verbose").tag(GSLogLevel.verbose)
                }
            } header: {
                Label("Developer", systemImage: "number")
            }
            // MARK: Reset
            Section {
                HStack {
                    Text("Reset Config")
                    Spacer()
                    Button {
                        viewModel.settings = GlobalSettings()
                        media.artworkEnabled = false; media.systemAudioEnabled = false
                    } label: {
                        Text("Reset").frame(width: 100)
                    }
                    .tint(Color.red)
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Label("Reset", systemImage: "exclamationmark.triangle.fill")
            }
        }.formStyle(.grouped)
    }
}

struct ExternalMediaSettingsSection: View {
    @ObservedObject var media: ExternalMediaService
    var body: some View {
            Section {
                Toggle("Use currently playing album artwork", isOn: $media.artworkEnabled)
                Text(media.artworkStatus).font(.caption).foregroundStyle(.secondary)
                if !media.trackTitle.isEmpty { Text(media.trackTitle).font(.callout).textSelection(.enabled) }
                Toggle("Use other apps for the audio spectrum", isOn: $media.systemAudioEnabled)
                Text(media.audioStatus).font(.caption).foregroundStyle(.secondary)
                Text("Album artwork follows the player shown in Control Center. Audio spectrum includes all other apps and excludes this wallpaper app.")
                    .font(.caption).foregroundStyle(.secondary)
                if media.systemAudioEnabled {
                    Text("Allow access in System Settings → Privacy & Security → Screen & System Audio Recording. Audio is analyzed locally and is not saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if media.artworkEnabled || media.systemAudioEnabled {
                    HStack {
                        Button("Retry media connection") { media.retry() }
                        Button("Open recording permissions") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            } header: {
                Label("Other Media Players", systemImage: "music.note")
            }
    }
}
