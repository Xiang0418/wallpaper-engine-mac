import SwiftUI
import AppKit

struct EngineAssetsSettingsSection: View {
    @ObservedObject var assets: EngineAssetsService
    @ObservedObject var steam: SteamCmdService
    @ObservedObject private var diagnostics = SceneAssetDiagnostics.shared

    var body: some View {
        Section {
            Label(assets.manifest == nil ? String(localized: "Shared assets not installed") : String(localized: "Shared assets ready"),
                  systemImage: assets.manifest == nil ? "exclamationmark.triangle" : "checkmark.circle")
            if let manifest = assets.manifest {
                Text("Imported \(manifest.fileCount) files on \(manifest.importedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Import the assets folder from your Wallpaper Engine installation, or download it using your Steam account. Active scenes reload after installation. Some effects still require renderer support.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Import local assets…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = String(localized: "Choose Wallpaper Engine’s assets folder or installation folder.")
                    panel.begin { response in
                        if response == .OK, let url = panel.url { assets.importFolder(url) }
                    }
                }.disabled(assets.isBusy)
                Button(assets.manifest == nil ? String(localized: "Download from Steam") : String(localized: "Update from Steam")) {
                    assets.download(using: steam)
                }.disabled(assets.isBusy || !steam.isLoggedIn || steam.isLoggingIn || steam.hasActiveWorkshopDownloads)
            }
            if !steam.isInstalled || !steam.isLoggedIn {
                Text("Set up SteamCMD and sign in through the Workshop tab to download assets.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if steam.hasActiveWorkshopDownloads {
                Text("Wait for Workshop downloads to finish before downloading shared assets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Steam downloads the original content depot without updating subscribed Workshop wallpapers. Ownership of Wallpaper Engine is required.")
                .font(.caption).foregroundStyle(.secondary)
            if assets.isBusy, let progress = assets.progress { EngineAssetProgressView(progress: progress) }
            if let error = assets.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if assets.manifest != nil {
                Button("Show shared assets in Finder") {
                    if let root = assets.library.activeRoot { NSWorkspace.shared.open(root) }
                }
            }
            DisclosureGroup("Scene asset diagnostics") {
                Text("Reports describe currently playing scenes. Missing files and unsupported effects are separate issues.")
                    .font(.caption).foregroundStyle(.secondary)
                let reports = diagnostics.reports.sorted { $0.key.uuidString < $1.key.uuidString }
                if reports.isEmpty || reports.allSatisfy({ $0.value.issues.isEmpty }) {
                    Text("No asset issues reported by active scenes.").foregroundStyle(.secondary)
                }
                ForEach(reports, id: \.key) { entry in
                    if !entry.value.issues.isEmpty {
                        DisclosureGroup(entry.value.wallpaper + " (\(entry.value.issues.count))") {
                            ForEach(entry.value.issues, id: \.self) { issue in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(kindLabel(issue.kind)).font(.caption).bold()
                                    Text(issue.path).textSelection(.enabled)
                                    Text(issue.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        } header: {
            Label("Wallpaper Engine shared assets", systemImage: "shippingbox")
        }
    }

    private func kindLabel(_ kind: SceneAssetIssue.Kind) -> String {
        switch kind {
        case .missing: return String(localized: "Missing file")
        case .invalid: return String(localized: "Invalid or unsupported file")
        case .unsupported: return String(localized: "Unsupported effect or feature")
        case .approximate: return String(localized: "Approximate substitute")
        }
    }
}

struct EngineAssetProgressView: View {
    let progress: EngineAssetProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.content).font(.callout).fontWeight(.medium)
            HStack {
                Text(progress.title)
                Spacer(minLength: 8)
                if let fraction = progress.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(1)))
                        .monospacedDigit()
                }
            }.font(.caption)
            if let fraction = progress.fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(progress.title))
            } else {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel(Text(progress.title))
            }
            if let files = progress.depotFileCount, let size = progress.depotSizeMB {
                Text("Content package: \(files) files, approximately \(size) MB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let summary = progress.byteSummary {
                Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if progress.phase != .importing {
                Text("Steam reports progress for the current phase, not individual filenames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
