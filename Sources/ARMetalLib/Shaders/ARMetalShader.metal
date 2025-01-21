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

// Box blur vertex shader for rendering to quad
vertex VertexOut vertexShaderBlur(uint vertexID [[vertex_id]]) {
    const float2 vertices[] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    const float2 texCoords[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(vertices[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    out.textureIndex = 0;  // Single texture for blur
    return out;
}

// Box blur fragment shader
fragment float4 fragmentShaderBlur(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler texSampler [[sampler(0)]]) {
    return tex.sample(texSampler, in.texCoord);
}

// Mask vertex shader - now includes texture coordinates for mask image
vertex VertexOut maskVertexShader(VertexIn in [[stage_in]], constant float4x4 *matrices [[buffer(1)]]) {
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

// Modified mask fragment shader to use mask texture
fragment float4 maskImageFragmentShader(VertexOut in [[stage_in]],
                                 texture2d<float> maskTexture [[texture(8)]],
                                 sampler textureSampler [[sampler(0)]]) {
    // Sample the mask texture
    float4 maskColor = maskTexture.sample(textureSampler, in.texCoord);
    
    // Use the red channel threshold to determine stencil writing
    // Pixels where the mask is lighter than 0.5 will be written to stencil
    bool shouldWrite = maskColor.r > 0.5;
    
    // Discard fragment if it shouldn't be written to stencil
    if (!shouldWrite) {
        discard_fragment();
    }
    
    return float4(0.0, 0.0, 0.0, maskColor.r);  // Color doesn't matter as we're only writing to stencil
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

// Main vertex shader with mask
vertex VertexOut vertexShaderWithMask(VertexIn in [[stage_in]],
                                    constant float4x4 *matrices [[buffer(1)]]) {
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

// Fragment shader with mask texture
fragment float4 fragmentShaderWithMask(VertexOut in [[stage_in]],
                                     array<texture2d<float>, 8> textures [[texture(0)]],
                                     texture2d<float> maskTexture [[texture(8)]],
                                     sampler textureSampler [[sampler(0)]]) {
    // Sample from the content texture
    float4 color = textures[in.textureIndex].sample(textureSampler, in.texCoord);
    
    // Sample from the mask texture (using same UV coordinates)
    float4 mask = maskTexture.sample(textureSampler, in.texCoord);
    
    // Use the mask's red channel as the alpha mask (assuming grayscale mask)
    // White (1.0) in mask = fully visible, Black (0.0) = fully transparent
    return float4(color.rgb, color.a * mask.r);
}
