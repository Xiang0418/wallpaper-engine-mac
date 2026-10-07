import AppKit
import JavaScriptCore
import SpriteKit
import AVFoundation

@main struct SceneRuntimeTests {
    static func main() throws {
        let context = JSContext()!
        var errors: [String] = []
        let log: @convention(block) (String) -> Void = { errors.append($0) }
        let read: @convention(block) (String) -> String = { _ in "null" }
        let write: @convention(block) (String, String) -> Void = { _,_ in }
        let launch: @convention(block) (String) -> Void = { _ in }
        context.setObject(log, forKeyedSubscript: "nativeLog" as NSString)
        context.setObject(read, forKeyedSubscript: "nativeRead" as NSString)
        context.setObject(write, forKeyedSubscript: "nativeWrite" as NSString)
        context.setObject(launch, forKeyedSubscript: "nativeShortcut" as NSString)
        context.exceptionHandler = { _, e in errors.append(e?.toString() ?? "exception") }
        context.evaluateScript(SceneScriptBootstrap.source)
        func check(_ expression: String) {
            precondition(context.evaluateScript(expression)?.toBool() == true, "Failed: \(expression); \(errors)")
        }
        let objects: [[String: Any]] = [
            ["id": 1, "name": "parent", "origin": "10 20 0"],
            ["id": 2, "parent": 1, "name": "clock", "text": ["value": "", "script": "export function update(value) { return String(new Date().getSeconds()).padStart(2, '0'); }"]],
            ["id": 3, "name": "child", "parent": 1, "origin": ["value": "1 2 0", "scriptproperties": ["speed": ["user": "speed", "value": 2]], "script": "export var scriptProperties=createScriptProperties().addSlider({name:'speed',value:1}).finish(); export function init(v){ shared.initialized=true; return v; } export function update(v){ return v.add(new Vec3(scriptProperties.speed*engine.frametime,0,0)); } export function cursorClick(){thisLayer.clicked=true;}" ]],
            ["id":4,"name":"broken","alpha":["value":1,"script":"export function update(){throw Error('intentional');}"]]
        ]
        context.objectForKeyedSubscript("loadScene")!.call(withArguments: [objects, ["speed":2], 1920,1080])
        check("shared.initialized && layers[2].getParent()===layers[0]")
        context.objectForKeyedSubscript("tick")!.call(withArguments:[0.1,100,200])
        check("Math.abs(layers[2].origin.x-1.2)<0.001 && layers[1].text.length===2")
        check("input.cursorWorldPosition.x===100 && engine.runtime===0.1")
        context.objectForKeyedSubscript("applyProperties")!.call(withArguments:[["speed":4]])
        context.objectForKeyedSubscript("tick")!.call(withArguments:[0.1,100,200])
        check("Math.abs(layers[2].origin.x-1.6)<0.001")
        precondition(errors.count == 1, "Script errors must isolate and log once: \(errors)")
        context.objectForKeyedSubscript("cursorEvent")!.call(withArguments:["cursorClick",3,100,200])
        check("layers[2].clicked===true")
        context.evaluateScript("var testAudio=engine.registerAudioBuffers(16)")
        context.objectForKeyedSubscript("setSpectrum")!.call(withArguments:[Array(repeating:0.5,count:64),Array(repeating:0.25,count:64)])
        check("testAudio.average[0]===0.375")
        context.objectForKeyedSubscript("shutdown")!.call(withArguments:[])
        check("scripts.length===0 && layers.length===0")
        precondition(SceneScriptRuntime.shortcutURL("cmd.exe /c evil") == nil)
        precondition(SceneScriptRuntime.shortcutURL("javascript:alert(1)") == nil)
        precondition(SceneScriptRuntime.shortcutURL("https://example.com") != nil)
        let scene = SKScene(size:CGSize(width:500,height:500))
        let icon = SKSpriteNode(color:.white,size:CGSize(width:100,height:100))
        scene.addChild(icon)
        let runtime = SceneScriptRuntime(objects:[["id":20,"name":"icon","origin":"100 100 0","scale":["value":"1 1 1","script":"export function update(v){engine.openUserShortcut('test');return v;} export function cursorClick(){engine.openUserShortcut('test');}"]]], nodes:[20:icon], properties:["test":"https://example.com"], size:scene.size,storageKey:"unit-test")
        var launches = 0
        runtime.openShortcut = { _ in launches += 1 }
        runtime.update(delta:0.016,cursor:CGPoint(x:100,y:100))
        precondition(launches == 0, "Scripts must not launch from update")
        runtime.mouseDown(at:CGPoint(x:100,y:100));runtime.mouseUp(at:CGPoint(x:100,y:100))
        precondition(launches == 1)
        runtime.mouseDown(at:CGPoint(x:100,y:100));runtime.mouseUp(at:CGPoint(x:130,y:100))
        precondition(launches == 1, "Dragging must not click")
        runtime.mouseDown(at:CGPoint(x:100,y:100));runtime.mouseUp(at:CGPoint(x:300,y:100))
        precondition(launches == 1, "Releasing outside must not click")
        runtime.stop()
        runtime.mouseDown(at:CGPoint(x:100,y:100));runtime.mouseUp(at:CGPoint(x:100,y:100))
        precondition(launches == 1)
        let analyzer = SceneAudioSpectrum()
        precondition(analyzer.snapshot().allSatisfy { $0 == 0 })
        analyzer.consume((0..<1024).map { sin(2 * .pi * 32 * Float($0)/1024) })
        precondition((analyzer.snapshot().max() ?? 0) > 0.5)
        for _ in 0..<40 { analyzer.consume(Array(repeating:0,count:1024)) }
        precondition((analyzer.snapshot().max() ?? 1) < 0.001)
        let audioURL=FileManager.default.temporaryDirectory.appendingPathComponent("we-spectrum-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at:audioURL) }
        let format=AVAudioFormat(standardFormatWithSampleRate:44100,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:44100)!
        buffer.frameLength=44100
        for i in 0..<44100 { buffer.floatChannelData![0][i]=sin(2 * .pi * 1378.125 * Float(i)/44100) }
        do { let file=try AVAudioFile(forWriting:audioURL,settings:format.settings);try file.write(from:buffer) }
        let source=try SceneAudioSpectrumSource(url:audioURL)
        _=source.snapshot(at:0.1,volume:1,playing:true)
        var sampled:[Float]=[]
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval:0.01)
            sampled=source.snapshot(at:0.1,volume:1,playing:true)
            if (sampled.max() ?? 0)>0.5 { break }
        }
        precondition((sampled.max() ?? 0)>0.5,"Analysis-only source reads actual PCM at playback time")
        precondition(source.snapshot(at:0.1,volume:0,playing:true).allSatisfy{$0 == 0})
        precondition(source.snapshot(at:0.1,volume:1,playing:false).allSatisfy{$0 == 0})
        source.stop()
        let label = SceneTextNode(text:"12",font:.systemFont(ofSize:30),color:.white,
                                  size:CGSize(width:165,height:140),padding:CGSize(width:32,height:32),
                                  horizontal:"right",vertical:"center")
        let baseline = label.position.y
        let edge = label.position.x
        precondition(abs(edge) < 0.001 && label.layoutBounds.maxX == 0 && label.horizontalAlignmentMode == .right)
        label.updateText("59")
        precondition(label.position.y == baseline && abs(label.position.x - edge) < 0.001,
                     "Clock ticks preserve text alignment and the font baseline")
        let trail = SceneRopeTrail(definition:["maxcount":10,"emitter":[["rate":100]],"initializer":[["name":"lifetimerandom","min":1,"max":1]]])
        for _ in 0..<100 { trail.update(delta:0.1,cursor:CGPoint(x:20,y:40),enabled:true) }
        precondition(trail.particleCount <= 10)
        for _ in 0..<20 { trail.update(delta:0.1,cursor:nil,enabled:false) }
        precondition(trail.particleCount == 0)
        let smoothTrail = SceneRopeTrail(definition:["maxcount":100,"emitter":[["rate":25]],"initializer":[["name":"lifetimerandom","min":1,"max":1]]])
        smoothTrail.update(delta:0.04,cursor:CGPoint(x:10,y:20),enabled:true)
        let count = smoothTrail.particleCount
        smoothTrail.update(delta:1.0/120,cursor:CGPoint(x:40,y:20),enabled:true)
        precondition(smoothTrail.particleCount == count && smoothTrail.renderedTip == CGPoint(x:40,y:20))
        precondition(smoothTrail.segmentCount >= 5, "Live head advances between 25 Hz emission ticks")
        smoothTrail.update(delta:0.01,cursor:nil,enabled:false)
        smoothTrail.update(delta:0.01,cursor:CGPoint(x:500,y:500),enabled:true)
        precondition(smoothTrail.segmentCount == 0, "Leaving/reentering does not bridge disconnected paths")
        smoothTrail.update(delta:0.008,cursor:CGPoint(x:560,y:500),enabled:true)
        smoothTrail.update(delta:0.008,cursor:CGPoint(x:560,y:560),enabled:true)
        precondition(smoothTrail.renderedVertices.contains { $0.x > 560 && $0.y > 500 && $0.y < 560 },
                     "Fast turns are curved instead of connecting emission points with straight chords")
        precondition(smoothTrail.renderedVertices.last == CGPoint(x:560,y:560))
        let started = Date()
        for frame in 0..<600 {
            smoothTrail.update(delta:1.0/120,cursor:CGPoint(x:Double(frame),y:sin(Double(frame)*0.1)*100),enabled:true)
        }
        precondition(smoothTrail.children.count <= 1600, "Segment pool remains bounded")
        print("Rope CPU update: \(Date().timeIntervalSince(started) / 600 * 1000) ms/frame (600 frames)")

