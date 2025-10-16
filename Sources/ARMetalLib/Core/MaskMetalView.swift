//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 24/01/25.
//

import Foundation
import MetalKit
import AVFoundation

public enum TrackingStatus{
    case tracking
    case trackingLost
    case notRecoganized
}

public class MaskMetalView: MTKView {
    private var commandQueue: MTLCommandQueue!
    private var renderPipelineState: MTLRenderPipelineState!
    private var vertexBuffers: [MTLBuffer] = []
    private var indexBuffers: [MTLBuffer] = []
    private var maskVertexBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var samplerState: MTLSamplerState?
    
    private var anchorTransform: simd_float4x4?
    private var cameraTransform: simd_float4x4?
    private var projectionMatrix: simd_float4x4?
    
    private var layerImages: [MaskLayer] = []
    private var layerImageDic: [Int: MaskLayer] = [:]
    
    private var stencilState: MTLDepthStencilState?
    private var maskRenderPipelineState: MTLRenderPipelineState!
    
    private var writeStencilState: MTLDepthStencilState?
    private var testStencilState: MTLDepthStencilState?
    
//    weak var viewControllerDelegate: ARMetalViewDelegate?
    private var videoExtent: CGSize?
    private var imageTargetExtent: CGSize?
    private var maskExtent: CGSize?
    private var playbackScale: Float? = 1.0
    private var maskOffset: SIMD3<Float> = .zero
    
    private var isBufferUpdated: Bool = false
    private var maskMode: MaskMode = .none
    private var maskTexture: MTLTexture?
    private var videoType: VideoType = .normal
    // for video player output dont replace or add new video output use the existing output
    private var imageTrackingStatus: TrackingStatus = .notRecoganized
    
    //MARK: Full screen buffer
    private var fullscreenExpBuffer: [MTLBuffer] = []
    private var drawBufferMaskFullscreen: MTLBuffer?
    
    // MARK: static image that is not affected by the mask stencil
    private var nonStencilPipelineImage: MTLRenderPipelineState!
    private var nonStencilPipelineLayer: MTLRenderPipelineState!
    private var nonStencilImageBuffer: MTLBuffer!
    private var overlayImageBuffer: MTLBuffer!
    
    private var isUpdatingLayers: Bool = false
    
    //airboard related variables
    private var isAirboardMode: Bool = false
    private var airboardVelocity: simd_float3 = simd_float3(0, 0, 0) // For smooth positioning
    private var airboardTargetPosition: simd_float3 = simd_float3(0, 0, -3.0)
    private var airboardCurrentPosition: simd_float3 = simd_float3(0, 0, -3.0)
    private var airboardExpBuffer: [MTLBuffer] = []
    private var drawBufferMaskAirboard: MTLBuffer?
    private var nonStencilAirboardBuffer: MTLBuffer!
    private var airboardWorldTransform: simd_float4x4 = matrix_identity_float4x4
    private var lastCameraTransform: simd_float4x4?
    
    private let viewAps: Float
    
    public init?(frame: CGRect, device: MTLDevice, maskMode: MaskMode, videoType: VideoType = .normal) {
        print("init MaskMetalView")
        self.viewAps = Float(frame.width / frame.height)
        super.init(frame: frame, device: device)
        self.device = device
        
        // Configure view properties
        self.colorPixelFormat = .bgra8Unorm
        self.depthStencilPixelFormat = .depth32Float_stencil8
        self.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.framebufferOnly = false
        self.maskMode = maskMode
        self.videoType = videoType
        // true if you want to update the draw call manually using setNeedsDisplay()
        self.enableSetNeedsDisplay = true
        
        setupMetal()
        setupMaskConfiguration(maskMode: maskMode)
        setupStaticRectangle()
//        self.viewControllerDelegate = viewControllerDelegate
        //        setupDefaultVertices()
    }
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
//    private struct StaticRectVertex {
//        var position: SIMD3<Float>
//        var texCoord: SIMD2<Float>
//    }
    
    public func getLayerCount() -> Int{
        return layerImageDic.count
    }
    private func setupStaticRectangle() {
        // Create vertices for the static rectangle, flipped vertically (positions only)
        let vertices: [Vertex] = [
            Vertex(position: SIMD3<Float>(-0.5, -0.5, 0.0), texCoord: SIMD2<Float>(0.0, 1.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(0.5, -0.5, 0.0), texCoord: SIMD2<Float>(1.0, 1.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(-0.5, 0.5, 0.0), texCoord: SIMD2<Float>(0.0, 0.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(0.5, 0.5, 0.0), texCoord: SIMD2<Float>(1.0, 0.0), textureIndex: 0)
        ]
            
        nonStencilImageBuffer = device?.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride,
            options: .storageModeShared
        )
        let overlayVertices: [Vertex] = [
            Vertex(position: SIMD3<Float>(-0.5, -0.5, 0.0), texCoord: SIMD2<Float>(0.0, 0.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(0.5, -0.5, 0.0), texCoord: SIMD2<Float>(1.0, 0.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(-0.5, 0.5, 0.0), texCoord: SIMD2<Float>(0.0, 1.0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(0.5, 0.5, 0.0), texCoord: SIMD2<Float>(1.0, 1.0), textureIndex: 0)
        ]
        
        overlayImageBuffer = device?.makeBuffer(
            bytes: overlayVertices,
            length: vertices.count * MemoryLayout<Vertex>.stride,
            options: .storageModeShared
        )
            
        createNonStecilPipeline()
        createNonStecilPipelineImage()
    }
    
    private func updateFullScreenImage(targetFullscreenExtent: CGSize){
        
        guard let nonStencilImageBuffer, let overlayImageBuffer else { return }
        let sourceBuffer = overlayImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let destBuffer = nonStencilImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
        
        for i in 0..<4{
            destBuffer[i] = sourceBuffer[i]
            destBuffer[i].position.y *= viewAps
        }
    }
    
    private func prepareFullscreenImage(scale: Float, offset: SIMD2<Float>){
        guard let nonStencilImageBuffer else { return }
        let bufferVertex = nonStencilImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
        
        for i in 0..<4 {
            bufferVertex[i].position *= scale
            bufferVertex[i].position += SIMD3(offset.x, offset.y, 0.0)
        }
    }
    public func getCurrentRenderTransform() -> simd_float4x4? {
        return self.anchorTransform
    }

    private func createNonStecilPipeline() {
        guard let device = self.device else { return }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle.module)
            guard let vertexFunction = library.makeFunction(name: "vertexShader") else {
                return
            }
            var fragmentFunction = library.makeFunction(name: "fragmentShader")
            
            switch self.videoType {
            case .normal:
                fragmentFunction = library.makeFunction(name: "fragmentShader")
            case .alpha(config: let config):
                switch config {
                case .LR:
                    fragmentFunction = library.makeFunction(name: "fragmentShaderSplitTextureLR")
                case .TD:
                    fragmentFunction = library.makeFunction(name: "fragmentShaderSplitTextureTD")
                }
            }
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Static Rectangle Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            
            // Configure blending
            let attachment = pipelineDescriptor.colorAttachments[0]
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .sourceAlpha
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            // Configure vertex descriptor for static rectangle
            let vertexDescriptor = MTLVertexDescriptor()
            
            // Position attribute
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            
            // Texture coordinate attribute
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            
            // Texture index
            vertexDescriptor.attributes[2].format = .uint
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
            vertexDescriptor.attributes[2].bufferIndex = 0
            
            // Buffer layout
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
            
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            nonStencilPipelineLayer = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create static rectangle pipeline: \(error)")
        }
    }
    
    private func createNonStecilPipelineImage() {
        guard let device = self.device else { return }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle.module)
            guard let vertexFunction = library.makeFunction(name: "vertexShader"), let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
                return
            }
            
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Static Rectangle Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            
            // Configure blending
            let attachment = pipelineDescriptor.colorAttachments[0]
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .sourceAlpha
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            // Configure vertex descriptor for static rectangle
            let vertexDescriptor = MTLVertexDescriptor()
            
            // Position attribute
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            
            // Texture coordinate attribute
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            
            // Texture index
            vertexDescriptor.attributes[2].format = .uint
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
            vertexDescriptor.attributes[2].bufferIndex = 0
            
            // Buffer layout
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
            
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            nonStencilPipelineImage = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create static rectangle pipeline: \(error)")
        }
    }
    
