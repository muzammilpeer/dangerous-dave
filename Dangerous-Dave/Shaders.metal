//
//  Shaders.metal
//  Dave1
//

#include <metal_stdlib>
using namespace metal;

struct GameVertex {
    float4 position;
    float4 color;
};

struct RasterVertex {
    float4 position [[position]];
    float4 color;
};

vertex RasterVertex vertexShader(uint vertexID [[vertex_id]],
                                 const device GameVertex *vertices [[buffer(0)]])
{
    RasterVertex out;
    out.position = vertices[vertexID].position;
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 fragmentShader(RasterVertex in [[stage_in]])
{
    return in.color;
}
