//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 16/01/25.
//

import Metal
import UIKit
import AVFoundation
import CoreVideo
import MetalKit

public enum ParallaxType: Sendable {
    case Image
    case Video
    case Model3D
}

public enum ParallaxContent {
    case image(UIImage)
    case video(AVPlayerItemVideoOutput?, AVPlayer)
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
public class LayerImage: @unchecked Sendable {
    let id: Int
    var textureCache: CVMetalTextureCache?
    let offset: SIMD3<Float>
    private(set) var content: ParallaxContent
    var texture: MTLTexture?
    var scale: Float
    
    // Video-specific properties
    private var videoPixelBuffer: CVPixelBuffer?
    private var currentVideoTexture: CVMetalTexture?
    private var timeObserverToken: Any?
    private var statusObserver: NSKeyValueObservation?
    
    var videoPlaybackObservers: [Int: Any] = [:]
    
    // Public getter for AVPlayer
    public var avPlayer: AVPlayer? {
        if case .video(_, let player) = content {
            return player
        }
        return nil
    }
    
    // Video state management
    private(set) var isVideoSetup: Bool = false
    
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
        if case .video(let playerVideoOutput, let avplayer) = content {
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
                            scale: Float = 1.0) {
        self.init(id: id,
                  offset: offset,
                  content: .video(videoPlayerOutput, avplayer),
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
        if case .video(_, _) = content {
            content = .video(output, player)
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
    
    deinit {
        cleanup()
    }
}

extension LayerImage {
    
    public func setupVideoContent(with url: URL, device: MTLDevice) {
        // Create AVPlayer and AVPlayerItem
        let player = AVPlayer(url: url)
        let playerItem = player.currentItem
        
        // Create texture cache synchronously if needed
        if self.textureCache == nil {
            var newTextureCache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &newTextureCache)
            self.textureCache = newTextureCache
        }
        
        // Create video output on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Create video output
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            
            playerItem?.add(videoOutput)
            
            // Update content
            self.content = .video(videoOutput, player)
            self.isVideoSetup = true
            
            // Set up time observer for frame updates
            let interval = CMTime(seconds: 1.0/30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.updateVideoFrame(at: time)
            }
        }
    }
    
    private func updateVideoFrame(at time: CMTime) {
        guard case .video(let videoOutput?, _) = content else { return }
        
        if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            self.videoPixelBuffer = pixelBuffer
            // Note: The actual texture update will happen in the draw call
        }
    }
    
    // Method to update video texture during render
    func updateVideoTexture() -> MTLTexture? {
        guard let pixelBuffer = videoPixelBuffer,
              let textureCache = textureCache else { return nil }
        
        var texture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texture
        )
        
        if let cvTexture = texture {
            currentVideoTexture = cvTexture
            return CVMetalTextureGetTexture(cvTexture)
        }
        return nil
    }
    
    func cleanup() {
        if let token = timeObserverToken,
           case .video(_, let player) = content {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        statusObserver?.invalidate()
        statusObserver = nil
        videoPixelBuffer = nil
        currentVideoTexture = nil
    }
    
    public func playVideo() {
        DispatchQueue.main.async {
            if let player = self.avPlayer {
                player.play()
            }
        }
    }
    
    public func pauseVideo() {
        DispatchQueue.main.async {
            if let player = self.avPlayer {
                player.pause()
            }
        }
    }
    
    public func seekVideo(for layer: LayerImage, to time: CMTime) {
        if let player = layer.avPlayer {
            player.seek(to: time)
        }
    }
    
    // MARK: - Loop Control
    
    public func setVideoLoop(for layer: LayerImage, shouldLoop: Bool) {
        
        guard let avPlayer = layer.avPlayer else { return }
        NotificationCenter.default.removeObserver(self,
                                                  name: .AVPlayerItemDidPlayToEndTime,
                                                  object: avPlayer.currentItem)
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { [weak self] notification in
            guard let strongSelf = self else { return }
            
            if shouldLoop {
                // play from beginning
//                self?.seekVideo(for: layer, to: .zero)
//                self?.playVideo(for: layer)
            }
            
//            self.videoDelegate?.videoDidFinishPlaying(layerId: layerId)
        }
    }
}