    private func setupMaskConfiguration(maskMode: MaskMode){
        switch maskMode {
        case .none:
            break
        case .Image(let image, let offset):
            updateMaskImage(image)
            maskOffset = offset
        case .VideoPlayer(let videoOutput):
            // TODO: Mask as a video
            break
        }
    }
    
    /// Use for updating and setting the LayerImage
    public func updateLayerImage(layerImage: [Int: MaskLayer]){
        self.layerImageDic = layerImage
        print("Recieved Overlay layerImage: \(layerImage)")
        setLayerImage(layerImage: layerImage)
    }
    
//    func setDelegate(controller: ARMetalViewDelegate){
//        self.viewControllerDelegate = controller
//    }
    /// Updated the Extent of the rendering Plane
    public func setTargetSize(videoExtent: CGSize, maskTargetSize: CGSize, playbackScale: Float = 1.0, imageTargetExtent: CGSize){
        self.videoExtent = videoExtent
        self.imageTargetExtent = imageTargetExtent
        maskExtent = maskTargetSize
        self.playbackScale = playbackScale
        
        updateVertexBuffer(newExtent: videoExtent)
        updateMaskVertices(maskVertexBuffer, maskTargetSize: maskTargetSize)
        updateOverlayVertices(targetSize: imageTargetExtent)
        // calculate the fullscreen Layer coordinates with mask for the scale factor to fit
        updateFullscreenCoordinates()
        updateAirboardCoordinates()
    }
    
    private func updateFullscreenCoordinates(){
        var points: [SIMD3<Float>] = []
        
        // Setup the Fullscreen buffer
        setupExpBufferFullscreen()
        setupMaskBufferFullscreen()
        updateFullScreenImage(targetFullscreenExtent: imageTargetExtent!)
        // Experience points
        for (index, layer) in layerImages.enumerated() {
            let id = layer.id
            if id == -1 { continue }
            if index < vertexBuffers.count {
                let vertexBuffer = fullscreenExpBuffer[index]
                let bufferPointer = vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
                
                points.append(bufferPointer[0].position)
                points.append(bufferPointer[1].position)
                points.append(bufferPointer[2].position)
                points.append(bufferPointer[3].position)
            }
        }
        
        // TODO: Target image to the points
//        let maksBuffer = drawBufferMaskFullscreen?.contents().assumingMemoryBound(to: Vertex.self)
//        points.append(maksBuffer![0].position)
//        points.append(maksBuffer![1].position)
//        points.append(maksBuffer![2].position)
//        points.append(maksBuffer![3].position)
        
        // Adding ovlerlay image
        if let nonStencilImageBuffer {
            let overlayBuffer = nonStencilImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
            points.append(overlayBuffer[0].position)
            points.append(overlayBuffer[1].position)
            points.append(overlayBuffer[2].position)
            points.append(overlayBuffer[3].position)
        }

        var value = scaleFactorTofit(points: points, bound: CGSize(width: 0.95, height: 0.9))
        print("new scale: \(value)")
        
        // Mask
        preparemaskBufferFullscreen(scale: value.scale * (playbackScale ?? 1.0), offset: value.offset )
        
        // Experience Content
        prepareExpBufferFullscreen(scale: value.scale * (playbackScale ?? 1.0), offset: value.offset )
        
        // setup fullscreen scale
        prepareFullscreenImage(scale: value.scale * (playbackScale ?? 1.0), offset: value.offset)
        
    }
    private func updateAirboardCoordinates(){
        var points: [SIMD3<Float>] = []
        
        setupExpBufferAirboard()
        setupMaskBufferAirboard()
        updateAirboardImage(targetAirboardExtent: imageTargetExtent!)
        
        // Experience points for airboard positioning
        for (index, layer) in layerImages.enumerated() {
            let id = layer.id
            if id == -1 { continue }
            if index < vertexBuffers.count {
                let vertexBuffer = airboardExpBuffer[index]
                let bufferPointer = vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
                
                points.append(bufferPointer[0].position)
                points.append(bufferPointer[1].position)
                points.append(bufferPointer[2].position)
                points.append(bufferPointer[3].position)
            }
        }
        
        if let nonStencilAirboardBuffer {
            let airboardBuffer = nonStencilAirboardBuffer.contents().assumingMemoryBound(to: Vertex.self)
            points.append(airboardBuffer[0].position)
            points.append(airboardBuffer[1].position)
            points.append(airboardBuffer[2].position)
            points.append(airboardBuffer[3].position)
        }

        var value = scaleFactorTofit(points: points, bound: CGSize(width: 0.6, height: 0.5))
        print("airboard scale: \(value)")
        
        // Apply scaling to keep content properly sized and centered
        preparemaskBufferAirboard(scale: value.scale * 0.8 * (playbackScale ?? 1.0), offset: value.offset)
        prepareExpBufferAirboard(scale: value.scale * 0.8 * (playbackScale ?? 1.0), offset: value.offset)
        prepareAirboardImage(scale: value.scale * 0.8 * (playbackScale ?? 1.0), offset: value.offset)
    }
    private func setupMaskBufferAirboard() {
        guard let device, let maskVertexBuffer else { return }
        if drawBufferMaskAirboard == nil {
            drawBufferMaskAirboard = device.makeBuffer(
                length: maskVertexBuffer.length,
                options: .storageModeShared
            )
        }
        
        let sourcePointer = maskVertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let destPointer = drawBufferMaskAirboard!.contents().assumingMemoryBound(to: Vertex.self)
        
        // CHANGE: Airboard positioning doesn't need aspect ratio correction like fullscreen
        for i in 0..<4 {
            destPointer[i] = sourcePointer[i]
            // Keep original proportions for airboard mode
        }
    }

