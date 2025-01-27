//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 16/01/25.
//

import Metal
import UIKit
import AVFoundation

public enum ParallaxType: Sendable {
    case Image
    case Video
    case Model3D
}

public enum ParallaxContent {
    case image(UIImage)
    case video(AVPlayerItemVideoOutput?, AVPlayer, VideoType)
    case model(URL)  // URL to your 3D model file
    
    var contentType: ParallaxType {
        switch self {
        case .image: return .Image
        case .video: return .Video
        case .model: return .Model3D
        }
    }
}

/// class for holding Parallax Layer images data
/// Used in Metal AR
public final class LayerImage: @unchecked Sendable {
    let id: Int
    var textureCache: CVMetalTextureCache?
    let offset: SIMD3<Float>
    private(set) var content: ParallaxContent
    var texture: MTLTexture?
    var scale: Float
    
    // Computed property to access the type
    var type: ParallaxType {
        return content.contentType
    }
    
    // Convenience accessor for image content
    var image: UIImage? {
        if case .image(let img) = content {
            return img
        }
        return nil
    }
    
    // Convenience accessor for video content
    var videoPlayerOutput: (AVPlayerItemVideoOutput?, AVPlayer?) {
        if case .video(let playerVideoOutput, let avplayer, let videoType) = content {
            return (playerVideoOutput, avplayer)
        }
        return (nil, nil)
    }
    
    // Convenience accessor for model content
    var modelURL: URL? {
        if case .model(let url) = content {
            return url
        }
        return nil
    }
    
    // Initializer with ParallaxContent
    public init(id: Int,
                offset: SIMD3<Float>,
                content: ParallaxContent,
                texture: MTLTexture? = nil,
                scale: Float = 1.0) {
        self.id = id
        self.offset = offset
        self.content = content
        self.texture = texture
        self.scale = scale
    }
    
    // Convenience initializer for images
    public convenience init(id: Int,
                            offset: SIMD3<Float>,
                            image: UIImage,
                            texture: MTLTexture? = nil,
                            scale: Float = 1.0) {
        self.init(id: id,
                  offset: offset,
                  content: .image(image),
                  texture: texture,
                  scale: scale)
    }
    
    // Convenience initializer for videos
    public convenience init(id: Int,
                            offset: SIMD3<Float>,
                            videoPlayerOutput: AVPlayerItemVideoOutput?,
                            avplayer: AVPlayer,
                            texture: MTLTexture? = nil,
                            scale: Float = 1.0, videoType: VideoType) {
        self.init(id: id,
                  offset: offset,
                  content: .video(videoPlayerOutput, avplayer, videoType),
                  texture: texture,
                  scale: scale)
    }
    
    func copy() -> LayerImage {
        return LayerImage(id: id,
                          offset: offset,
                          content: content,
                          texture: texture,
                          scale: scale)
    }
    
    public func setVideoPlayerOutput(_ output: AVPlayerItemVideoOutput, player: AVPlayer) {
        if case .video(_, _, _) = content {
            content = .video(output, player, .normal)
            print("content set to \(content)")
        } else {
            print("Warning: Cannot set video output - content is not of type video")
        }
    }
    
    var description: String {
        let offsetString = "x: \(offset.x), y: \(offset.y), z: \(offset.z)"
        let contentDescription: String
        switch content {
        case .image: contentDescription = "Image"
        case .video: contentDescription = "Video"
        case .model: contentDescription = "3D Model"
        }
        let textureDescription = texture != nil ? "Texture present" : "No texture"
        
        return """
        LayerImage:
        - ID: \(id)
        - Offset: \(offsetString)
        - Scale: \(scale)
        - Type: \(type)
        - Content: \(contentDescription)
        - Texture: \(textureDescription)
        """
    }
}
