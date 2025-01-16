//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 16/01/25.
//

import Metal
import UIKit

enum ParallaxType: Sendable {
    case Image
    case Video
}

/// class for holding Parallax Layer images data
/// Used in Metal AR
final class LayerImage: @unchecked Sendable {
    let id: Int
    let offset: SIMD3<Float>
    let image: UIImage?
    var texture: MTLTexture?
    var scale: Float
    let type: ParallaxType
    
    // Initializer
    init(id: Int, offset: SIMD3<Float>, image: UIImage?, texture: MTLTexture? = nil, scale: Float = 1.0, type: ParallaxType = .Image) {
        self.id = id
        self.offset = offset
        self.image = image
        self.texture = texture
        self.scale = scale
        self.type = type
    }
    
    func copy() -> LayerImage {
        return LayerImage(id: id, offset: offset, image: image, texture: texture, scale: scale, type: type)
    }
    
    var description: String {
        let offsetString = "x: \(offset.x), y: \(offset.y), z: \(offset.z)"
        let imageDescription = image != nil ? "Image present" : "No image"
        let textureDescription = texture != nil ? "Texture present" : "No texture"
        return """
        LayerImage:
        - ID: \(id)
        - Offset: \(offsetString)
        - Scale: \(scale)
        - Type: \(type)
        - Image: \(imageDescription)
        - Texture: \(textureDescription)
        """
    }
}
