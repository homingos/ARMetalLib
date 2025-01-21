//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 21/01/25.
//
import Metal
import MetalKit
import AVFoundation

struct BlurUniforms {
    var texelSize: SIMD2<Float>
    var radius: Float
    var sigma: Float
}

public class VideoBlurRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var texture: MTLTexture?
    private var intermediateTexture: MTLTexture?  // For two-pass blur
    private var renderPassDescriptor: MTLRenderPassDescriptor
    private var videoOutput: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    
    // Pipeline states
    private var horizontalBlurPipelineState: MTLRenderPipelineState?
    private var verticalBlurPipelineState: MTLRenderPipelineState?
    private var finalRenderPipelineState: MTLRenderPipelineState?
    
    // Uniforms buffer
    private var blurUniforms: BlurUniforms
    private var uniformsBuffer: MTLBuffer?
    
    // Vertex buffer
    private var vertexBuffer: MTLBuffer?
    
    init?(width: Int, height: Int, blurRadius: Float = 10.0) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        self.renderPassDescriptor = MTLRenderPassDescriptor()
        
        // Initialize blur uniforms
        self.blurUniforms = BlurUniforms(
            texelSize: SIMD2<Float>(1.0 / Float(width), 1.0 / Float(height)),
            radius: blurRadius,
            sigma: blurRadius / 3.0
        )
        
        // Create uniforms buffer
        let uniformsSize = MemoryLayout<BlurUniforms>.size
        self.uniformsBuffer = device.makeBuffer(length: uniformsSize, options: .cpuCacheModeWriteCombined)
        
        // Setup video output
        let pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as [String: Any]
        
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        
        // Create texture cache
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        self.textureCache = textureCache
        
        // Setup textures and pipelines
        setupTextures(width: width, height: height)
        setupVertexBuffer()
        setupRenderPipelines()
        updateUniformsBuffer()
    }
    
    private func setupTextures(width: Int, height: Int) {
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type2D
        textureDescriptor.width = width
        textureDescriptor.height = height
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        
        texture = device.makeTexture(descriptor: textureDescriptor)
        intermediateTexture = device.makeTexture(descriptor: textureDescriptor)
        
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }
    
    private func setupVertexBuffer() {
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 0.0, 1.0,  // position(x,y) + texCoord(u,v)
             1.0, -1.0, 0.0, 1.0, 1.0,
            -1.0,  1.0, 0.0, 0.0, 0.0,
             1.0,  1.0, 0.0, 1.0, 0.0
        ]
        
        let vertexSize = vertices.count * MemoryLayout<Float>.size
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexSize, options: .cpuCacheModeWriteCombined)
    }
    
    private func setupRenderPipelines() {
        guard let library = device.makeDefaultLibrary(bundle: Bundle.module) else { return }
        
        // Horizontal blur pipeline
        if let vertexFunction = library.makeFunction(name: "vertexShaderBlurHorizontal"),
           let fragmentFunction = library.makeFunction(name: "fragmentShaderBlurHorizontal") {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            horizontalBlurPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        
        // Vertical blur pipeline
        if let vertexFunction = library.makeFunction(name: "vertexShaderBlurVertical"),
           let fragmentFunction = library.makeFunction(name: "fragmentShaderBlurVertical") {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            verticalBlurPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        
        // Final render pipeline
        if let vertexFunction = library.makeFunction(name: "vertexShader"),
           let fragmentFunction = library.makeFunction(name: "fragmentShader") {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            finalRenderPipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
    }
    
    private func updateUniformsBuffer() {
        guard let buffer = uniformsBuffer else { return }
        memcpy(buffer.contents(), &blurUniforms, MemoryLayout<BlurUniforms>.size)
    }
    
    func processVideoFrame(player: AVPlayer, completion: @escaping (MTLTexture?) -> Void) {
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
              let intermediateTexture = intermediateTexture,
              let finalTexture = texture else {
            completion(nil)
            return
        }
        
        // Horizontal pass
        renderPassDescriptor.colorAttachments[0].texture = intermediateTexture
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
           let pipelineState = horizontalBlurPipelineState {
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(sourceTexture, index: 0)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
        
        // Vertical pass
        renderPassDescriptor.colorAttachments[0].texture = finalTexture
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
           let pipelineState = verticalBlurPipelineState {
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(intermediateTexture, index: 0)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            completion(self?.texture)
        }
        
        commandBuffer.commit()
    }
    
    func setBlurRadius(_ radius: Float) {
        blurUniforms.radius = radius
        blurUniforms.sigma = radius / 3.0
        updateUniformsBuffer()
    }
}

// VideoProcessor class remains the same
//class VideoProcessor {
//    private let renderer: VideoBlurRenderer?
//    private var player: AVPlayer?
//    
//    init(width: Int, height: Int) {
//        renderer = VideoBlurRenderer(width: width, height: height)
//    }
//    
//    func setupPlayer(url: URL) {
//        let asset = AVAsset(url: url)
//        let playerItem = AVPlayerItem(asset: asset)
//        player = AVPlayer(playerItem: playerItem)
//        
//        if let videoOutput = renderer?.videoOutput {
//            playerItem.add(videoOutput)
//        }
//    }
//    
//    func processNextFrame(completion: @escaping (MTLTexture?) -> Void) {
//        guard let player = player,
//              let renderer = renderer else {
//            completion(nil)
//            return
//        }
//        
//        renderer.processVideoFrame(player: player, completion: completion)
//    }
//    
//    func setBlurRadius(_ radius: Float) {
//        renderer?.setBlurRadius(radius)
//    }
//}
