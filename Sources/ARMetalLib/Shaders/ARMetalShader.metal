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

struct StaticRectVertex {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct RectVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Modified static rectangle vertex shader with stage_in
vertex RectVertexOut staticRectVertexShader(StaticRectVertex in [[stage_in]]) {
    RectVertexOut out;
    out.position = float4(in.position, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

// Modified static rectangle fragment shader with stage_in
fragment float4 staticRectFragmentShader(RectVertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]]) {
    return texture.sample(textureSampler, in.texCoord);
}

// Existing vertex shaders remain the same
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
    float4 maskColor = maskTexture.sample(textureSampler, in.texCoord);
    
    bool shouldWrite = maskColor.r > 0.5;
    
    if (!shouldWrite) {
        discard_fragment();
    }
    
    return float4(0.0, 0.0, 0.0, maskColor.r);
}

// Existing mask fragment shader
fragment float4 maskFragmentShader(VertexOut in [[stage_in]]) {
    return float4(0.0, 0.0, 0.0, 0.0);
}

// Main vertex shader remains the same
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

// NEW: Custom fragment shader with split texture coordinates
fragment float4 fragmentShaderSplitTextureLR(VertexOut in [[stage_in]],
                                         array<texture2d<float>, 8> textures [[texture(0)]],
                                         sampler textureSampler [[sampler(0)]]) {
    // Modify texture coordinates as per original code
    float2 textureCoordinates = in.texCoord;
    textureCoordinates.x = textureCoordinates.x / 2.0;
    
    // Sample the main texture
    float4 textureColor = textures[in.textureIndex].sample(textureSampler, textureCoordinates);
    
    // Sample the alpha portion from the same texture but offset
    float4 alphaColor = textures[in.textureIndex].sample(textureSampler, float2(0.5, 0.0) + textureCoordinates);
    
    // Use the red channel of the alpha portion as the alpha value
    textureColor.a = alphaColor.r;
    
    return textureColor;
}

fragment float4 fragmentShaderSplitTextureTD(VertexOut in [[stage_in]],
                                      array<texture2d<float>, 8> textures [[texture(0)]],
                                      sampler textureSampler [[sampler(0)]]) {
    // Modify texture coordinates as per original code
    float2 textureCoordinates = in.texCoord;
    textureCoordinates.y = textureCoordinates.y / 2.0;
    
    // Sample the main texture
    float4 textureColor = textures[in.textureIndex].sample(textureSampler, textureCoordinates);
    
    // Sample the alpha portion from the same texture but offset
    float4 alphaColor = textures[in.textureIndex].sample(textureSampler, float2(0.0, 0.5) + textureCoordinates);
    
    // Use the red channel of the alpha portion as the alpha value
    textureColor.a = alphaColor.r;
    
    return textureColor;
}

// Existing main fragment shader
fragment float4 fragmentShader(VertexOut in [[stage_in]], array<texture2d<float>, 8> textures [[texture(0)]], sampler textureSampler [[sampler(0)]]) {
    float4 color = textures[in.textureIndex].sample(textureSampler, in.texCoord);
    return color;
}

// Existing vertex shader with mask
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

// NEW: Modified fragment shader with mask and split texture
fragment float4 fragmentShaderSplitTextureWithMask(VertexOut in [[stage_in]],
                                                 array<texture2d<float>, 8> textures [[texture(0)]],
                                                 texture2d<float> maskTexture [[texture(8)]],
                                                 sampler textureSampler [[sampler(0)]]) {
    // Modify texture coordinates
    float2 textureCoordinates = in.texCoord;
    textureCoordinates.x = textureCoordinates.x / 2.0;
    
    // Sample the main texture
    float4 textureColor = textures[in.textureIndex].sample(textureSampler, textureCoordinates);
    
    // Sample the alpha portion
    float4 alphaColor = textures[in.textureIndex].sample(textureSampler, float2(0.5, 0.0) + textureCoordinates);
    
    // Sample the mask
    float4 mask = maskTexture.sample(textureSampler, in.texCoord);
    
    // Combine the alpha from both the split texture and the mask
    textureColor.a = alphaColor.r * mask.r;
    
    return textureColor;
}

// Existing fragment shader with mask
fragment float4 fragmentShaderWithMask(VertexOut in [[stage_in]],
                                     array<texture2d<float>, 8> textures [[texture(0)]],
                                     texture2d<float> maskTexture [[texture(8)]],
                                     sampler textureSampler [[sampler(0)]]) {
    float4 color = textures[in.textureIndex].sample(textureSampler, in.texCoord);
    float4 mask = maskTexture.sample(textureSampler, in.texCoord);
    return float4(color.rgb, color.a * mask.r);
}