    private func setupExpBufferAirboard() {
        guard let device else { return }
        if airboardExpBuffer.isEmpty {
            for vertexBuffer in vertexBuffers {
                if let newBuffer = device.makeBuffer(
                    length: vertexBuffer.length,
                    options: .storageModeShared
                ) {
                    airboardExpBuffer.append(newBuffer)
                }
            }
        }
        
        for (index, buffer) in airboardExpBuffer.enumerated() {
            let sourcePointer = vertexBuffers[index].contents().assumingMemoryBound(to: Vertex.self)
            let destPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
            
            for i in 0..<4 {
                destPointer[i] = sourcePointer[i]
                // Keep original proportions for airboard
            }
        }
    }

    private func updateAirboardImage(targetAirboardExtent: CGSize){
        guard let overlayImageBuffer else { return }
        
        if nonStencilAirboardBuffer == nil {
            nonStencilAirboardBuffer = device?.makeBuffer(
                length: overlayImageBuffer.length,
                options: .storageModeShared
            )
        }
        
        let sourceBuffer = overlayImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let destBuffer = nonStencilAirboardBuffer.contents().assumingMemoryBound(to: Vertex.self)
        
        for i in 0..<4{
            destBuffer[i] = sourceBuffer[i]
            // No aspect ratio correction needed for airboard
        }
    }

    private func preparemaskBufferAirboard(scale: Float, offset: SIMD2<Float>) -> MTLBuffer? {
        guard let device, let maskVertexBuffer else { return nil}
        if drawBufferMaskAirboard == nil {
            drawBufferMaskAirboard = device.makeBuffer(
                length: maskVertexBuffer.length,
                options: .storageModeShared
            )
        }
        
        let destPointer = drawBufferMaskAirboard!.contents().assumingMemoryBound(to: Vertex.self)
        
        for i in 0..<4 {
            destPointer[i].position *= scale
            destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
        }
        return drawBufferMaskAirboard!
    }

    private func prepareExpBufferAirboard(scale: Float, offset: SIMD2<Float>) -> [MTLBuffer]{
        guard let device else { return []}
        if airboardExpBuffer.isEmpty {
            for vertexBuffer in vertexBuffers {
                if let newBuffer = device.makeBuffer(
                    length: vertexBuffer.length,
                    options: .storageModeShared
                ) {
                    airboardExpBuffer.append(newBuffer)
                }
            }
        }
        
        for (index, buffer) in airboardExpBuffer.enumerated() {
            let destPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
            
            for i in 0..<4 {
                destPointer[i].position *= scale
                destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
            }
        }
        return airboardExpBuffer
    }

    private func prepareAirboardImage(scale: Float, offset: SIMD2<Float>){
        guard let nonStencilAirboardBuffer else { return }
        let bufferVertex = nonStencilAirboardBuffer.contents().assumingMemoryBound(to: Vertex.self)
        
        for i in 0..<4 {
            bufferVertex[i].position *= scale
            bufferVertex[i].position += SIMD3(offset.x, offset.y, 0.0)
        }
    }

    private func updateVertexBuffer(newExtent: CGSize) {
        print("111: updateLayerVertices called with extent: \(newExtent)")
        isBufferUpdated = false
        defer {
            isBufferUpdated = true
            print("111: updateLayerVertices defer called")
        }
        
        for (index, layer) in layerImages.enumerated() {
            if index < vertexBuffers.count {
                let vertexBuffer = vertexBuffers[index]
                let bufferPointer = vertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
                
                let aspectRatio: Float = 1.0
                let zOffset = Float(layer.offset.z) * Float(imageTargetExtent?.width ?? 1.0)
                let xOffset = Float(layer.offset.x) * Float(imageTargetExtent?.width ?? 1.0)
                let yOffset = Float(layer.offset.y) * Float(imageTargetExtent?.height ?? 1.0)
                let scale = layer.scale
                
                // Update x and z components (width and height) of each vertex
                // Vertex 0
                bufferPointer[0].position.x = (-0.5 ) * scale * Float(newExtent.width) + xOffset
                bufferPointer[0].position.y = (-0.5 ) * scale * Float(newExtent.height) + yOffset
                
                // Vertex 1
                bufferPointer[1].position.x = (0.5 ) * scale * Float(newExtent.width) + xOffset
                bufferPointer[1].position.y = (-0.5 ) * scale * Float(newExtent.height) + yOffset
                
                // Vertex 2
                bufferPointer[2].position.x = (-0.5 ) * scale * Float(newExtent.width) + xOffset
                bufferPointer[2].position.y = (0.5 ) * scale * Float(newExtent.height) + yOffset
                
                // Vertex 3
                bufferPointer[3].position.x = (0.5 ) * scale * Float(newExtent.width) + xOffset
                bufferPointer[3].position.y = (0.5 ) * scale * Float(newExtent.height) + yOffset
                
                print("Check this bbb x: \((-0.5 ) * scale * Float(newExtent.width))")
                print("Check this bbb y: \((-0.5 ) * scale * Float(newExtent.height))")
                print("Check this bbb x: \((0.5 ) * scale * Float(newExtent.width))")
                print("Check this bbb y: \((-0.5 ) * scale * Float(newExtent.height))")
            }
        }
    }
    
    private func updateOverlayVertices(targetSize: CGSize) {
        let bufferPointer = overlayImageBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let newExtent = targetSize
        let point: Float = 0.5
        
        bufferPointer[0].position.x = (-point) * Float(newExtent.width)
        bufferPointer[0].position.y = (-point) * Float(newExtent.height)
        
        bufferPointer[1].position.x = (point) * Float(newExtent.width)
        bufferPointer[1].position.y = (-point) * Float(newExtent.height)
        
        bufferPointer[2].position.x = (-point) * Float(newExtent.width)
        bufferPointer[2].position.y = (point) * Float(newExtent.height)
        
        bufferPointer[3].position.x = (point) * Float(newExtent.width)
        bufferPointer[3].position.y = (point) * Float(newExtent.height)
        
        print("Non-stencil vertices updated: \(bufferPointer[0].position) + \(newExtent)")
    }
    
