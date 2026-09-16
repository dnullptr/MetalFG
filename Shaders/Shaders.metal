#include <metal_stdlib>
#include "../Headers/ShaderTypes.h"

using namespace metal;

// Structure passing data from vertex shader to fragment shader
struct RasterizerData {
    float4 position [[position]];       // Clip-space position
    float2 texCoords;                  // Passthrough UV coordinates
};

// Helper: Convert RGBA to standard perceptual luminance
inline float rgb_to_luma(float4 c) {
    return dot(c.rgb, float3(0.299f, 0.587f, 0.114f));
}

// ============================================================================
// Vertex Shader: Full-Screen Reprojection Quad
// ============================================================================
vertex RasterizerData metalfg_vertex(uint vertexID [[vertex_id]],
                                     constant MetalFGVertex *vertices [[buffer(MetalFGBufferIndexVertices)]]) {
    RasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.texCoords = vertices[vertexID].texCoords;
    return out;
}

// ============================================================================
// Compute Kernel: Screen-Space Block Motion Estimation (BME) & UI Masking
// ============================================================================
kernel void metalfg_block_motion_estimation(uint2 gid [[thread_position_in_grid]],
                                           texture2d<float, access::sample> prevTexture [[texture(MetalFGBMETexturePrev)]],
                                           texture2d<float, access::sample> currTexture [[texture(MetalFGBMETextureCurr)]],
                                           texture2d<float, access::write> motionVectors [[texture(MetalFGBMETextureMotionVectors)]],
                                           constant MetalFGBMEUniforms &uniforms [[buffer(MetalFGBufferIndexBMEUniforms)]]) {
    if (gid.x >= uniforms.gridDimensions.x || gid.y >= uniforms.gridDimensions.y) {
        return;
    }
    
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    
    // UV center of this macroblock
    float2 centerUV = (float2(gid) + 0.5f) / float2(uniforms.gridDimensions);
    
    // 1. Static UI Detection:
    // Sample a 3x3 pattern around the block center. If pixels are identical between frames,
    // this block contains static UI (minimap, health bar, dialogue, buttons).
    float centerDiff = 0.0f;
    const float dUV = 0.004f;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 sampleUV = centerUV + float2(dx, dy) * dUV;
            float lCurr = rgb_to_luma(currTexture.sample(s, sampleUV));
            float lPrev = rgb_to_luma(prevTexture.sample(s, sampleUV));
            centerDiff += abs(lCurr - lPrev);
        }
    }
    centerDiff /= 9.0f;
    
    if (centerDiff < uniforms.uiThreshold) {
        // UI Block detected: Zero motion vector locks pixels in place, preventing text smearing
        motionVectors.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    
    // 2. Motion Search centered on Touch Camera Velocity Prior:
    float2 prior = uniforms.touchVelocity;
    float bestError = 1e6f;
    float2 bestVector = prior;
    
    float stepSize = uniforms.searchRadius / 4.0f;
    
    // 5x5 candidate search grid centered on touch prior
    for (int sy = -2; sy <= 2; sy++) {
        for (int sx = -2; sx <= 2; sx++) {
            float2 candidate = prior + float2(sx, sy) * stepSize;
            
            float error = 0.0f;
            for (int py = -1; py <= 1; py++) {
                for (int px = -1; px <= 1; px++) {
                    float2 uvCurr = centerUV + float2(px, py) * dUV;
                    float2 uvPrev = uvCurr - candidate;
                    
                    float lCurr = rgb_to_luma(currTexture.sample(s, uvCurr));
                    float lPrev = rgb_to_luma(prevTexture.sample(s, uvPrev));
                    error += abs(lCurr - lPrev);
                }
            }
            
            // Regularization penalty for large vector deviations
            error += length(candidate) * 0.02f;
            
            if (error < bestError) {
                bestError = error;
                bestVector = candidate;
            }
        }
    }
    
    motionVectors.write(float4(bestVector, 0.0f, 1.0f), gid);
}

// ============================================================================
// Fragment Shader: Motion-Compensated Forward Warping
// ============================================================================
fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],
                                 texture2d<float, access::sample> sourceTexture [[texture(MetalFGTextureIndexSource)]],
                                 texture2d<float, access::sample> motionVectors [[texture(MetalFGTextureIndexMotionVectors)]],
                                 constant MetalFGWarpUniforms &uniforms [[buffer(MetalFGBufferIndexWarpUniforms)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);
    
    // Bilinearly sample the motion vector field at the current pixel
    float2 mv = motionVectors.sample(linearSampler, in.texCoords).xy;
    
    // Static UI check: If motion vector is zero, sample directly (zero blur, zero distortion)
    if (dot(mv, mv) < 1e-7f) {
        return sourceTexture.sample(linearSampler, in.texCoords);
    }
    
    // Forward motion extrapolation: Advance pixel by timeOffsetFactor (0.5 for midpoint)
    float2 warpedUV = in.texCoords + mv * uniforms.timeOffsetFactor;
    return sourceTexture.sample(linearSampler, warpedUV);
}
