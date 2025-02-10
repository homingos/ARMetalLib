//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 10/02/25.
//

import Foundation
import Metal
import UIKit
import MetalKit

func loadTextureFromImage(_ image: UIImage, device: MTLDevice) -> MTLTexture? {
    guard let cgImage = image.cgImage else {
        print("Failed to get CGImage from UIImage")
        return nil
    }
    
    print("Image properties - Size: \(cgImage.width)x\(cgImage.height), BitsPerComponent: \(cgImage.bitsPerComponent), BitsPerPixel: \(cgImage.bitsPerPixel), ColorSpace: \(cgImage.colorSpace.debugDescription ?? "unknown")")
    
    let textureLoader = MTKTextureLoader(device: device)
    
    // Modified texture options
    let textureOptions: [MTKTextureLoader.Option: Any] = [
        .SRGB: false,
        .generateMipmaps: true,
        .textureUsage: MTLTextureUsage([.shaderRead, .renderTarget]).rawValue,
        .allocateMipmaps: true,
        .origin: MTKTextureLoader.Origin.bottomLeft
    ]
    
    do {
        // Try direct loading first
        return try textureLoader.newTexture(cgImage: cgImage, options: textureOptions)
    } catch {
        print("Direct texture loading failed: \(error)")
        
        // Enhanced manual conversion
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bitsPerComponent = 8
        let bytesPerRow = bytesPerPixel * width
        let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * bytesPerPixel)
        
        // Clear the memory first
        rawData.initialize(repeating: 0, count: width * height * bytesPerPixel)
        
        guard let context = CGContext(data: rawData,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: bitsPerComponent,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            print("Failed to create CGContext")
            rawData.deallocate()
            return nil
        }
        
        // Flip the coordinate system
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        
        // Draw with interpolation quality
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Create texture descriptor with explicit properties
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: true
        )
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        textureDescriptor.storageMode = .shared  // Use shared for debugging
        textureDescriptor.cpuCacheMode = .writeCombined
        
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
        
        // Generate mipmaps if needed
        if textureDescriptor.mipmapLevelCount > 1 {
            guard let commandQueue = device.makeCommandQueue(),
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                print("Failed to create command objects for mipmap generation")
                rawData.deallocate()
                return texture
            }
            
            blitEncoder.generateMipmaps(for: texture)
            blitEncoder.endEncoding()
            commandBuffer.commit()
        }
        
        // Clean up
        rawData.deallocate()
        
        print("Manual texture creation successful")
        return texture
    }
}
