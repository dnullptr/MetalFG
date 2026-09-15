#include <metal_stdlib>
#include "../Headers/ShaderTypes.h"

using namespace metal;

// Structure passing data from vertex shader to fragment shader
struct RasterizerData {
    float4 position [[position]];       // Clip-space position
    float2 texCoords;                  // Passthrough UV coordinates
    float2 ndc;                        // Target Normalized Device Coordinates [-1, 1]
};

// ============================================================================
// Vertex Shader: Full-Screen Reprojection Quad
// ============================================================================
vertex RasterizerData metalfg_vertex(uint vertexID [[vertex_id]],
                                     constant MetalFGVertex *vertices [[buffer(MetalFGBufferIndexVertices)]],
                                     constant MetalFGUniforms &uniforms [[buffer(MetalFGBufferIndexUniforms)]]) {
    RasterizerData out;
    
    // Read pre-defined quad vertex
    float2 pos = vertices[vertexID].position;
    out.position = float4(pos, 0.0, 1.0);
    out.texCoords = vertices[vertexID].texCoords;
    out.ndc = pos;
    
    return out;
}

// ============================================================================
// Fragment Shader: Asynchronous Timewarp (ATW) Inverse Homography Sampler
// ============================================================================
fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],
                                 texture2d<float, access::sample> sourceTexture [[texture(MetalFGTextureIndexSource)]],
                                 constant MetalFGUniforms &uniforms [[buffer(MetalFGBufferIndexUniforms)]]) {
    // Current target pixel in homogeneous NDC coordinates [x, y, 1]^T
    float3 targetNDC = float3(in.ndc.x, in.ndc.y, 1.0);
    
    // Reproject target pixel into source base frame coordinates via homography H:
    // P_src = H * P_target
    float3 sourceProj = uniforms.homographyMatrix * targetNDC;
    
    // Perspective division
    float w = sourceProj.z;
    
    // Guard against points behind camera or projection singularity
    if (w <= 0.0001) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    
    float2 srcNDC = sourceProj.xy / w;
    
    // Convert source NDC [-1, 1] to Metal UV coordinates [0, 1]
    // Note: Metal NDC has Y pointing up (+1 at top, -1 at bottom),
    // while texture coordinates have V pointing down (0 at top, 1 at bottom).
    float u = (srcNDC.x + 1.0) * 0.5;
    float v = (1.0 - srcNDC.y) * 0.5;
    
    // Check out-of-bounds bounds (disocclusion / viewport edges during rotation)
    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) {
        // Outside captured frame buffer -> render black border
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    
    // Calculate distance to nearest viewport border for smooth edge fading
    float distToBorderX = min(u, 1.0 - u);
    float distToBorderY = min(v, 1.0 - v);
    float minBorderDist = min(distToBorderX, distToBorderY);
    
    // Smoothstep edge falloff to avoid hard pixel jaggedness at the warped boundary
    float fadeWidth = uniforms.edgeFadeParams.x; // Default ~0.02 (2% border fade)
    if (fadeWidth < 0.0001) fadeWidth = 0.02;
    float edgeFade = smoothstep(0.0, fadeWidth, minBorderDist);
    
    // High-quality bilinear sampler with edge clamping
    constexpr sampler linearSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);
    
    float4 sampledColor = sourceTexture.sample(linearSampler, float2(u, v));
    
    // Apply edge fade
    sampledColor.rgb *= edgeFade;
    
    // Debug overlay: if debugColor alpha is > 0, blend tint to visualize synthetic frames
    if (uniforms.debugColor.a > 0.0) {
        sampledColor.rgb = mix(sampledColor.rgb, uniforms.debugColor.rgb, uniforms.debugColor.a);
    }
    
    return sampledColor;
}

