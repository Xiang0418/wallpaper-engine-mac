import AppKit
import SwiftUI

extension URL { func directoryTotalAllocatedSize(includingSubfolders: Bool) throws -> Int? { 0 } }

@main struct ScenePropertiesUITests {
    static func main() throws {
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: fixture.appendingPathComponent("project.json"))
        let project = try JSONDecoder().decode(WEProject.self, from: data)
        let roundtrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(NSDictionary(dictionary: original["general"] as! [String: Any]).isEqual(to: roundtrip["general"] as! [String: Any]))
        let store = ScenePropertyStore.shared
        let definitions = store.definitions(at: fixture)
        precondition(definitions.count == 121)
        var allEnabled = store.values(at: fixture)
        for (name, d) in definitions where d["type"] as? String == "bool" { allEnabled[name] = true }
        precondition(definitions.values.allSatisfy { ScenePropertyStore.isVisible($0, values: allEnabled) })
        for theme in ["light", "dark"] {
            let view = NSHostingView(rootView: ScrollView { ScenePropertiesEditor(directory: fixture).padding(20) }.background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, theme == "light" ? .light : .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/we-properties-\(theme).png"))
            window.orderOut(nil)
        }
        print("All 121 definitions survive metadata roundtrip; all fixture conditions resolve; settings UI rendered in light/dark")
    }
}
