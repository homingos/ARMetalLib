//
//  File.swift
//  ARMetalLib
//
//  Created by Shiv Prakash on 04/02/25.
//

import Foundation
import SceneKit
import MetalKit
import ARMetalLib

public class MetalViewCoordinateConverter {
    
    private let view: UIView
    private let sceneView: SCNView?
    private let metalView: MTKView?
    
    public init(view: UIView, sceneView: SCNView?, metalView: MTKView?) {
        self.view = view
        self.sceneView = sceneView
        self.metalView = metalView
    }
    
    @MainActor public func convertToTextureCoordinates(
        from screenLocation: CGPoint,
        isFullScreenMode: Bool,
        targetNode: SCNNode? = nil
    ) -> CGPoint? {
        if isFullScreenMode {
            return convertFullScreenToTexture(screenLocation)
        } else {
            return convertSceneHitToTexture(screenLocation, targetNode: targetNode)
        }
    }
    
    @MainActor public func convertFullScreenToTexture(_ location: CGPoint) -> CGPoint {
        let viewHeight = view.frame.height
        let viewWidth = view.frame.width
        
        let normalizedX = location.x / viewWidth
        
        // For consistency with Metal coordinates
        let normalizedY = location.y / viewHeight
        
        // Clamp values between 0 and 1
        let clampedX = min(max(normalizedX, 0), 1)
        let clampedY = min(max(normalizedY, 0), 1)
        
        return CGPoint(x: clampedX, y: 1.0 - clampedY) // Flip Y for Metal
    }
    
    @MainActor public func convertSceneHitToTexture(_ location: CGPoint, targetNode: SCNNode?) -> CGPoint? {
        guard let sceneView = sceneView,
              let node = targetNode else { return nil }
        
        // Perform hit testing
        let hitResults = sceneView.hitTest(location, options: nil)
        guard let hitResult = hitResults.first,
              let planeGeometry = hitResult.node.geometry as? SCNPlane else {
            return nil
        }
        
        // Get local coordinates from hit test
        let hitPosition = hitResult.localCoordinates
        
        // Convert to normalized texture coordinates (0 to 1)
        let textureX = Float(hitPosition.x) / Float(planeGeometry.width) + 0.5
        let textureY = Float(hitPosition.y) / Float(planeGeometry.height) + 0.5
        
        // Clamp values
        let clampedX = min(max(textureX, 0), 1)
        let clampedY = min(max(textureY, 0), 1)
        
        return CGPoint(x: Double(clampedX), y: Double(clampedY))
    }
    
    @MainActor public func sconvertMetalViewPoint(_ point: CGPoint) -> CGPoint {
        guard let metalView = metalView else { return point }
        
        // Convert point to metal view's coordinate space
        let metalPoint = metalView.convert(point, from: nil)
        
        // Normalize coordinates
        let normalizedX = metalPoint.x / metalView.bounds.width
        
        // For Metal: Y increases downward, so we flip it
        let normalizedY = 1.0 - (metalPoint.y / metalView.bounds.height)
        
        return CGPoint(x: normalizedX, y: normalizedY)
    }
}
