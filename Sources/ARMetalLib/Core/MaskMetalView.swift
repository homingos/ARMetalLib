//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 24/01/25.
//

import Foundation
import MetalKit
import AVFoundation

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
    
    private var isBufferUpdated: Bool = false
    private var maskMode: MaskMode = .none
    private var maskTexture: MTLTexture?
    private var videoType: VideoType = .normal
    // for video player output dont replace or add new video output use the existing output
    
    public init?(frame: CGRect, device: MTLDevice, maskMode: MaskMode, videoType: VideoType = .normal) {
        print("init ARMetalView")
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
//        self.viewControllerDelegate = viewControllerDelegate
        //        setupDefaultVertices()
    }
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupMaskConfiguration(maskMode: MaskMode){
        switch maskMode {
        case .none:
            break
        case .Image(let image):
            updateMaskImage(image)
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
    public func setTargetSize(targetSize: CGSize){
        targetExtent = targetSize
        updateVertexBuffer(newExtent: targetSize)
        updateMaskVertices(maskVertexBuffer)
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
                
                let zOffset = Float(layer.offset.y) * 0.5
                let xOffset = Float(layer.offset.x)
                let yOffset = Float(layer.offset.z)
                let scale = layer.scale
                
                // Update x and z components (width and height) of each vertex
                // Vertex 0
                bufferPointer[0].position.x = (-0.5 + xOffset) * scale * Float(newExtent.width)
                bufferPointer[0].position.z = (-0.5 + yOffset) * scale * Float(newExtent.height)
                
                // Vertex 1
                bufferPointer[1].position.x = (0.5 + xOffset) * scale * Float(newExtent.width)
                bufferPointer[1].position.z = (-0.5 + yOffset) * scale * Float(newExtent.height)
                
                // Vertex 2
                bufferPointer[2].position.x = (-0.5 + xOffset) * scale * Float(newExtent.width)
                bufferPointer[2].position.z = (0.5 + yOffset) * scale * Float(newExtent.height)
                
                // Vertex 3
                bufferPointer[3].position.x = (0.5 + xOffset) * scale * Float(newExtent.width)
                bufferPointer[3].position.z = (0.5 + yOffset) * scale * Float(newExtent.height)
                
                print("Updated vertices for layer \(layer.id): \(bufferPointer[0].position)")
            }
        }
    }
    
    private func setLayerImage(layerImage: [Int: MaskLayer]){
        guard let device else { return }
        
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
                if let image = layerValues.image, let cgImage = image.cgImage {
                    do {
                        // Create texture descriptor for high quality
                        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .rgba8Unorm,
                            width: cgImage.width,
                            height: cgImage.height,
                            mipmapped: true
                        )
                        textureDescriptor.usage = [.shaderRead, .renderTarget]
                        textureDescriptor.storageMode = .private
                        textureDescriptor.sampleCount = 1
                        
                        layerValues.texture = try textureLoader.newTexture(
                            cgImage: cgImage,
                            options: textureOptions
                        )
                        //                    print("Layer texture loaded with high quality settings")
                    } catch {
                        print("Error loading texture: \(error)")
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
            let zOffset =  Float(layer.offset.y) * 0.1 // Small z-offset to prevent z-fighting
            let xOffset =  Float(layer.offset.x) // Small x-offset to prevent z-fighting
            let yOffset =  Float(layer.offset.z) // Small y-offset to prevent z-fighting
            
            let extent = targetExtent ?? CGSize(width: 1.0, height: 1.0)
            let scale = layer.scale
            
            let vertices: [Vertex] = [
                Vertex(position: SIMD3<Float>((-0.5 + xOffset) * scale * Float(extent.width), zOffset, (-0.5 + yOffset) * scale * Float(extent.height)), texCoord: SIMD2<Float>(0.0, 1.0), textureIndex: UInt32(index)),
                Vertex(position: SIMD3<Float>((0.5 + xOffset) * scale * Float(extent.width), zOffset, (-0.5 + yOffset) * scale * Float(extent.height)) , texCoord: SIMD2<Float>(1.0, 1.0), textureIndex: UInt32(index)),
                Vertex(position: SIMD3<Float>((-0.5 + xOffset) * scale * Float(extent.width), zOffset, (0.5 + yOffset) * scale * Float(extent.height)) , texCoord: SIMD2<Float>(0.0, 0.0), textureIndex: UInt32(index)),
                Vertex(position: SIMD3<Float>((0.5 + xOffset) * scale * Float(extent.width), zOffset, (0.5 + yOffset) * scale * Float(extent.height)), texCoord: SIMD2<Float>(1.0, 0.0), textureIndex: UInt32(index))
            ]
            print("for \(layer.id): offset is : \(vertices)")
            
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
        projectionMatrix: simd_float4x4
    ) {
        self.anchorTransform = anchorTransform
        self.cameraTransform = cameraTransform
        self.projectionMatrix = projectionMatrix
        if (layerImages.count == vertexBuffers.count) && isBufferUpdated{
            setNeedsDisplay()
        }
        //else {
        //            print("cannot setNeedsDisplay: \(layerImages.count) + \(vertexBuffers.count)")
        //        }
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
        maskEncoder.setVertexBuffer(maskVertexBuffer, offset: 0, index: 0)
        maskEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        
        // Apply the maskImage if present
        switch maskMode {
        case .none:
            break
        case .Image(let uIImage):
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
                    if let texture = cvTexture {
                        let metalTexture = CVMetalTextureGetTexture(texture)
                        contentEncoder.setVertexBuffer(vertexB[i], offset: 0, index: 0)
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
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), 0, -point * Float(extent.height)), texCoord: SIMD2<Float>(0, 1), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width),0, -point * Float(extent.height)), texCoord: SIMD2<Float>(1, 1), textureIndex: 0),
            Vertex(position: SIMD3<Float>(-point * Float(extent.width), 0, point * Float(extent.height)), texCoord: SIMD2<Float>(0, 0), textureIndex: 0),
            Vertex(position: SIMD3<Float>(point * Float(extent.width), 0, point * Float(extent.height)), texCoord: SIMD2<Float>(1, 0), textureIndex: 0)
        ]
    }
    
    private func updateMaskVertices(_ buffer: MTLBuffer) {
        let bufferPointer = buffer.contents().assumingMemoryBound(to: Vertex.self)
        let newExtent = targetExtent ?? CGSize(width: 1.0, height: 1.0)
        let point: Float = 0.5
        
        // Update x and z components (width and height) of each vertex
        // Vertex 0
        bufferPointer[0].position.x = (-point) * Float(newExtent.width)
        bufferPointer[0].position.z = (-point) * Float(newExtent.height)
        
        // Vertex 1
        bufferPointer[1].position.x = (point) * Float(newExtent.width)
        bufferPointer[1].position.z = (-point) * Float(newExtent.height)
        
        // Vertex 2
        bufferPointer[2].position.x = (-point) * Float(newExtent.width)
        bufferPointer[2].position.z = (point) * Float(newExtent.height)
        
        // Vertex 3
        bufferPointer[3].position.x = (point) * Float(newExtent.width)
        bufferPointer[3].position.z = (point) * Float(newExtent.height)
        print("Mask vertices updated: \(bufferPointer[0].position)")
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
