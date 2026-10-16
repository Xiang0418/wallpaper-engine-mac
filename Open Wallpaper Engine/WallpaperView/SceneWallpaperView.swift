import Cocoa
import SwiftUI
import SpriteKit
import Combine

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let screenId: String

    class Coordinator {
        var model: SceneWallpaperViewModel?
        var sceneChanges: AnyCancellable?
        var requestedSource: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: SKView, coordinator: Coordinator) {
        coordinator.sceneChanges = nil
        view.presentScene(nil)
        coordinator.model?.stop()
    }

    func makeNSView(context: Context) -> SKView {
        let view = InteractiveWallpaperView(frame: .zero)
        view.ignoresSiblingOrder = false
        view.allowsTransparency = false
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        if let prepared = wallpaperViewModel.takePreparedScene(for: screenId) {
            // Preparation is complete: swap in one main-thread operation.
            context.coordinator.sceneChanges = nil
            prepared.skScene?.scaleMode = .fill
            view.presentScene(prepared.skScene)
            context.coordinator.model?.stop()
            context.coordinator.model = prepared
            prepared.requestReload = { [weak wallpaperViewModel, weak prepared] in
                guard let prepared else { return }
                wallpaperViewModel?.setWallpaper(prepared.currentWallpaper, for: screenId)
            }
            context.coordinator.sceneChanges = prepared.$skScene.receive(on: DispatchQueue.main)
                .sink { [weak view] scene in
                    guard let scene, view?.scene !== scene else { return }
                    scene.scaleMode = .fill
                    view?.presentScene(scene)
                }
            prepared.activatePreparedScene()
        } else if context.coordinator.model == nil {
            // Restored assignments at launch also prepare outside the main thread.
            let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
            let source = wallpaper.wallpaperDirectory.appendingPathComponent(wallpaper.project.file)
            if context.coordinator.requestedSource != source {
                context.coordinator.requestedSource = source
                DispatchQueue.main.async {
                    guard wallpaperViewModel.wallpaper(for: screenId).wallpaperDirectory == wallpaper.wallpaperDirectory,
                          wallpaperViewModel.loadingWallpapers[screenId] == nil else { return }
                    wallpaperViewModel.setWallpaper(wallpaper, for: screenId)
                }
            }
        }
        view.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        view.isPaused = wallpaperViewModel.playRate == 0
    }
}
