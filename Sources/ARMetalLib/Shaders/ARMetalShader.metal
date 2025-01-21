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


// New struct for blur parameters
struct BlurUniforms {
    float2 texelSize;    // 1.0 / texture dimensions
    float radius;        // Blur radius
    float sigma;         // Gaussian sigma value
};

// Utility function to calculate Gaussian weight
float gaussianWeight(float x, float sigma) {
    float pi = 3.14159265359;
    return (1.0 / sqrt(2.0 * pi * sigma * sigma)) * exp(-(x * x) / (2.0 * sigma * sigma));
}

// Vertical blur vertex shader
vertex VertexOut vertexShaderBlurVertical(VertexIn in [[stage_in]],
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

// Horizontal blur vertex shader
vertex VertexOut vertexShaderBlurHorizontal(VertexIn in [[stage_in]],
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

// Vertical blur fragment shader
fragment float4 fragmentShaderBlurVertical(VertexOut in [[stage_in]],
                                         texture2d<float> sourceTexture [[texture(0)]],
                                         constant BlurUniforms &uniforms [[buffer(0)]],
                                         sampler textureSampler [[sampler(0)]]) {
    float4 color = float4(0.0);
    float weightSum = 0.0;
    
    // Calculate weights and sample vertically
    for (int i = -int(uniforms.radius); i <= int(uniforms.radius); i++) {
        float2 offset = float2(0.0, float(i) * uniforms.texelSize.y);
        float weight = gaussianWeight(float(i), uniforms.sigma);
        color += sourceTexture.sample(textureSampler, in.texCoord + offset) * weight;
        weightSum += weight;
    }
    
    return color / weightSum;
}

// Horizontal blur fragment shader
fragment float4 fragmentShaderBlurHorizontal(VertexOut in [[stage_in]],
                                           texture2d<float> sourceTexture [[texture(0)]],
                                           constant BlurUniforms &uniforms [[buffer(0)]],
                                           sampler textureSampler [[sampler(0)]]) {
    float4 color = float4(0.0);
    float weightSum = 0.0;
    
    // Calculate weights and sample horizontally
    for (int i = -int(uniforms.radius); i <= int(uniforms.radius); i++) {
        float2 offset = float2(float(i) * uniforms.texelSize.x, 0.0);
        float weight = gaussianWeight(float(i), uniforms.sigma);
        color += sourceTexture.sample(textureSampler, in.texCoord + offset) * weight;
        weightSum += weight;
    }
    
    return color / weightSum;
}

// Combined blur and mask fragment shader
fragment float4 fragmentShaderBlurWithMask(VertexOut in [[stage_in]],
                                         texture2d<float> blurredTexture [[texture(0)]],
                                         texture2d<float> maskTexture [[texture(8)]],
                                         sampler textureSampler [[sampler(0)]]) {
    // Sample from the blurred texture
    float4 blurredColor = blurredTexture.sample(textureSampler, in.texCoord);
    
    // Sample from the mask texture
    float4 mask = maskTexture.sample(textureSampler, in.texCoord);
    
    // Apply the mask to the blurred result
    return float4(blurredColor.rgb, blurredColor.a * mask.r);
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
