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

public class OffscreenRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sourceTexture: MTLTexture
    let outputTexture: MTLTexture
    
    let vertexBuffer: MTLBuffer
    
    public init?(device: MTLDevice,image: UIImage, planeNode: SCNNode, sceneView: ARSCNView) {
        
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue(),
              let texture = loadTextureFromImage(image, device: device)
        else {
            print("Metal not available or texture failed.")
            return nil
        }
        
        
        self.commandQueue = commandQueue
        self.sourceTexture = texture
        
        let screenScale = UIScreen.main.scale
        let viewSize = sceneView.bounds.size
        let width = Int(viewSize.width * screenScale)
        let height = Int(viewSize.height * screenScale)
        
        // Create a render target (offscreen)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        self.outputTexture = device.makeTexture(descriptor: descriptor)!
        
        // Build pipeline
        let library = try! device.makeDefaultLibrary(bundle: Bundle.module)
        let vertex = library.makeFunction(name: "texture_vertex")
        let fragment = library.makeFunction(name: "texture_fragment")
        
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertex
        pipelineDesc.fragmentFunction = fragment
        pipelineDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        
        let vertexDescriptor = MTLVertexDescriptor()

        // position (float3)
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        // texCoord (float2)
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        // textureIndex (uint)
        vertexDescriptor.attributes[2].format = .uint
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[2].bufferIndex = 0

        // layout
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        pipelineDesc.vertexDescriptor = vertexDescriptor 
        
        self.pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDesc)
        
        guard let vertices = makeVerticesFromPlaneNode(planeNode) else {
               print("Could not generate vertices from plane node")
               return nil
           }

           self.vertexBuffer = device.makeBuffer(
               bytes: vertices,
               length: MemoryLayout<Vertex>.stride * vertices.count,
               options: []
           )!
    }
    
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
        encoder.setVertexBytes(&mvpMatrix,length: MemoryLayout<simd_float4x4>.stride,index: 1)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
    }
    
    public func getColorAt(u: CGFloat, v: CGFloat) -> UIColor? {
        
        let x = Int(u * CGFloat(outputTexture.width))
        let y = Int(v * CGFloat(outputTexture.height))
        
        let region = MTLRegionMake2D(x, y, 1, 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        outputTexture.getBytes(&pixel,
                               bytesPerRow: 4,
                               from: region,
                               mipmapLevel: 0)
        
        return UIColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: CGFloat(pixel[3]) / 255.0
        )
    }
}

func makeVerticesFromPlaneNode(_ planeNode: SCNNode) -> [Vertex]? {
    guard let plane = planeNode.geometry as? SCNPlane else {
        print(" Not a plane geometry")
        return nil
    }

    let width = Float(plane.width)
    let height = Float(plane.height)

    // Match SceneKit's UV layout (bottom-left = (0,0))
    return [
        Vertex(position: [-width/2, -height/2, 0], texCoord: [0, 1], textureIndex: 0),
        Vertex(position: [ width/2, -height/2, 0], texCoord: [1, 1], textureIndex: 0),
        Vertex(position: [-width/2,  height/2, 0], texCoord: [0, 0], textureIndex: 0),
        Vertex(position: [ width/2, -height/2, 0], texCoord: [1, 1], textureIndex: 0),
        Vertex(position: [ width/2,  height/2, 0], texCoord: [1, 0], textureIndex: 0),
        Vertex(position: [-width/2,  height/2, 0], texCoord: [0, 0], textureIndex: 0)
    ]
}
