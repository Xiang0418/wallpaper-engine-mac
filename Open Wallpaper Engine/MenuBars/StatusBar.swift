//
//  Status.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/8.
//

import Cocoa

extension AppDelegate {
    @objc func mute() {
        self.wallpaperViewModel.playVolume = 0
    }

    @objc func unmute() {
        self.wallpaperViewModel.playVolume = self.wallpaperViewModel.lastPlayVolume == 0 ? 1 : self.wallpaperViewModel.lastPlayVolume
    }

    @objc func pause() {
        self.wallpaperViewModel.playRate = 0
    }

    @objc func resume() {
        self.wallpaperViewModel.playRate = self.wallpaperViewModel.lastPlayRate == 0 ? 1 : self.wallpaperViewModel.lastPlayRate
    }

    @objc func takeScreenshot() {
        try! Process.run(URL(filePath: "/usr/sbin/screencapture"), arguments: ["-Cmup", "~/Picturesscreenshot.png"])
    }

    @objc func browseWorkshop() {
        // Change tab selection to `Workshop`
        self.contentViewModel.topTabBarSelection = 1
        openMainWindow()
    }

    @objc func openSupportWebpage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/haren724/open-wallpaper-engine-mac/wiki")!)
    }

    @objc func selectRecentWallpaper(_ sender: NSMenuItem) {
        guard let wallpaper = sender.representedObject as? WEWallpaper else { return }
        wallpaperViewModel.nextCurrentWallpaper = wallpaper
    }

    func buildRecentWallpapersMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Recent Wallpapers"))
        let recents = wallpaperViewModel.recentWallpapers

        if recents.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No recent wallpapers"), action: nil, keyEquivalent: ""))
        } else {
            for wallpaper in recents {
                let title = wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title
                let typeLabel = wallpaper.project.type.isEmpty ? "" : " (\(wallpaper.project.type.capitalized))"
                let item = NSMenuItem(title: "\(title)\(typeLabel)", action: #selector(selectRecentWallpaper(_:)), keyEquivalent: "")
                item.representedObject = wallpaper
                item.target = self
                menu.addItem(item)
            }
        }

        return menu
    }

    private func refreshWallpaperVolumeItems(in menu: NSMenu) {
        let tag = 7301
        for item in menu.items where item.tag == tag { menu.removeItem(item) }
        guard let muteIndex = menu.items.firstIndex(where: {
            $0.action == #selector(mute) || $0.action == #selector(unmute)
        }) else { return }
        let item = NSMenuItem()
        item.tag = tag
        let sourceName = NSScreen.screens.first {
            WallpaperViewModel.screenId(for: $0) == wallpaperViewModel.audioSourceScreenId
        }?.localizedName ?? String(localized: "Selected display disconnected")
        item.view = WallpaperVolumeMenuView(model: wallpaperViewModel, screenName: sourceName)
        menu.insertItem(item, at: muteIndex)
        let separator = NSMenuItem.separator()
        separator.tag = tag
        menu.insertItem(separator, at: muteIndex + 1)
    }

    func makeStatusMenu() -> NSMenu {
        // Recent Wallpapers Submenu
        let recentWallpapersMenuItem = NSMenuItem(title: String(localized: "Recent Wallpapers"), action: nil, keyEquivalent: "")
        recentWallpapersMenuItem.submenu = buildRecentWallpapersMenu()

        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            .init(title: String(localized: "Show Open Wallpaper Engine"),
                  systemImage: "photo",
                  action: #selector(openMainWindow),
                  keyEquivalent: "o"),

            recentWallpapersMenuItem,

            .separator(),

            .init(title: String(localized: "Browse Workshop"),
                  systemImage: "globe",
                  action: #selector(browseWorkshop),
                  keyEquivalent: "w"),

            .init(title: String(localized: "Settings"),
                  systemImage: "gearshape.fill",
                  action: #selector(openSettingsWindow),
                  keyEquivalent: ","),

            .separator(),

            .init(title: String(localized: "Support & FAQ"),
                  systemImage: "person.fill.questionmark",
                  action: #selector(openSupportWebpage),
                  keyEquivalent: "i"),

            .separator(),

            .init(title: String(localized: "Mute"),
                  systemImage: "speaker.slash.fill",
                  action: #selector(AppDelegate.shared.mute),
                  keyEquivalent: "m"),

            .init(title: String(localized: "Pause"),
                  systemImage: "pause.fill",
                  action: #selector(pause),
                  keyEquivalent: "p"),

            .init(title: String(localized: "Quit"),
                  systemImage: "power",
                  action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        ]

        refreshWallpaperVolumeItems(in: menu)

        if let muteItem = menu.items.first(where: { $0.action == #selector(mute) }), wallpaperViewModel.playVolume == 0 {
            muteItem.title = String(localized: "Unmute")
            muteItem.action = #selector(unmute)
        }
        if let pauseItem = menu.items.first(where: { $0.action == #selector(pause) }), wallpaperViewModel.playRate == 0 {
            pauseItem.title = String(localized: "Resume")
            pauseItem.action = #selector(resume)
        }
        return menu
    }

    func setStatusMenu() {
        let menu = makeStatusMenu()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        if let button = self.statusItem.button {
            if let image = NSImage(named: "we.logo") {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: nil)
            }
        }
    }
}

// MARK: - NSMenuDelegate — refresh Recent Wallpapers on menu open

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshWallpaperVolumeItems(in: menu)
        // Update the Recent Wallpapers submenu each time the status bar menu opens
        if let recentItem = menu.items.first(where: { $0.title == String(localized: "Recent Wallpapers") }) {
            recentItem.submenu = buildRecentWallpapersMenu()
        }
    }
}