    private func setLayerImage(layerImage: [Int: MaskLayer]){
        guard let device else { return }
        print("check it out updating overlay mask ")
        isUpdatingLayers = true
        defer {
            isUpdatingLayers = false
        }
        layerImages.removeAll()
        let textureLoader = MTKTextureLoader(device: device)
        let textureOptions: [MTKTextureLoader.Option: Any] = [
            .generateMipmaps: true,                     // Enable mipmapping
            .SRGB: false,                               // Linear color space for correct rendering
            .textureUsage: MTLTextureUsage([.shaderRead, .renderTarget]).rawValue,
            .allocateMipmaps: true                      // Allocate space for mipmaps
        ]
        print("111: setlayer image called")
        
        for layer in layerImageDic{
            let imageName = layer.key
            let layerValues = layer.value
            print("layer ids: \(layerValues.id)")
            // TODO: Check for image type and do this
            // or handle for Video
            switch layerValues.content{
                
            case .image(_):
                if let image = layerValues.image {
                        if let texture = loadTextureFromImage(image, device: device) {
                            layerValues.texture = texture
                            print("Layer texture loaded successfully")
                        } else {
                            print("Failed to load texture for layer \(layerValues.id)")
                        }
                    }
            case .video(_, _, let videoType):
                self.videoType = videoType
                print("video type: \(videoType)")
                if let cache = createTextureCache(device: device){
                    layerValues.textureCache = cache
                } else { print("Failed to create texture cache") }
//                CVMetalTextureCacheCreate(nil, nil, device,nil, &layerValues.textureCache)
            case .model(_):
                break
            case .videov2:
                break
            }
            layerImages.append(layerValues)
        }
        // Sort for the render order
        layerImages.sort { $0.offset.y < $1.offset.y }
        for ele in layerImages {
            print("Layers added: \(ele.description)")
        }
        
        setupLayerVertices()
        let maskVertices = createMaskVertices()
        maskVertexBuffer = device.makeBuffer(
            bytes: maskVertices,
            length: maskVertices.count * MemoryLayout<Vertex>.stride,
            options: .storageModeShared
        )
    }
    
    private func setupMetal() {
        guard let device = self.device else {
            print("No Metal device")
            return
        }
        
        // Create command queue
        guard let queue = device.makeCommandQueue() else {
            print("Failed to create command queue")
            return
        }
        commandQueue = queue
        print("Command queue created")
        
        createRenderPipeline()
        createMaskRenderPipeline()
        createStencilState()
        createSamplerState()
        print("all ARMetal view setup")
    }
    
    public func createTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var textureCache: CVMetalTextureCache?
        
