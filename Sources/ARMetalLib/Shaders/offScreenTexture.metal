//
//  offScreenTexture.metal
//  ARMetalLib
//
//  Created by Yuvraj Kadale on 28/10/25.
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

vertex VertexOut texture_vertex(VertexIn in [[stage_in]], constant float4x4 &mvpMatrix [[buffer(1)]]) {
    VertexOut out;
    out.position = mvpMatrix * float4(in.position, 1.0);
    out.texCoord = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    out.textureIndex = in.textureIndex;
    return out;
}

fragment float4 texture_fragment(VertexOut in [[stage_in]], texture2d<float> colorTexture [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return colorTexture.sample(s, in.texCoord);
}
