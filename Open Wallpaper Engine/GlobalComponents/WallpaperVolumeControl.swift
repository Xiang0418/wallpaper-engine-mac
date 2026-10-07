import SwiftUI
import Combine

/// Both this panel and the status menu write the same persisted wallpaper level.
struct WallpaperVolumeControl: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let wallpaper: WEWallpaper

    private var percentage: Binding<Double> {
        Binding(get: { Double(wallpaperViewModel.volume(for: wallpaper) * 100) },
                set: { wallpaperViewModel.setVolume(Float($0.rounded() / 100), for: wallpaper) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Wallpaper Volume", systemImage: "speaker.wave.2.fill")
                Spacer()
                Text("\(Int(percentage.wrappedValue.rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
            Slider(value: percentage, in: 0...100) {
                Text("Wallpaper Volume")
            } minimumValueLabel: {
                Text("0%")
            } maximumValueLabel: {
                Text("100%")
            }
            .labelsHidden()
            .accessibilityLabel(Text("Wallpaper Volume"))
            .accessibilityValue(Text("\(Int(percentage.wrappedValue.rounded()))%"))
            Group {
                if wallpaperViewModel.playVolume == 0 {
                    Text("All wallpapers are muted. Your volume setting is saved.")
                } else {
                    Text("Saved for this wallpaper.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Native controls keep dragging responsive while NSMenu runs its tracking loop.
final class WallpaperVolumeMenuView: NSView {
    private let model: WallpaperViewModel
    private let wallpaper: WEWallpaper?
    private let screenName: String
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let percentage = NSTextField(labelWithString: "100%")
    private let detail = NSTextField(labelWithString: "")
    private var subscription: AnyCancellable?

    init(model: WallpaperViewModel, wallpaper: WEWallpaper? = nil, screenName: String = "") {
        self.model = model
        self.wallpaper = wallpaper
        self.screenName = screenName
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 112))

        let heading = NSTextField(labelWithString: wallpaper == nil ? String(localized: "Overall Volume") : String(localized: "Wallpaper Volume"))
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.frame = NSRect(x: 16, y: 87, width: 215, height: 18)
        addSubview(heading)
        percentage.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        percentage.alignment = .right
        percentage.frame = NSRect(x: 238, y: 87, width: 46, height: 18)
        addSubview(percentage)

        let title = NSTextField(labelWithString: wallpaper?.project.title ?? (screenName.isEmpty ? String(localized: "Selected audio source") : screenName))
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = wallpaper?.project.title ?? (screenName.isEmpty ? String(localized: "Selected audio source") : screenName)
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 16, y: 65, width: 268, height: 18)
        addSubview(title)

        slider.frame = NSRect(x: 16, y: 35, width: 268, height: 24)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeVolume(_:))
        slider.setAccessibilityLabel(wallpaper == nil ? String(localized: "Overall Volume") : String(localized: "Wallpaper Volume") + ": " + (wallpaper?.project.title ?? "") + ", " + screenName)
        addSubview(slider)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 16, y: 10, width: 268, height: 18)
        addSubview(detail)

        let key = wallpaper.map { WallpaperViewModel.volumeKey(for: $0) }
        // Read the published values, since @Published emits before its property is set.
        subscription = model.$wallpaperVolumes.combineLatest(model.$playVolume)
            .sink { [weak self] levels, master in
                guard let self = self else { return }
                let level = key.map { levels[$0] ?? 1 } ?? master
                let percent = Double((level * 100).rounded())
                self.slider.doubleValue = percent
                self.percentage.stringValue = "\(Int(percent))%"
                self.slider.setAccessibilityValueDescription(self.percentage.stringValue)
                self.detail.stringValue = master == 0
                    ? String(localized: "All wallpapers muted")
                    : (wallpaper == nil ? String(localized: "Audio source: Display Settings") : screenName)
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changeVolume(_ sender: NSSlider) {
        let level = Float(sender.doubleValue.rounded() / 100)
        if let wallpaper = wallpaper { model.setVolume(level, for: wallpaper) }
        else { model.playVolume = level }
    }
}

struct WallpaperAudioSourceControl: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wallpaper Audio Source")
                .font(.headline)
            Picker("Wallpaper Audio Source", selection: $wallpaperViewModel.audioSourceScreenId) {
                ForEach(NSScreen.screens, id: \.self) { screen in
                    Text(screen.localizedName).tag(WallpaperViewModel.screenId(for: screen))
                }
                if !NSScreen.screens.contains(where: { WallpaperViewModel.screenId(for: $0) == wallpaperViewModel.audioSourceScreenId }) {
                    Text("Selected display disconnected").tag(wallpaperViewModel.audioSourceScreenId)
                }
            }
            .labelsHidden()
            .accessibilityLabel(Text("Wallpaper Audio Source"))
            Text("Only this display plays audio. If disconnected or disabled, wallpaper audio stays silent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