        if CommandLine.arguments.count > 1 {
            errors.removeAll()
            let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
            let scene = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let raw = scene["objects"] as! [[String:Any]]
            context.objectForKeyedSubscript("loadScene")!.call(withArguments:[raw,[:],1920,1080])
            context.objectForKeyedSubscript("applyProperties")!.call(withArguments:[["appdockenabled":true]])
            for i in 0..<120 { context.objectForKeyedSubscript("tick")!.call(withArguments:[1.0/60,Double(i)*10,50]) }
            precondition(errors.isEmpty, "Package script failures: \(errors)")
            check("layers.filter(l=>/^Launcher /.test(l.name)).length===24")
            check("layers.filter(l=>['时','分','秒'].includes(l.name)).every(l=>/^\\d{2}$/.test(l.text))")
            check("layers.filter(l=>/^Launcher /.test(l.name)).every(l=>Number.isFinite(l.origin.x)&&Number.isFinite(l.scale.x))")
            context.objectForKeyedSubscript("cursorEvent")!.call(withArguments:["cursorDown",151,10,10])
            context.objectForKeyedSubscript("cursorEvent")!.call(withArguments:["cursorMove",151,30,40])
            check("Math.abs(thisScene.getLayer(146).origin.x-964.45465)<0.01")
            check("Math.abs(thisScene.getLayer(146).origin.y-65.57890)<0.01")
            context.objectForKeyedSubscript("cursorEvent")!.call(withArguments:["cursorUp",151,30,40])
            print("Real package scripts: passed (120 frames, clock + 24 launchers)")
        }
        print("Scene runtime, errors, properties, lifecycle, shortcuts, PCM spectrum and bounded rope: passed")
    }
}
