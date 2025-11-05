//
//  TextureInteraction.swift
//  ARMetalLib
//
//  Created by Yuvraj Kadale on 28/10/25.
//

import Metal
import UIKit
import simd
import SceneKit
import ARKit

@MainActor
public class OffscreenMetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var sourceTexture: MTLTexture
    let outputTexture: MTLTexture
    
    private(set) var vertexBuffer: MTLBuffer!
    
    public init?(device externalDevice: MTLDevice? = nil,viewSize: CGSize,videoExtent: CGSize? = nil) {
        // --- Setup Metal ---
        guard let device = externalDevice ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            print("Failed to initialize Metal device or command queue.")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        // --- Create offscreen render target ---
        let screenScale = UIScreen.main.scale
        let width = Int(viewSize.width * screenScale)
        let height = Int(viewSize.height * screenScale)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        self.outputTexture = device.makeTexture(descriptor: descriptor)!

        // --- Build pipeline ---
        let library = try! device.makeDefaultLibrary(bundle: Bundle.module)
        let vertex = library.makeFunction(name: "texture_vertex")
        let fragment = library.makeFunction(name: "texture_fragment")

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertex
        pipelineDesc.fragmentFunction = fragment
        pipelineDesc.colorAttachments[0].pixelFormat = .rgba8Unorm

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        vertexDescriptor.attributes[2].format = .uint
        vertexDescriptor.attributes[2].offset =
            MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[2].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        pipelineDesc.vertexDescriptor = vertexDescriptor

        self.pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDesc)

        // --- Initialize with empty texture ---
        self.sourceTexture = OffscreenMetalRenderer.makeEmptyTexture(device: device, size: viewSize)
        
        // --- Default 1:1 vertices (will update when videoExtent is known) ---
        let initialExtent = videoExtent ?? CGSize(width: 1.0, height: 1.0)
        setupVertices(for: initialExtent)

    }

    // MARK: - Vertex Setup
    private func setupVertices(for videoExtent: CGSize) {
    
        // make it w.r.t to video
        var w: Float = Float(videoExtent.width/2)
        var h: Float = Float(videoExtent.height/2) 
        
        let vertices = [
            Vertex(position: [-w, -h, 0], texCoord: [0, 1], textureIndex: 0),
            Vertex(position: [ w, -h, 0], texCoord: [1, 1], textureIndex: 0),
            Vertex(position: [-w,  h, 0], texCoord: [0, 0], textureIndex: 0),
            Vertex(position: [ w, -h, 0], texCoord: [1, 1], textureIndex: 0),
            Vertex(position: [ w,  h, 0], texCoord: [1, 0], textureIndex: 0),
            Vertex(position: [-w,  h, 0], texCoord: [0, 0], textureIndex: 0)
        ]

        self.vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: []
        )
    }

    // MARK: - Update video extent later
    public func updateVideoExtent(_ extent: CGSize) {
        setupVertices(for: extent)
        print("Updated OffscreenMetalRenderer vertices with new video extent: \(extent)")
    }

    // MARK: - Rendering
    public func render(mvpMatrix: simd_float4x4) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = outputTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        
        encoder.pushDebugGroup("OffscreenRender")
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        
        var mvpMatrix = mvpMatrix
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&mvpMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Texture Utilities
    public func setColorMap(_ image: UIImage) {
        print("Setting color map...")
        guard let newTexture = loadTextureFromImage(image, device: device) else {
            print("Failed to load new color map texture")
            return
        }
        self.sourceTexture = newTexture
    }

    public func getColorAt(u: CGFloat, v: CGFloat) -> UIColor? {
        let x = Int(u * CGFloat(outputTexture.width))
        let y = Int(v * CGFloat(outputTexture.height))
        let region = MTLRegionMake2D(x, y, 1, 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        outputTexture.getBytes(&pixel, bytesPerRow: 4, from: region, mipmapLevel: 0)

        return UIColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: CGFloat(pixel[3]) / 255.0
        )
    }

    private static func makeEmptyTexture(device: MTLDevice, size: CGSize) -> MTLTexture {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)!
    }
}

