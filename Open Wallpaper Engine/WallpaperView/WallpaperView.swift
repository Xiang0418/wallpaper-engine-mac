//
//  WallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI

struct WallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    let screenId: String

    private var menuBarInset: CGFloat {
        guard let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId }) else { return 0 }
        return max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    var body: some View {
        let wallpaper = viewModel.wallpaper(for: screenId)
        switch wallpaper.project.type.lowercased() {
        case "video":
            VideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        case "scene":
            SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
                .padding(.top, menuBarInset)
                .background(Color.black)
        case "web":
            WebWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        default:
            EmptyView()
        }
    }
}
