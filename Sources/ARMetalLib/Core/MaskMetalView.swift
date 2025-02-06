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
    private var targetExtent: CGSize?
    private var maskExtent: CGSize?
    private var targetFullscreenAspectRatio: Float?
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
    private var staticRectPipelineState: MTLRenderPipelineState!
    private var staticRectVertexBuffer: MTLBuffer!
    
    private let viewAps: Float
    
    public init?(frame: CGRect, device: MTLDevice, maskMode: MaskMode, videoType: VideoType = .normal) {
        print("init ARMetalView")
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
    
    private struct StaticRectVertex {
        var position: SIMD3<Float>
        var texCoord: SIMD2<Float>
    }
    
    private func setupStaticRectangle() {
        // Create vertices for the static rectangle, flipped vertically (positions only)
        let vertices: [StaticRectVertex] = [
            StaticRectVertex(position: SIMD3<Float>(-0.5, -0.5, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),    // Bottom-left (was Top-left)
            StaticRectVertex(position: SIMD3<Float>(0.5, -0.5, 0.0), texCoord: SIMD2<Float>(1.0, 0.0)),     // Bottom-right (was Top-right)
            StaticRectVertex(position: SIMD3<Float>(-0.5, 0.5, 0.0), texCoord: SIMD2<Float>(0.0, 1.0)),     // Top-left (was Bottom-left)
            StaticRectVertex(position: SIMD3<Float>(0.5, 0.5, 0.0), texCoord: SIMD2<Float>(1.0, 1.0))       // Top-right (was Bottom-right)
        ]
            
        staticRectVertexBuffer = device?.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<StaticRectVertex>.stride,
            options: .storageModeShared
        )
            
        createStaticRectPipeline()
    }
    
    private func updateFullScreenImage(fullscreenAspectRatio: Float, scale: Float, offset: SIMD2<Float>){
        
        guard let staticRectVertexBuffer else { return }
        let bufferVertex = staticRectVertexBuffer.contents().assumingMemoryBound(to: StaticRectVertex.self)
        
        let center: CGPoint = .zero
        let extent = CGSize(width: 0.5 * Double(1/viewAps) * Double(fullscreenAspectRatio) * Double(scale), height: 0.5 * Double(scale))
        let xValue = center.x + Double(offset.x)
        let yValue = center.y + Double(offset.y)
        
        bufferVertex[0].position = SIMD3<Float>(Float(xValue - extent.width/2), Float(yValue + extent.height/2), 0.0)
        bufferVertex[1].position = SIMD3<Float>(Float(xValue + extent.width/2), Float(yValue + extent.height/2), 0.0)
        bufferVertex[2].position = SIMD3<Float>(Float(xValue - extent.width/2), Float(yValue - extent.height/2), 0.0)
        bufferVertex[3].position = SIMD3<Float>(Float(xValue + extent.width/2), Float(yValue - extent.height/2), 0.0)
    }

    private func createStaticRectPipeline() {
        guard let device = self.device else { return }
        
        do {
            let library = try device.makeDefaultLibrary(bundle: Bundle.module)
            guard let vertexFunction = library.makeFunction(name: "staticRectVertexShader"),
                  let fragmentFunction = library.makeFunction(name: "staticRectFragmentShader") else {
                return
            }
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Static Rectangle Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            
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
            
            // Buffer layout
            vertexDescriptor.layouts[0].stride = MemoryLayout<StaticRectVertex>.stride
            
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            // Configure color attachment
            let colorAttachment = pipelineDescriptor.colorAttachments[0]
            colorAttachment?.pixelFormat = self.colorPixelFormat
            colorAttachment?.isBlendingEnabled = true
            colorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            colorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            colorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            
            staticRectPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
    public func setTargetSize(targetSize: CGSize, maskTargetSize: CGSize, targetFullscreenAspectRatio: Float? = nil){
        targetExtent = targetSize
        maskExtent = maskTargetSize
        self.targetFullscreenAspectRatio = targetFullscreenAspectRatio
        updateVertexBuffer(newExtent: targetSize)
        updateMaskVertices(maskVertexBuffer, maskTargetSize: maskTargetSize)
        
        // calculate the fullscreen Layer coordinates with mask for the scale factor to fit
        updateFullscreenCoordinates()
    }
    
    private func updateFullscreenCoordinates(){
        var points: [SIMD3<Float>] = []
        
        // Setup the Fullscreen buffer
        setupExpBufferFullscreen()
        setupMaskBufferFullscreen()
        // Experience points
        for (index, layer) in layerImages.enumerated() {
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
        let maksBuffer = drawBufferMaskFullscreen?.contents().assumingMemoryBound(to: StaticRectVertex.self)
        points.append(maksBuffer![0].position)
        points.append(maksBuffer![1].position)
        points.append(maksBuffer![2].position)
        points.append(maksBuffer![3].position)
        
        let scale = scaleFactorTofit(points: points, bound: CGSize(width: 1.0, height: 1.0))
        print("new scale: \(scale)")

        // Mask
        preparemaskBufferFullscreen(scale: scale.scale, offset: scale.offset)
        
        // Experience Content
        prepareExpBufferFullscreen(scale: scale.scale, offset: scale.offset)
        
        // setup fullscreen scale
        updateFullScreenImage(fullscreenAspectRatio: targetFullscreenAspectRatio ?? 1.0, scale: scale.scale, offset: scale.offset)
        
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
                
                let zOffset = Float(layer.offset.z) * 0.5
                let xOffset = Float(layer.offset.x)
                let yOffset = Float(layer.offset.y)
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

                
                
//                print("Updated vertices for layer 1 \(layer.id): \(bufferPointer[0].position)")
//                print("Updated vertices for layer 2 \(layer.id): \(bufferPointer[1].position)")
//                print("Updated vertices for layer 3 \(layer.id): \(bufferPointer[2].position)")
//                print("Updated vertices for layer 4 \(layer.id): \(bufferPointer[03].position)")
            }
        }
    }
    private func loadTextureFromImage(_ image: UIImage, device: MTLDevice) -> MTLTexture? {
        // Ensure we have a valid CGImage
        guard let cgImage = image.cgImage else {
            print("Failed to get CGImage from UIImage")
            return nil
        }
        
        // Create a texture loader
        let textureLoader = MTKTextureLoader(device: device)
        
        // Configure texture loading options
        let textureOptions: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: MTLTextureUsage([.shaderRead, .renderTarget]).rawValue
        ]
        
        do {
            // First try direct loading
            return try textureLoader.newTexture(cgImage: cgImage, options: textureOptions)
        } catch {
            print("Direct texture loading failed, attempting manual conversion...")
            
            // Manual texture creation as fallback
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerPixel = 4
            let bitsPerComponent = 8
            let bytesPerRow = bytesPerPixel * width
            let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * bytesPerPixel)
            
            guard let context = CGContext(data: rawData,
                                        width: width,
                                        height: height,
                                        bitsPerComponent: bitsPerComponent,
                                        bytesPerRow: bytesPerRow,
                                        space: colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                print("Failed to create CGContext")
                rawData.deallocate()
                return nil
            }
            
            // Draw the image into the context
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            // Create texture descriptor
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: true
            )
            textureDescriptor.usage = [.shaderRead, .renderTarget]
            textureDescriptor.storageMode = .shared
            
            // Create texture
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                print("Failed to create texture")
                rawData.deallocate()
                return nil
            }
            
            // Copy data to texture
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.replace(region: region,
                           mipmapLevel: 0,
                           withBytes: rawData,
                           bytesPerRow: bytesPerRow)
            
            // Clean up
            rawData.deallocate()
            
            return texture
        }
    }
    
    private func setLayerImage(layerImage: [Int: MaskLayer]){
        guard let device else { return }
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
            
            print("fragment shader overlay: \(String(describing: fragmentFunction))")
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
            
            let extent = targetExtent ?? CGSize(width: 1.0, height: 1.0)
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
        projectionMatrix: simd_float4x4, trackingStatus: TrackingStatus
    ) {
        self.anchorTransform = anchorTransform
        self.cameraTransform = cameraTransform
        self.projectionMatrix = projectionMatrix
        
        self.imageTrackingStatus = trackingStatus
        if (layerImages.count == vertexBuffers.count) && isBufferUpdated{
            setNeedsDisplay()
        }

    }
    
    // Add this to your class's public interface
    func updateMaskImage(_ image: UIImage) {
        guard let device = device,
              let cgImage = image.cgImage else { return }
        
        let textureLoader = MTKTextureLoader(device: device)
        do {
            let textureOptions: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: true,
                .textureUsage: MTLTextureUsage([.shaderRead]).rawValue
            ]
            maskTexture = try textureLoader.newTexture(
                cgImage: cgImage,
                options: textureOptions
            )
        } catch {
            print("Failed to load mask texture: \(error)")
        }
    }
    
    public override func draw(_ rect: CGRect) {
        
        guard let uniformBuffer = uniformBuffer,
              let maskVertexBuffer,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderPassDescriptor = currentRenderPassDescriptor,
              let writeStencilState = writeStencilState,
              let testStencilState = testStencilState else {
            return
        }
        // First pass - render mask to stencil buffer
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
        //        print("drawing")
        // Render mask geometry
        // TODO: Create the buffer only once not every frame
        maskEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        
        // Apply the maskImage if present
        switch maskMode {
        case .none:
            break
        case .Image(let uIImage, let offset):
            var maskVB = maskVertexBuffer
            if imageTrackingStatus == .trackingLost, let drawBufferMaskFullscreen{
                maskVB = drawBufferMaskFullscreen
            }
            
            maskEncoder.setVertexBuffer(maskVB, offset: 0, index: 0)
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
        
        //MARK: to render bacnground image
        if imageTrackingStatus == .trackingLost {
            // Final pass - render static rectangle
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            guard let rectEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            // Find the first layer with useStencil = false
            if let nonStencilLayer = layerImages.first(where: { !$0.useStencil }) {
                rectEncoder.setRenderPipelineState(staticRectPipelineState)
                rectEncoder.setVertexBuffer(staticRectVertexBuffer, offset: 0, index: 0)
                
                // Set the texture from the non-stencil layer
                if let texture = nonStencilLayer.texture {
                    rectEncoder.setFragmentTexture(texture, index: 0)
                    rectEncoder.setFragmentSamplerState(samplerState, index: 0)
                    rectEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            rectEncoder.endEncoding()
        }
        
        // Second pass - render content with stencil test
        let contentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        contentEncoder.setRenderPipelineState(renderPipelineState)
        contentEncoder.setDepthStencilState(testStencilState)
        contentEncoder.setStencilReferenceValue(1)  // Must match the value written in the mask pass
        contentEncoder.setFragmentSamplerState(samplerState, index: 0)
        
        // TODO: Update this for supporting multi-Parallax
        updateUniforms(uniformBuffer)
        contentEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        let copiedLayerImages = layerImages.map { $0.copy() }
//        let newOffset = viewControllerDelegate?.willUpdateDraw(layerImages: copiedLayerImages)
        let newOffset:[SIMD3<Float>]? = nil
        var vertexB = vertexBuffers
        if newOffset == nil {
            
        } else {
            if let newOffset {
                for i in 0..<vertexB.count {
                    let existingVertexBuffer = vertexB[i]
                    let layerIndex = i / 4
                    let bufferPointer = existingVertexBuffer.contents().assumingMemoryBound(to: Vertex.self)
                    print("before: \(bufferPointer[0].position)")
                    bufferPointer[0].position += newOffset[layerIndex]
                    bufferPointer[1].position += newOffset[layerIndex]
                    bufferPointer[2].position += newOffset[layerIndex]
                    bufferPointer[3].position += newOffset[layerIndex]
                    
                    print("after: \(bufferPointer[0].position)")
                }
            }
        }
        // Draw each layer
        for i in 0..<layerImages.count {
            let currentLayer = layerImages[i]
            let contentType = currentLayer.content
            if currentLayer.useStencil == false { continue }
            switch contentType {
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
                if let videoOutput = playerItemVideoOutput, let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil), let textureCache = currentLayer.textureCache {
                    
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
                    var buffer = vertexB[i]
                    // add the vertex logic to restrict the vertex
                    if imageTrackingStatus == .trackingLost {
//                        constrainVideoFrame(vertexB[i])
                        buffer = fullscreenExpBuffer[i]
                    }
                    if let texture = cvTexture {
                        let metalTexture = CVMetalTextureGetTexture(texture)
                        contentEncoder.setVertexBuffer(buffer, offset: 0, index: 0)
                        contentEncoder.setFragmentTexture(metalTexture, index: i)
                        
                        contentEncoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: 6,
                            indexType: .uint16,
                            indexBuffer: indexBuffers[i],
                            indexBufferOffset: 0
                        )
                    }
                } else {
                    print("things ar enot valid")
                }
            case .model(let uRL):
                // TODO: For 3d objects
                break
            }
        }
        
        contentEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func createMaskVertices() -> [Vertex] {
        let extent = targetExtent ?? CGSize(width: 1.0, height: 1.0)
        let point: Float = 0.5 // Adjust this value to change the size of the mask
        return [
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), -point * Float(extent.height), 0), texCoord: SIMD2<Float>(0, 1), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width), -point * Float(extent.height),0), texCoord: SIMD2<Float>(1, 1), textureIndex: 0),
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), point * Float(extent.height), 0), texCoord: SIMD2<Float>(0, 0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width), point * Float(extent.height), 0), texCoord: SIMD2<Float>(1, 0), textureIndex: 0)
        ]
    }
    
    private func updateMaskVertices(_ buffer: MTLBuffer, maskTargetSize: CGSize?) {
        let bufferPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
        let newExtent = maskTargetSize ?? CGSize(width: 1.0, height: 1.0)
        let point: Float = 0.5
        
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
        
        bufferPointer[0].position.x = (-point + value.x) * Float(newExtent.width)
        bufferPointer[0].position.y = (-point + value.y) * Float(newExtent.height)
        
        // Vertex 1
        bufferPointer[1].position.x = (point + value.x) * Float(newExtent.width)
        bufferPointer[1].position.y = (-point + value.y) * Float(newExtent.height)
        
        // Vertex 2
        bufferPointer[2].position.x = (-point + value.x) * Float(newExtent.width)
        bufferPointer[2].position.y = (point + value.y) * Float(newExtent.height)
        
        // Vertex 3
        bufferPointer[3].position.x = (point + value.x) * Float(newExtent.width)
        bufferPointer[3].position.y = (point + value.y) * Float(newExtent.height)
        
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
        let asp = Float(maskExtent!.width / maskExtent!.height) / Float(targetExtent!.width / targetExtent!.height)

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
        let asp = Float(maskExtent!.width / maskExtent!.height) / Float(targetExtent!.width / targetExtent!.height)

        for i in 0..<4 {
            destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
            destPointer[i].position *= scale
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
                destPointer[i].position += SIMD3<Float>(offset.x, offset.y, 0.0)
                destPointer[i].position *= scale
//                let asp = Float(targetExtent!.width / targetExtent!.height)
//                destPointer[i].position.y /= Float(targetExtent!.width / targetExtent!.height)
                
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
    
    deinit {
        print("deinit called for ARMetalView")
        layerImages.removeAll()
        layerImageDic.removeAll()
    }
}
