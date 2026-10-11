import SpriteKit

/// Packed 64-band data texture consumed by the phase-two material pipeline.
enum SceneSpectrumTexture {
    static func texture(_ bins: [Float]) -> SKTexture {
        var bytes = [UInt8](repeating:0,count:64*4)
        for i in 0..<64 {
            let value = i < bins.count && bins[i].isFinite ? bins[i] : 0
            bytes[i*4] = UInt8(max(0,min(1,value))*255)
            bytes[i*4+3] = 255
        }
        let texture = SKTexture(data:Data(bytes),size:CGSize(width:64,height:1))
        texture.filteringMode = .nearest
        return texture
    }

}