        // Set up texture cache attributes
        let textureAttributes = [
            kCVMetalTextureCacheMaximumTextureAgeKey: 1,
            kCVMetalTextureUsage: MTLTextureUsage.shaderRead.rawValue
        ] as [String: Any]
        
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,  // Allocator
            textureAttributes as CFDictionary,  // Cache attributes
            device,              // Metal device
            nil,                // Texture attributes (can be nil)
            &textureCache      // Output texture cache
        )
        
        if status == kCVReturnSuccess {
            return textureCache
        } else {
            print("Failed to create texture cache with status: \(status)")
            return nil
        }
    }
    
    private func createSamplerState() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        samplerState = device?.makeSamplerState(descriptor: descriptor)
    }
    
    private func createStencilState() {
        // Write stencil state (for mask)
        let writeDescriptor = MTLDepthStencilDescriptor()
        writeDescriptor.depthCompareFunction = .always
        writeDescriptor.isDepthWriteEnabled = false
        
        let writeFaceStencil = MTLStencilDescriptor()
        writeFaceStencil.stencilCompareFunction = .always
        writeFaceStencil.stencilFailureOperation = .zero
        writeFaceStencil.depthFailureOperation = .zero
        writeFaceStencil.depthStencilPassOperation = .replace
        writeFaceStencil.readMask = 0xFF
        writeFaceStencil.writeMask = 0xFF
        writeDescriptor.frontFaceStencil = writeFaceStencil
        writeDescriptor.backFaceStencil = writeFaceStencil
        
        writeStencilState = device?.makeDepthStencilState(descriptor: writeDescriptor)
        
        // Test stencil state (for content)
        let testDescriptor = MTLDepthStencilDescriptor()
        testDescriptor.depthCompareFunction = .always
        testDescriptor.isDepthWriteEnabled = false
        
        let testFaceStencil = MTLStencilDescriptor()
        testFaceStencil.stencilCompareFunction = .equal
        testFaceStencil.stencilFailureOperation = .zero
        testFaceStencil.depthFailureOperation = .zero
        testFaceStencil.depthStencilPassOperation = .keep
        testFaceStencil.readMask = 0xFF
        testFaceStencil.writeMask = 0xFF
        testDescriptor.frontFaceStencil = testFaceStencil
        testDescriptor.backFaceStencil = testFaceStencil
        
        testStencilState = device?.makeDepthStencilState(descriptor: testDescriptor)
    }
    
    private func createMaskRenderPipeline() {
        guard let device = self.device else { return }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle.module)
            
            guard let vertexFunction = library.makeFunction(name: "maskVertexShader") else { return }
            var fragmentFunction: MTLFunction?

            switch maskMode {
            case .none:
                fragmentFunction = library.makeFunction(name: "maskFragmentShader")
            case .Image(let uIImage):
                fragmentFunction = library.makeFunction(name: "maskImageFragmentShader")
            case .VideoPlayer(_):
                break
            }
            
            guard let fragmentFunction else { return }
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Mask Render Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            
            // Configure color attachment for mask pass
            let colorAttachment = pipelineDescriptor.colorAttachments[0]
            colorAttachment?.pixelFormat = self.colorPixelFormat
            colorAttachment?.isBlendingEnabled = false
            colorAttachment?.writeMask = [] // Don't write to color buffer
            
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            
            // Add vertex descriptor for mask pipeline
            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            
            vertexDescriptor.attributes[2].format = .uint
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
            vertexDescriptor.attributes[2].bufferIndex = 0
            
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
            
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            do {
                maskRenderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("Failed to create mask pipeline state: \(error)")
            }
        } catch {
            print("ERROR : !!!")
        }
        
    }
    
    
    private func createRenderPipeline() {
        guard let device = self.device else { return }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle.module)
            guard let vertexFunction = library.makeFunction(name: "vertexShader") else {
                print("Failed to create shader functions")
                return
            }
            
            // Choose the fragment Shader based on the video type
            var fragmentFunction: MTLFunction?
            
            switch self.videoType {
            case .normal:
                fragmentFunction = library.makeFunction(name: "fragmentShader")
            case .alpha(config: let config):
                switch config {
                case .LR:
                    fragmentFunction = library.makeFunction(name: "fragmentShaderSplitTextureLR")
                case .TD:
                    fragmentFunction = library.makeFunction(name: "fragmentShaderSplitTextureTD")
                }
            }
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Render Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            
            // Configure blending
            let attachment = pipelineDescriptor.colorAttachments[0]
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .sourceAlpha
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            // Configure vertex descriptor with texture index
            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            
            vertexDescriptor.attributes[2].format = .uint
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
            vertexDescriptor.attributes[2].bufferIndex = 0
            
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
            
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            do {
                renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("Failed to create pipeline state: \(error)")
            }
        } catch {
            print("ERROR: !!!")
        }
        
    }
    
    /// Initlize the vertex buffer and index buffer according to LayerImages
    private func setupLayerVertices() {
        print("111: setupLayerVertices is called")
        isBufferUpdated = false
        
        vertexBuffers.removeAll()
        indexBuffers.removeAll()
        defer {
            isBufferUpdated = true
            print("111: defer is called")
        }
        
        for (index, layer) in layerImages.enumerated() {
            // Calculate offset based on layer priority
            let zOffset = Float(layer.offset.z) * 0.1 // Small z-offset to prevent z-fighting
            let xOffset = Float(layer.offset.x) // x-offset
            let yOffset = Float(layer.offset.y) // y-offset
            
            let extent = videoExtent ?? CGSize(width: 1.0, height: 1.0)
            let scale = layer.scale
            
            let vertices: [Vertex] = [
                // Vertex 0
                Vertex(position: SIMD3<Float>(
                    (-0.5) * scale * Float(extent.width) + xOffset,
                    (-0.5) * scale * Float(extent.height) + yOffset,
                    zOffset
                ), texCoord: SIMD2<Float>(0.0, 1.0), textureIndex: UInt32(index)),
                
                // Vertex 1
                Vertex(position: SIMD3<Float>(
                    (0.5) * scale * Float(extent.width) + xOffset,
                    (-0.5) * scale * Float(extent.height) + yOffset,
                    zOffset
                ), texCoord: SIMD2<Float>(1.0, 1.0), textureIndex: UInt32(index)),
                
                // Vertex 2
                Vertex(position: SIMD3<Float>(
                    (-0.5) * scale * Float(extent.width) + xOffset,
                    (0.5) * scale * Float(extent.height) + yOffset,
                    zOffset
                ), texCoord: SIMD2<Float>(0.0, 0.0), textureIndex: UInt32(index)),
                
                // Vertex 3
                Vertex(position: SIMD3<Float>(
                    (0.5) * scale * Float(extent.width) + xOffset,
                    (0.5) * scale * Float(extent.height) + yOffset,
                    zOffset
                ), texCoord: SIMD2<Float>(1.0, 0.0), textureIndex: UInt32(index))
            ]
            print("for \(layer.id): offset is : \(xOffset) + \(yOffset)")
            
            let indices: [UInt16] = [
                0, 1, 2,  // First triangle
                2, 1, 3   // Second triangle
            ]
            
            if let vertexBuffer = device?.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Vertex>.stride,
                options: .storageModeShared
            ) {
                vertexBuffers.append(vertexBuffer)
            }
            if let indexBuffer = device?.makeBuffer(
                bytes: indices,
                length: indices.count * MemoryLayout<UInt16>.stride,
                options: .storageModeShared
            ) {
                indexBuffers.append(indexBuffer)
            }
        }
        
        let uniformBufferSize = MemoryLayout<simd_float4x4>.stride * 3
        uniformBuffer = device?.makeBuffer(length: uniformBufferSize, options: .storageModeShared)
        print("111: setupLayerVertices is executed")
    }
    
    private func loadTexture(named name: String) -> MTLTexture? {
        guard let device = device else {
            print("Failed to create texture loader")
            return nil
        }
        
        let textureLoader = MTKTextureLoader(device: device)
        guard let image = UIImage(named: name)?.cgImage else {
            print("Failed to load image: \(name)")
            return nil
        }
        
        do {
            let textureOptions: [MTKTextureLoader.Option: Any] = [
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .generateMipmaps: true
            ]
            
            let texture = try textureLoader.newTexture(cgImage: image, options: textureOptions)
            print("Texture loaded successfully")
            return texture
        } catch {
            print("Failed to create texture: \(error)")
            return nil
        }
    }
    
    // Function to update transforms
    //TODO: no need to update the projectMatrix every frame
    /// Preventing calling this function if it is not need to update the MetalView
    public func updateTransforms(
        anchorTransform: simd_float4x4,
        cameraTransform: simd_float4x4?,
        projectionMatrix: simd_float4x4, trackingStatus: TrackingStatus,
        isAirboardEnabled: Bool = false
    ) {
        
        self.lastCameraTransform = cameraTransform
        self.projectionMatrix = projectionMatrix
        
        
        if trackingStatus == .trackingLost && isAirboardEnabled {
            self.isAirboardMode = true
            // Apply smooth airboard positioning similar to video node implementation
            updateAirboardPositioning(cameraTransform: anchorTransform)
            self.anchorTransform = self.airboardWorldTransform
            self.cameraTransform = cameraTransform
        } else {
            self.isAirboardMode = false
            self.anchorTransform = anchorTransform
            self.cameraTransform = cameraTransform
        }
        
        self.imageTrackingStatus = trackingStatus
        if (layerImages.count == vertexBuffers.count) && isBufferUpdated{
            setNeedsDisplay()
        }

    }
    

    private func updateAirboardPositioning(cameraTransform: simd_float4x4?) {
        guard let cameraTransform = cameraTransform else { return }
        
        let deltaTime: Float = 1.0/60.0
        let cameraPosition = simd_make_float3(cameraTransform.columns.3)
        
        
        let fixedDistance: Float = 3.0
        let forward = -simd_normalize(simd_make_float3(cameraTransform.columns.2))
        
        let screenCenterTarget = cameraPosition + forward * fixedDistance
        print("screen center target: \(cameraPosition)")
        // Use spring to smoothly move to the screen-centered position
        airboardCurrentPosition = criticallyDampedSpringSimple(
            current: airboardCurrentPosition,
            target: screenCenterTarget,
            velocity: &airboardVelocity,
            damping: 0.5,    // Increased damping for more stability
            frequency: 0.5,  // Increased frequency for faster return
            deltaTime: deltaTime
        )
        
        let toCamera = cameraPosition - airboardCurrentPosition
        let toCameraFlat = simd_normalize(simd_float3(toCamera.x, 0, toCamera.z))
        
        let forward3D = simd_float3(0, 0, 1)
        let rotationAngle = atan2(toCameraFlat.x, toCameraFlat.z)
        
        let cosY = cos(rotationAngle)
        let sinY = sin(rotationAngle)
        
        let lookat = simd_float4x4(
            simd_float4(cosY,  0, -sinY, 0),
            simd_float4(0,     1,  0,    0),
            simd_float4(sinY,  0,  cosY, 0),
            simd_float4(0,     0,  0,    1)
        )
        
        var worldTransform = lookat
        worldTransform.columns.3 = simd_float4(airboardCurrentPosition, 1.0)
        
        self.airboardWorldTransform = worldTransform
    }

    // Enhanced spring function with better damping
    private func criticallyDampedSpringSimple(
        current: simd_float3,
        target: simd_float3,
        velocity: inout simd_float3,
        damping: Float = 2.0,
        frequency: Float = 3.0,
        deltaTime: Float
    ) -> simd_float3 {
        let omega = frequency * 2 * Float.pi
        let k = omega * omega
        let c = 2 * damping * omega
        
        let displacement = current - target
        let springForce = -displacement * k
        let dampingForce = -velocity * c
        let acceleration = springForce + dampingForce
        
        velocity += acceleration * deltaTime
        let newPosition = current + velocity * deltaTime
        
        // Optional: Add bounds checking relative to target
        let maxDistance: Float = 0.5 // Reduced max distance
        let distanceFromTarget = simd_length(newPosition - target)
        
        if distanceFromTarget > maxDistance {
            let direction = simd_normalize(newPosition - target)
            return target + direction * maxDistance
        }
        
        return newPosition
    }

    // Add this to your class's public interface
    func updateMaskImage(_ image: UIImage) {
        guard let device = device,
              let cgImage = image.cgImage else { return }
        
        if let mtlTexture = loadTextureFromImage(image, device: device) {
            maskTexture = mtlTexture
        } else {
            print("Failed to load mask texture")
        }
    }
    
    public override func draw(_ rect: CGRect) {
        guard !isUpdatingLayers else { return }
        autoreleasepool {
            guard let uniformBuffer = uniformBuffer,
                  let maskVertexBuffer,
                  let drawable = currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let renderPassDescriptor = currentRenderPassDescriptor,
                  let writeStencilState = writeStencilState,
                  let testStencilState = testStencilState else {
                return
            }
            
            // CHANGE: Determine which buffers to use based on mode FIRST
            var vertexB = vertexBuffers
            var maskBuffer = maskVertexBuffer
            var overlayBuffer = overlayImageBuffer
            
            // NEW: Switch buffers based on current mode
            switch (imageTrackingStatus, isAirboardMode) {
            case (.notRecoganized, true):  // FIXED: Use trackingLost instead of notRecoganized
                // Use airboard buffers
                vertexB = airboardExpBuffer.isEmpty ? vertexBuffers : airboardExpBuffer
                maskBuffer = drawBufferMaskAirboard ?? maskVertexBuffer
                overlayBuffer = nonStencilAirboardBuffer ?? overlayImageBuffer
                
            case (.trackingLost, false):
                // Use fullscreen buffers (existing logic)
                vertexB = fullscreenExpBuffer.isEmpty ? vertexBuffers : fullscreenExpBuffer
                maskBuffer = drawBufferMaskFullscreen ?? maskVertexBuffer
                overlayBuffer = nonStencilImageBuffer ?? overlayImageBuffer
                
            default:
                // Use normal tracking buffers
                break
            }
            
            // MARK: First pass - render mask to stencil buffer
            renderPassDescriptor.stencilAttachment.clearStencil = 0
            renderPassDescriptor.stencilAttachment.loadAction = .clear
            renderPassDescriptor.stencilAttachment.storeAction = .store
            
            // Clear color for first pass
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            
            guard let maskEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            maskEncoder.setRenderPipelineState(maskRenderPipelineState)
            maskEncoder.setDepthStencilState(writeStencilState)
            maskEncoder.setStencilReferenceValue(1)
            maskEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            
            // CHANGE: Apply the selected maskBuffer instead of hardcoded maskVertexBuffer
            switch maskMode {
            case .none:
                maskEncoder.setVertexBuffer(maskBuffer, offset: 0, index: 0)
            case .Image(let uIImage, let offset):
                maskEncoder.setVertexBuffer(maskBuffer, offset: 0, index: 0)
                maskEncoder.setFragmentTexture(maskTexture, index: 8)
                maskEncoder.setFragmentSamplerState(samplerState, index: 0)
            case .VideoPlayer(_):
                break
            }
            
            maskEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            maskEncoder.endEncoding()
            
            // Second pass - ensure we're keeping the stencil
            renderPassDescriptor.stencilAttachment.loadAction = .load
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            
            //MARK: Rendering non stencil part (Overlay Images)
            guard let nonStencilEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            // Setup common encoder state
            nonStencilEncoder.setRenderPipelineState(nonStencilPipelineImage)
            updateUniforms(uniformBuffer)
            nonStencilEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            nonStencilEncoder.setFragmentSamplerState(samplerState, index: 0)
            print("check: \(airboardWorldTransform)")
            let overlayLayer = layerImageDic[-1]
            let isOverlayImage = overlayLayer?.isOverlayImaage ?? false
            
            // CHANGE: Use selected overlayBuffer based on mode
            if imageTrackingStatus == .tracking && isOverlayImage {
                // Render overlay in tracking mode
                if let overlayLayer = layerImageDic[-1],
                   let texture = overlayLayer.texture {
                    nonStencilEncoder.setVertexBuffer(overlayImageBuffer, offset: 0, index: 0) // Always use original for tracking
                    nonStencilEncoder.setFragmentTexture(texture, index: 0)
                    nonStencilEncoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: 6,
                        indexType: .uint16,
                        indexBuffer: indexBuffers[0],
                        indexBufferOffset: 0
                    )
                }
            }
            
            // CHANGE: Use selected overlayBuffer for non-tracking modes
            if imageTrackingStatus == .trackingLost {
                if let overlayLayer = layerImageDic[-1],
                   let texture = overlayLayer.texture {
                    nonStencilEncoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0) // FIXED: Use selected buffer
                    nonStencilEncoder.setFragmentTexture(texture, index: 0)
                    nonStencilEncoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: 6,
                        indexType: .uint16,
                        indexBuffer: indexBuffers[0],
                        indexBufferOffset: 0
                    )
                }
            }

            nonStencilEncoder.endEncoding()
            
            //MARK: Rendering non stencil Experience part
            guard let nonStencilEncoderExp = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            
            nonStencilEncoderExp.setRenderPipelineState(nonStencilPipelineLayer)
            updateUniforms(uniformBuffer)
            nonStencilEncoderExp.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            nonStencilEncoderExp.setFragmentSamplerState(samplerState, index: 0)
            
            // Process other non-stencil layers
            for i in 0..<layerImages.count {
                let currentLayer = layerImages[i]
                if currentLayer.useStencil || currentLayer.id == -1 { continue }
                
                switch currentLayer.content {
                case .image(_):
                    guard let texture = currentLayer.texture else { continue }
                    nonStencilEncoderExp.setVertexBuffer(vertexB[i], offset: 0, index: 0)
                    nonStencilEncoderExp.setFragmentTexture(texture, index: 0)
                    nonStencilEncoderExp.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: 6,
                        indexType: .uint16,
                        indexBuffer: indexBuffers[i],
                        indexBufferOffset: 0
                    )
                    
                case .video(let playerItemVideoOutput, let avplayer, _):
                    let time = avplayer.currentTime()
                    guard let videoOutput = playerItemVideoOutput,
                          let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                          let textureCache = currentLayer.textureCache else { continue }
                    
                    var cvTexture: CVMetalTexture?
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
                        &cvTexture
                    )
                    
                    guard let texture = cvTexture,
                          let metalTexture = CVMetalTextureGetTexture(texture) else { continue }
                    
                    // CHANGE: Use the pre-selected vertexB instead of hardcoded logic
                    nonStencilEncoderExp.setVertexBuffer(vertexB[i], offset: 0, index: 0)
                    nonStencilEncoderExp.setFragmentTexture(metalTexture, index: i)
                    nonStencilEncoderExp.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: 6,
                        indexType: .uint16,
                        indexBuffer: indexBuffers[i],
                        indexBufferOffset: 0
                    )
                    
                case .model(_):
                    break
                case .videov2:
                    break
                }
            }
            nonStencilEncoderExp.endEncoding()
            
            //MARK: Rendering stencil part
            guard let contentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                print("Failed to create content encoder")
                return
            }
            contentEncoder.setRenderPipelineState(renderPipelineState)
            contentEncoder.setDepthStencilState(testStencilState)
            contentEncoder.setStencilReferenceValue(1)
            contentEncoder.setFragmentSamplerState(samplerState, index: 0)
            
            updateUniforms(uniformBuffer)
            contentEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            
            // Draw each stencil layer
            for i in 0..<layerImages.count {
                let currentLayer = layerImages[i]
                if currentLayer.useStencil == false { continue }
                
                switch currentLayer.content {
                case .image(_):
                    if let texture = currentLayer.texture {
                        contentEncoder.setVertexBuffer(vertexB[i], offset: 0, index: 0)
                        contentEncoder.setFragmentTexture(texture, index: i)
                        
                        contentEncoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: 6,
                            indexType: .uint16,
                            indexBuffer: indexBuffers[i],
                            indexBufferOffset: 0
                        )
                    }
                    
                case .video(let playerItemVideoOutput, let avplayer, let videoType):
                    let time = avplayer.currentTime()
                    if let videoOutput = playerItemVideoOutput,
                       let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                       let textureCache = currentLayer.textureCache {
                        
                        var cvTexture: CVMetalTexture?
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
                            &cvTexture
                        )
                        
                        if let texture = cvTexture,
                           let metalTexture = CVMetalTextureGetTexture(texture) {
                            // CHANGE: Use the pre-selected vertexB instead of hardcoded buffer selection
                            contentEncoder.setVertexBuffer(vertexB[i], offset: 0, index: 0)
                            contentEncoder.setFragmentTexture(metalTexture, index: i)
                            
                            contentEncoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: 6,
                                indexType: .uint16,
                                indexBuffer: indexBuffers[i],
                                indexBufferOffset: 0
                            )
                        } else {
                            print("Failed to get metal texture from CVMetalTexture")
                        }
                    } else {
                        print("Video output components not valid")
                    }
                    
                case .model(_):
                    break
                case .videov2:
                    break
                }
            }
            
            contentEncoder.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
    private func createMaskVertices() -> [Vertex] {
        let extent = videoExtent ?? CGSize(width: 1.0, height: 1.0)
        let point: Float = 0.5 // Adjust this value to change the size of the mask
        return [
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), -point * Float(extent.height), 0), texCoord: SIMD2<Float>(0, 0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width), -point * Float(extent.height),0), texCoord: SIMD2<Float>(1, 0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), point * Float(extent.height), 0), texCoord: SIMD2<Float>(0, 1), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width), point * Float(extent.height), 0), texCoord: SIMD2<Float>(1, 1), textureIndex: 0)
        ]
    }
    
    private func updateMaskVertices(_ buffer: MTLBuffer, maskTargetSize: CGSize?) {
        let bufferPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
        let newExtent = maskTargetSize ?? CGSize(width: 1.0, height: 1.0)
        let point: Float = 0.5 * 1.01
        
        // Update x and z components (width and height) of each vertex
        // Vertex 0
        var value: SIMD3<Float> = .zero
        switch maskMode {
        case .none:
            break
        case .Image(let _, let offset):
            value = offset
        case .VideoPlayer(let aVPlayerItemVideoOutput):
            break
        }
        
        let xOffset = (maskOffset.x ?? 0.0) * Float(imageTargetExtent?.width ?? 0.0)
        let yOffset = (maskOffset.y ?? 0.0) * Float(imageTargetExtent?.height ?? 0.0)
        
        bufferPointer[0].position.x = (-point) * Float(newExtent.width) + xOffset
        bufferPointer[0].position.y = (-point) * Float(newExtent.height) + yOffset
        
        // Vertex 1
        bufferPointer[1].position.x = (point) * Float(newExtent.width) + xOffset
        bufferPointer[1].position.y = (-point) * Float(newExtent.height) + yOffset
        
        // Vertex 2
        bufferPointer[2].position.x = (-point) * Float(newExtent.width) + xOffset
        bufferPointer[2].position.y = (point) * Float(newExtent.height) + yOffset
        
        // Vertex 3
        bufferPointer[3].position.x = (point) * Float(newExtent.width) + xOffset
        bufferPointer[3].position.y = (point) * Float(newExtent.height) + yOffset
        
        print("Mask vertices updated: \(bufferPointer[0].position) + \(newExtent)")
    }
    
    private func scaleFactorTofit(points: [SIMD3<Float>], bound: CGSize) -> (scale: Float, offset: SIMD2<Float>) {
        var maxX: Float = points[0].x
        var maxY: Float = points[0].y
        var minX: Float = points[0].x
        var minY: Float = points[0].y

        // Compare with remaining points to find max and min
        for point in points {
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
            minX = min(minX, point.x)
            minY = min(minY, point.y)
        }
        
        // bound box of the current experience
        let currentWidth = abs(maxX - minX)
        let currentHeight = abs(maxY - minY)
        
        let scalex = Float(bound.width * 2) / currentWidth
        let scaley = Float(bound.height * 2) / currentHeight
        
        let scale = min(scalex, scaley)
        
        // Calculate scaled points
        let scaledPoints = points.map { SIMD3<Float>($0.x * scale, $0.y * scale, $0.z) }
        
        // Find bounds of scaled points
        var scaledMaxX: Float = scaledPoints[0].x
        var scaledMaxY: Float = scaledPoints[0].y
        var scaledMinX: Float = scaledPoints[0].x
        var scaledMinY: Float = scaledPoints[0].y
        
        for point in scaledPoints {
            scaledMaxX = max(scaledMaxX, point.x)
            scaledMaxY = max(scaledMaxY, point.y)
            scaledMinX = min(scaledMinX, point.x)
            scaledMinY = min(scaledMinY, point.y)
        }

        // Calculate center of scaled points
        let centerX = (scaledMaxX + scaledMinX) / 2.0
        let centerY = (scaledMaxY + scaledMinY) / 2.0
        
        // Calculate offset to center the points
        let offsetX = -centerX
        let offsetY = -centerY

        for (index, point) in scaledPoints.enumerated() {
            let finalPoint = SIMD3<Float>(
                point.x + offsetX,
                point.y + offsetY,
                point.z
            )
            print("Final Point \(index): (\(finalPoint.x), \(finalPoint.y), \(finalPoint.z))")
        }
        
        // Verify final bounds
        let finalMinX = scaledMinX + offsetX
        let finalMaxX = scaledMaxX + offsetX
        let finalMinY = scaledMinY + offsetY
        let finalMaxY = scaledMaxY + offsetY
        
        print("\nFinal bounds:")
        print("X range: [\(finalMinX), \(finalMaxX)]")
        print("Y range: [\(finalMinY), \(finalMaxY)]")
        
        return (scale, SIMD2<Float>(offsetX, offsetY))
    }
    
    private func setupMaskBufferFullscreen() {
        guard let device, let maskVertexBuffer else { return }
        if drawBufferMaskFullscreen == nil {
            drawBufferMaskFullscreen = device.makeBuffer(
                length: maskVertexBuffer.length,
                options: .storageModeShared
            )
        }
        
        // Get source and destination pointers
        let sourcePointer = maskVertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
        let destPointer = drawBufferMaskFullscreen!.contents().assumingMemoryBound(to: Vertex.self)
        
        // Copy vertices with offset
        let asp = Float(maskExtent!.width / maskExtent!.height) / Float(videoExtent!.width / videoExtent!.height)

        for i in 0..<4 {
            destPointer[i] = sourcePointer[i]
            destPointer[i].position.y *= viewAps
        }
    }
    
    private func setupExpBufferFullscreen() {
        guard let device else { return }
        if fullscreenExpBuffer.isEmpty {
            for vertexBuffer in vertexBuffers {
                if let newBuffer = device.makeBuffer(
                    length: vertexBuffer.length,
                    options: .storageModeShared
                ) {
                    fullscreenExpBuffer.append(newBuffer)
                }
            }
        }
        
        for (index, buffer) in fullscreenExpBuffer.enumerated() {
            let sourcePointer = vertexBuffers[index].contents().assumingMemoryBound(to: Vertex.self)
            let destPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
            
            for i in 0..<4 {
                destPointer[i] = sourcePointer[i]
                destPointer[i].position.y *= viewAps
                
            }
        }
    }
    
    private func preparemaskBufferFullscreen(scale: Float, offset: SIMD2<Float>) -> MTLBuffer? {
        // Create draw buffer if needed
        guard let device, let maskVertexBuffer else { return nil}
        if drawBufferMaskFullscreen == nil {
            drawBufferMaskFullscreen = device.makeBuffer(
                length: maskVertexBuffer.length,
                options: .storageModeShared
            )
        }
        
        // Get source and destination pointers
        let destPointer = drawBufferMaskFullscreen!.contents().assumingMemoryBound(to: Vertex.self)
        
        // Copy vertices with offset
        let asp = Float(maskExtent!.width / maskExtent!.height) / Float(videoExtent!.width / videoExtent!.height)

        for i in 0..<4 {
            destPointer[i].position *= scale
            destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
            
        }
        return drawBufferMaskFullscreen!
    }
    
    private func prepareExpBufferFullscreen(scale: Float, offset: SIMD2<Float>) -> [MTLBuffer]{
        guard let device else { return []}
        if fullscreenExpBuffer.isEmpty {
            for vertexBuffer in vertexBuffers {
                if let newBuffer = device.makeBuffer(
                    length: vertexBuffer.length,
                    options: .storageModeShared
                ) {
                    fullscreenExpBuffer.append(newBuffer)
                }
            }
        }
        
        for (index, buffer) in fullscreenExpBuffer.enumerated() {
            let destPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
            
            for i in 0..<4 {
                destPointer[i].position *= scale
                destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
                
            }
        }
        return fullscreenExpBuffer
    }
    
    private func updateUniforms(_ buffer: MTLBuffer) {
        let matrices = buffer.contents().assumingMemoryBound(to: simd_float4x4.self)
        if let anchor = anchorTransform,
           let camera = cameraTransform,
           let projection = projectionMatrix {
            matrices[0] = anchor
            matrices[1] = camera
            matrices[2] = projection
        } else {
            matrices[0] = matrix_identity_float4x4
            matrices[1] = matrix_identity_float4x4
            matrices[2] = matrix_identity_float4x4
        }
    }
    
    public func clearLayes(){
        layerImages.removeAll()
        layerImageDic.removeAll()
        
        clearVertexBuffer()
        clearAirboardBuffers()
    }
    private func clearAirboardBuffers(){
        airboardExpBuffer.removeAll()
        drawBufferMaskAirboard = nil
        nonStencilAirboardBuffer = nil
    }
    
    private func clearVertexBuffer(){
        vertexBuffers.removeAll()
        indexBuffers.removeAll()
    }
    
    deinit {
        print("deinit called for ARMetalView")
        layerImages.removeAll()
        layerImageDic.removeAll()
    }
}


extension simd_float4x4 {
    init(lookAt eye: simd_float3, target: simd_float3, up: simd_float3) {
        let zAxis = simd_normalize(eye - target)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        
        self.init(
            simd_float4(xAxis, 0),
            simd_float4(yAxis, 0),
            simd_float4(zAxis, 0),
            simd_float4(eye, 1)
        )
    }
}
