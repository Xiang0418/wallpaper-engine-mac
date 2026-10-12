import AppKit
import SpriteKit
import Metal

@main struct TrailBenchmark {
    static func main() throws {
        _ = NSApplication.shared
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let renderer = SKRenderer(device: device)
        print("device=\(device.name), 1920x1080, 30 fps simulation, 240 Hz input; milliseconds/frame; synchronous offscreen rendering")
        for speed in [1.0, 10.0] {
            for enabled in [false, true] {
                let scene = SKScene(size: CGSize(width: 1920, height: 1080))
                scene.backgroundColor = .black
                let trail = SceneRopeTrail(definition: ["maxcount":500,"emitter":[["rate":25]],"initializer":[["name":"lifetimerandom","min":1.5,"max":1.5],["name":"sizerandom","min":5.0,"max":5.0],["name":"colorrandom","max":"255 132 193"]],"operator":[["name":"sizechange","startvalue":3.0,"endvalue":0.0,"endtime":0.5]]])
                scene.addChild(trail); renderer.scene = scene
                var cpu:[Double]=[], submit:[Double]=[], gpu:[Double]=[], total:[Double]=[]
                for frame in 0..<210 {
                    try autoreleasepool {
                        let start = CACurrentMediaTime()
                        for event in 1...8 {
                            let time = Double(frame * 8 + event)/240
                            let p = CGPoint(x:960+180*cos(time*speed*2 * .pi),y:540+180*sin(time*speed*2 * .pi))
                            trail.update(delta:1.0/240,cursor:p,enabled:enabled,render:false)
                        }
                        let endTime = Double(frame + 1)/30
                        trail.update(delta:0,cursor:CGPoint(x:960+180*cos(endTime*speed*2 * .pi),y:540+180*sin(endTime*speed*2 * .pi)),enabled:enabled)
                        let updated = CACurrentMediaTime()
                        renderer.update(atTime:Double(frame)/30)
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture=texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].storeAction = .store
                        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
                        let command = queue.makeCommandBuffer()!
                        renderer.render(withViewport:CGRect(x:0,y:0,width:1920,height:1080),commandBuffer:command,renderPassDescriptor:pass)
                        let submitted = CACurrentMediaTime()
                        command.commit(); command.waitUntilCompleted()
                        precondition(command.status == .completed)
                        if frame >= 60 {
                            cpu.append((updated-start)*1000); submit.append((submitted-updated)*1000)
                            gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
                            total.append((CACurrentMediaTime()-start)*1000)
                        }
                        if frame == 209 && enabled {
                            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1920,pixelsHigh:1080,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1920*4,bitsPerPixel:32)!
                            texture.getBytes(bitmap.bitmapData!,bytesPerRow:1920*4,from:MTLRegionMake2D(0,0,1920,1080),mipmapLevel:0)
                            // BGRA -> RGBA for PNG inspection.
                            for i in stride(from:0,to:1920*1080*4,by:4) { let b=bitmap.bitmapData![i];bitmap.bitmapData![i]=bitmap.bitmapData![i+2];bitmap.bitmapData![i+2]=b }
                            let prefix=CommandLine.arguments.dropFirst().first ?? "/tmp/trail"
                            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(prefix)-\(Int(speed)).png"))
                        }
                    }
                }
                func avg(_ a:[Double])->Double { a.reduce(0,+)/Double(a.count) }
                print(String(format:"speed=%.0f enabled=%@ segments=%d update=%.3f submit=%.3f gpu=%.3f wall=%.3f p95=%.3f",speed,String(enabled),trail.segmentCount,avg(cpu),avg(submit),avg(gpu),avg(total),total.sorted()[Int(Double(total.count)*0.95)]))
            }
        }
    }
}
