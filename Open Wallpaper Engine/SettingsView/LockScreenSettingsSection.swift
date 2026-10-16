import SwiftUI

struct LockScreenSettingsSection: View {
    @ObservedObject var service = LockScreenSyncService.shared
    @State private var screens = NSScreen.screens
    var body: some View {
        Section {
            Toggle("鎖定畫面跟隨桌布（實驗）", isOn: Binding(get: { service.enabled }, set: service.setEnabled))
                .disabled(service.busy && !service.enabled)
            if service.enabled {
                Picker("跟隨的螢幕", selection: $service.sourceScreenID) {
                    Text("自動跟隨主螢幕").tag(LockScreenSyncService.automaticDisplay)
                    ForEach(screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(WallpaperViewModel.screenId(for: screen))
                    }
                    if service.sourceScreenID != LockScreenSyncService.automaticDisplay && !screens.contains(where: { WallpaperViewModel.screenId(for: $0) == service.sourceScreenID }) {
                        Text("未連接的螢幕").tag(service.sourceScreenID)
                    }
                }
            }
            if service.enabled && !service.activeDisplayName.isEmpty {
                Text("目前跟隨：" + service.activeDisplayName).font(.caption).foregroundStyle(.secondary)
                Text("下載完成會預先準備目前比例的影片；換成新比例時準備正在使用的桌布，相同比例重用快取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LockScreenProgressView()
            if !service.preparationStatus.isEmpty && service.enabled {
                Text(service.preparationStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text(service.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("macOS 26 實驗功能。首次需下載並選取一個 Apple 航拍桌布，螢幕保護程式設為自動。影片會靜音並重複至少三分鐘；場景會錄成 15 秒動畫並隱藏場景時鐘，網頁桌布不會同步。啟用期間暫停調整選單列顏色；關閉會還原首次備份的桌布設定。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("系統桌布設定") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }
                if service.enabled { Button("重新同步") { service.retry() }.disabled(service.busy) }
                if service.protectsAerial && !service.enabled { Button("重試還原") { service.restore() }.disabled(service.busy) }
            }
        } header: { Label("鎖定畫面", systemImage: "lock.display") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in screens = NSScreen.screens }
    }
}


// Shared by the library and settings so preparation is visible without opening settings.
struct LockScreenProgressView: View {
    @ObservedObject private var service = LockScreenSyncService.shared
    var body: some View {
        if !service.activityTitle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(service.activityTitle, systemImage: "lock.display")
                    .font(.callout).lineLimit(2)
                HStack {
                    Text(service.activityStage).font(.caption)
                    Spacer()
                    if let progress = service.recordingProgress {
                        Text("\(Int(progress * 100))%").font(.caption.monospacedDigit())
                    }
                }
                if let progress = service.recordingProgress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                        .accessibilityLabel("場景錄製進度")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel(service.activityStage)
                }
                Text("完成前保留目前鎖定背景，可繼續使用程式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }
}
