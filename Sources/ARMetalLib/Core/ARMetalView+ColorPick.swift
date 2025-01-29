//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 28/01/25.
//

import MetalKit
import UIKit

extension ARMetalView {
    internal struct ColorPickerResources {
        let colorTexture: MTLTexture
        let colorBuffer: MTLBuffer
        
        init?(device: MTLDevice) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let buffer = device.makeBuffer(length: 4, options: .storageModeShared) else {
                return nil
            }
            
            self.colorTexture = texture
            self.colorBuffer = buffer
        }
    }
    
    // Public method to set the target texture
    public func setTargetTextureForColorPicking(image: UIImage) {
        let mtlTexture = self.device?.makeTexture(from: image)
        print("Image is set: \(mtlTexture)")
        self.targetTexture = mtlTexture
    }
    
    // Public method to handle touch location from view controller
    public func getColorAtViewLocation(_ viewLocation: CGPoint) {
        guard let targetTexture = targetTexture else { return }
        
        // Convert the view location to the metal view's coordinate space
        let metalViewLocation = self.convert(viewLocation, from: nil)
        
        // Convert to normalized coordinates (0 to 1)
        let normalizedX = metalViewLocation.x / bounds.width
        let normalizedY = metalViewLocation.y / bounds.height
        
        // Get color from the texture
        getColorFromTexture(
            texture: targetTexture,
            normalizedX: Float(normalizedX),
            normalizedY: Float(normalizedY),
            originalViewLocation: viewLocation  // Pass original location for reference
        )
    }
    
    private func getColorFromTexture(
        texture: MTLTexture,
        normalizedX: Float,
        normalizedY: Float,
        originalViewLocation: CGPoint
    ) {
        guard let device = device,
              let commandQueue = commandQueue else { return }
        
        // Lazily initialize color picker resources
        if Self.colorPickerResources == nil {
            Self.colorPickerResources = ColorPickerResources(device: device)
        }
        
        guard let resources = Self.colorPickerResources else { return }
        
        // Create command buffer
        let commandBuffer = commandQueue.makeCommandBuffer()
        let blitEncoder = commandBuffer?.makeBlitCommandEncoder()
        
        // Calculate the pixel coordinates in the texture
        let x = Int(normalizedX * Float(texture.width))
        let y = Int(normalizedY * Float(texture.height))
        
        // Ensure coordinates are within texture bounds
        let safeX = min(max(x, 0), texture.width - 1)
        let safeY = min(max(y, 0), texture.height - 1)
        
        // Copy single pixel using optimized region
        let region = MTLRegion(
            origin: MTLOrigin(x: safeX, y: safeY, z: 0),
            size: MTLSize(width: 1, height: 1, depth: 1)
        )
        
        blitEncoder?.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: region.origin,
            sourceSize: region.size,
            to: resources.colorTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        
        blitEncoder?.endEncoding()
        
        // Copy from texture to buffer
        let readEncoder = commandBuffer?.makeBlitCommandEncoder()
        readEncoder?.copy(
            from: resources.colorTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: resources.colorBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: 4,
            destinationBytesPerImage: 4
        )
        
        readEncoder?.endEncoding()
        
        // Handle color reading in completion handler
        commandBuffer?.addCompletedHandler { [weak self] _ in
            let bytes = resources.colorBuffer.contents().assumingMemoryBound(to: UInt8.self)
            let color = UIColor(
                red: CGFloat(bytes[0]) / 255.0,
                green: CGFloat(bytes[1]) / 255.0,
                blue: CGFloat(bytes[2]) / 255.0,
                alpha: CGFloat(bytes[3]) / 255.0
            )
            
            // Notify delegate on main thread
            DispatchQueue.main.async {
                if let delegate = self?.viewControllerDelegate as? TextureColorPickerDelegate {
                    delegate.didPickColor(
                        color,
                        at: originalViewLocation,  // Return the original view location
                        fromTexture: texture,
                        pixelCoordinate: CGPoint(x: safeX, y: safeY)  // Add pixel coordinates
                    )
                }
            }
        }
        
        commandBuffer?.commit()
    }
}

// Updated delegate protocol
public protocol TextureColorPickerDelegate: ARMetalViewDelegate {
    func didPickColor(
        _ color: UIColor,
        at viewLocation: CGPoint,
        fromTexture texture: MTLTexture,
        pixelCoordinate: CGPoint
    )
}

extension MTLDevice {
    func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        
        let textureLoader = MTKTextureLoader(device: self)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .generateMipmaps: true,
            .SRGB: false
        ]
        
        do {
            // Try loading with high quality settings first
            return try textureLoader.newTexture(cgImage: cgImage, options: options)
        } catch {
            print("Failed to create texture with loader: \(error)")
            return createTextureManually(from: cgImage)
        }
    }
    
    private func createTextureManually(from cgImage: CGImage) -> MTLTexture? {
        // Create texture descriptor
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: cgImage.width,
            height: cgImage.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        textureDescriptor.storageMode = .shared
        
        guard let texture = makeTexture(descriptor: textureDescriptor),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.width * bytesPerPixel
        let imageSize = cgImage.height * bytesPerRow
        
        // Allocate memory for image data
        let imageData = UnsafeMutablePointer<UInt8>.allocate(capacity: imageSize)
        defer { imageData.deallocate() }
        
        guard let context = CGContext(
            data: imageData,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        // Flip the context coordinates
        context.translateBy(x: 0, y: CGFloat(cgImage.height))
        context.scaleBy(x: 1, y: -1)
        
        // Draw image
        let rect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        context.draw(cgImage, in: rect)
        
        // Copy to texture
        let region = MTLRegionMake2D(0, 0, cgImage.width, cgImage.height)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: imageData,
            bytesPerRow: bytesPerRow
        )
        
        return texture
    }
}

