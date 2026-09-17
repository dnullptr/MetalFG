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
// Compute Kernel 1: Screen-Space Block Motion Estimation (BME) & UI Anchoring
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
    
    // Identify standard mobile HUD / UI anchor zones:
    // Top bar (y < 0.18): Minimap, menu, team status
    // Bottom-left (x < 0.35, y > 0.55): Virtual joystick
    // Bottom-right (x > 0.65, y > 0.55): Attack, elemental skill, jump buttons
    bool isHUDZone = (centerUV.y < 0.18f) ||
                     (centerUV.x < 0.35f && centerUV.y > 0.55f) ||
                     (centerUV.x > 0.65f && centerUV.y > 0.55f);
    
    const float dUV = 0.004f;
    
    // 1. ALWAYS test stationary candidate (0, 0) first (Zero Motion / Static UI candidate)
    float errZero = 0.0f;
    for (int py = -1; py <= 1; py++) {
        for (int px = -1; px <= 1; px++) {
            float2 uvCurr = centerUV + float2(px, py) * dUV;
            float lCurr = rgb_to_luma(currTexture.sample(s, uvCurr));
            float lPrev = rgb_to_luma(prevTexture.sample(s, uvCurr));
            errZero += abs(lCurr - lPrev);
        }
    }
    errZero /= 9.0f;
    
    // In HUD zones, give candidate (0, 0) a 50% extra threshold tolerance
    float effectiveThreshold = isHUDZone ? (uniforms.uiThreshold * 1.5f) : uniforms.uiThreshold;
    if (errZero < effectiveThreshold) {
        // Locked to stationary UI / background: zero displacement
        motionVectors.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    
    // 2. Motion Search centered on Touch Camera Velocity Prior:
    float2 prior = uniforms.touchVelocity;
    float bestError = errZero; // (0, 0) is the baseline to beat
    float2 bestVector = float2(0.0f, 0.0f);
    
    float stepSize = uniforms.searchRadius / 4.0f;
    
    // 5x5 candidate search grid
    for (int sy = -2; sy <= 2; sy++) {
        for (int sx = -2; sx <= 2; sx++) {
            float2 candidate = prior + float2(sx, sy) * stepSize;
            
            // Clamp candidate magnitude to max allowed displacement
            float candLen = length(candidate);
            if (candLen > uniforms.maxDisplacement) {
                candidate = (candidate / candLen) * uniforms.maxDisplacement;
            }
            
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
            error /= 9.0f;
            
            // Regularization penalty for deviating from prior/zero to prevent noisy random matching
            error += length(candidate - prior) * 0.03f;
            if (isHUDZone) {
                error += 0.04f; // Extra penalty for motion in HUD zones
            }
            
            if (error < bestError) {
                bestError = error;
                bestVector = candidate;
            }
        }
    }
    
    // Clamp final vector magnitude
    float finalLen = length(bestVector);
    if (finalLen > uniforms.maxDisplacement) {
        bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;
    }
    
    motionVectors.write(float4(bestVector, 0.0f, 1.0f), gid);
}

// ============================================================================
// Compute Kernel 2: 3x3 Spatial Median Filter (Kills Boiling Shimmer)
// ============================================================================
inline float median9(float p[9]) {
    // Fast register-based sorting network for 9 scalar values
    for (int i = 0; i < 5; i++) {
        for (int j = i + 1; j < 9; j++) {
            if (p[j] < p[i]) {
                float tmp = p[i];
                p[i] = p[j];
                p[j] = tmp;
            }
        }
    }
    return p[4];
}

kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],
                                        texture2d<float, access::read> inVectors [[texture(MetalFGSmoothTextureInput)]],
                                        texture2d<float, access::write> outVectors [[texture(MetalFGSmoothTextureOutput)]]) {
    uint width = inVectors.get_width();
    uint height = inVectors.get_height();
    if (gid.x >= width || gid.y >= height) return;
    
    float vx[9];
    float vy[9];
    int idx = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);
            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);
            float2 v = inVectors.read(uint2(cx, cy)).xy;
            vx[idx] = v.x;
            vy[idx] = v.y;
            idx++;
        }
    }
    
    float medX = median9(vx);
    float medY = median9(vy);
    
    outVectors.write(float4(medX, medY, 0.0f, 1.0f), gid);
}

// ============================================================================
// Fragment Shader: Motion-Compensated Forward Warping with Disocclusion Rejection
// ============================================================================
fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],
                                 texture2d<float, access::sample> sourceTexture [[texture(MetalFGTextureIndexSource)]],
                                 texture2d<float, access::sample> motionVectors [[texture(MetalFGTextureIndexMotionVectors)]],
                                 constant MetalFGWarpUniforms &uniforms [[buffer(MetalFGBufferIndexWarpUniforms)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);
    
    float4 origColor = sourceTexture.sample(linearSampler, in.texCoords);
    
    // Bilinearly sample the spatially smoothed motion vector field
    float2 mv = motionVectors.sample(linearSampler, in.texCoords).xy;
    
    // Static UI check: If motion vector is zero, return untouched original color (zero blur, zero distortion)
    if (dot(mv, mv) < 1e-7f) {
        return origColor;
    }
    
    // Backward mapping: To find the pixel value at in.texCoords at time t + 0.5,
    // we must look backward into the source frame at in.texCoords - mv * uniforms.timeOffsetFactor!
    float2 warpedUV = in.texCoords - mv * uniforms.timeOffsetFactor;
    float4 warpedColor = sourceTexture.sample(linearSampler, warpedUV);
    
    // Disocclusion Rejection:
    // When moving edges reveal new background or when motion estimation fails,
    // warpedColor and origColor diverge significantly.
    // In that case, smoothly blend back towards origColor to eliminate ghosting!
    float colorDist = distance(warpedColor.rgb, origColor.rgb);
    float confidence = smoothstep(0.28f, 0.04f, colorDist);
    
    return mix(origColor, warpedColor, confidence);
}
