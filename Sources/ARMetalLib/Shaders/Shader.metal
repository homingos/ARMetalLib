//
//  Shader.metal
//  maskImage
//
//  Created by Vishwas Prakash on 18/12/24.
//

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    uint textureIndex [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint textureIndex;
};

// Mask vertex shader
vertex VertexOut maskVertexShader(VertexIn in [[stage_in]], constant float4x4 *matrices [[buffer(1)]]) {
    VertexOut out;
    
    float4x4 modelMatrix = matrices[0];
    float4x4 viewMatrix = matrices[1];
    float4x4 projectionMatrix = matrices[2];
    float4x4 modelViewMatrix = viewMatrix * modelMatrix;
    
    out.position = projectionMatrix * modelViewMatrix * float4(in.position, 1.0);  // Use NDC coordinates directly for mask
    out.texCoord = in.texCoord;
    out.textureIndex = in.textureIndex;
    
    return out;
}

// Mask fragment shader - writes to stencil buffer
fragment float4 maskFragmentShader(VertexOut in [[stage_in]]) {
    // Return clear color but we'll write to stencil buffer
    return float4(0.0, 0.0, 0.0, 0.0);
}

// Main vertex shader
vertex VertexOut vertexShader(VertexIn in [[stage_in]], constant float4x4 *matrices [[buffer(1)]]) {
    VertexOut out;
    
    float4x4 modelMatrix = matrices[0];
    float4x4 viewMatrix = matrices[1];
    float4x4 projectionMatrix = matrices[2];
    float4x4 modelViewMatrix = viewMatrix * modelMatrix;
    
    out.position = projectionMatrix * modelViewMatrix * float4(in.position, 1.0);
    out.texCoord = in.texCoord;
    out.textureIndex = in.textureIndex;
    
    return out;
}

// Main fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                  array<texture2d<float>, 8> textures [[texture(0)]],
                                  sampler textureSampler [[sampler(0)]]) {
    // Sample from the appropriate texture based on the index
    float4 color = textures[in.textureIndex].sample(textureSampler, in.texCoord);
    
    return color;
}
