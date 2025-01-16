//
//  File.swift
//  ARMetalLib
//
//  Created by Vishwas Prakash on 16/01/25.
//

import Metal

public struct Vertex {
    public var position: SIMD3<Float>
    public var texCoord: SIMD2<Float>
    public var textureIndex: UInt32
    
    public init(position: SIMD3<Float>, texCoord: SIMD2<Float>, textureIndex: UInt32) {
        self.position = position
        self.texCoord = texCoord
        self.textureIndex = textureIndex
    }
}
