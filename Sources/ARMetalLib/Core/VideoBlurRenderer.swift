//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 21/01/25.
//
import Metal
import MetalKit
import AVFoundation
import MetalPerformanceShaders

struct BlurUniforms {
    var texelSize: SIMD2<Float>
    var radius: Float
    var sigma: Float
}

public class VideoBlurRenderer {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var texture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private var boxFilter: MPSImageBox
    
    public init?(width: Int, height: Int, blurRadius: Float = 10.0) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Initialize box blur filter
        self.boxFilter = MPSImageBox(device: device, kernelWidth: Int(blurRadius), kernelHeight:  Int(blurRadius))
        
        // Create texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        self.textureCache = textureCache
        
        // Setup texture
        setupTexture(width: width, height: height)
    }
    
    private func setupTexture(width: Int, height: Int) {
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2D
        textureDescriptor.width = width
        textureDescriptor.height = height
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]  // Added shaderWrite
        
        texture = device.makeTexture(descriptor: textureDescriptor)
    }
    
    public func processVideoFrame(player: AVPlayer, videoOutput: AVPlayerItemVideoOutput, completion: @escaping (MTLTexture?) -> Void) {
        guard let currentItem = player.currentItem else {
            completion(nil)
            return
        }
        
        let currentTime = player.currentTime()
        
        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime) else {
            completion(nil)
            return
        }

        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else {
            completion(nil)
            return
        }
        
        processPixelBuffer(pixelBuffer, completion: completion)
    }
    
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, completion: @escaping (MTLTexture?) -> Void) {
        guard let textureCache = textureCache else {
            completion(nil)
            return
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        
        guard result == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
            completion(nil)
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let finalTexture = texture else {
            completion(nil)
            return
        }
        
        // Apply box blur
        boxFilter.encode(commandBuffer: commandBuffer,
                        sourceTexture: sourceTexture,
                        destinationTexture: finalTexture)
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            completion(self?.texture)
        }
        
        commandBuffer.commit()
    }
    
    func setBlurRadius(_ radius: Float) {
        boxFilter = MPSImageBox(device: device, kernelWidth: Int(radius), kernelHeight: Int(radius))
    }
}
