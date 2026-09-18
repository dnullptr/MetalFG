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

// Fast candidate evaluation using pre-sampled current frame luma in registers
inline float eval_candidate_luma(texture2d<float, access::sample> prevTexture,
                                const thread float2 uvsCurr[9],
                                const thread float lCurr[9],
                                float2 candidate) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float error = 0.0f;
    for (int i = 0; i < 9; i++) {
        float lPrev = rgb_to_luma(prevTexture.sample(s, uvsCurr[i] - candidate));
        error += abs(lCurr[i] - lPrev);
    }
    return error * (1.0f / 9.0f);
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
// Compute Kernel 1: Concentric Multi-Radius Optical Flow & UI Anchoring
// ============================================================================
kernel void metalfg_block_motion_estimation(uint2 gid [[thread_position_in_grid]],
                                           texture2d<float, access::sample> prevTexture [[texture(MetalFGBMETexturePrev)]],
                                           texture2d<float, access::sample> currTexture [[texture(MetalFGBMETextureCurr)]],
                                           texture2d<float, access::write> motionVectors [[texture(MetalFGBMETextureMotionVectors)]],
                                           constant MetalFGBMEUniforms &uniforms [[buffer(MetalFGBufferIndexBMEUniforms)]]) {
    if (gid.x >= uniforms.gridDimensions.x || gid.y >= uniforms.gridDimensions.y) {
        return;
    }
    
    // UV center of this macroblock
    float2 centerUV = (float2(gid) + 0.5f) / float2(uniforms.gridDimensions);
    
    // Identify standard mobile HUD / UI anchor zones:
    bool isHUDZone = (centerUV.y < 0.18f) ||
                     (centerUV.x < 0.35f && centerUV.y > 0.55f) ||
                     (centerUV.x > 0.65f && centerUV.y > 0.55f);
    
    const float dUV = 0.002f;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    
    // 1. Pre-cache 9 luma samples of current frame in fast registers
    float2 uvsCurr[9];
    float lCurr[9];
    int idx = 0;
    for (int py = -1; py <= 1; py++) {
        for (int px = -1; px <= 1; px++) {
            uvsCurr[idx] = centerUV + float2(px, py) * dUV;
            lCurr[idx] = rgb_to_luma(currTexture.sample(s, uvsCurr[idx]));
            idx++;
        }
    }
    
    // 2. ALWAYS test stationary candidate (0, 0) first (Zero Motion / Static UI candidate)
    float errZero = eval_candidate_luma(prevTexture, uvsCurr, lCurr, float2(0.0f, 0.0f));
    
    // Static UI anchoring
    float effectiveThreshold = isHUDZone ? (uniforms.uiThreshold * 1.5f) : (uniforms.uiThreshold * 0.25f);
    if (errZero < effectiveThreshold) {
        motionVectors.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    
    float bestError = errZero;
    float2 bestVector = float2(0.0f, 0.0f);
    float2 prior = uniforms.touchVelocity;
    
    // 3. Concentric Multi-Radius Search (Zero Blind Spots)
    // Evaluates 4 concentric rings to capture all velocity ranges directly:
    // Ring 1 (Micro: ~1.5px): Floating companion (Paimon), breathing, cloth simulation
    // Ring 2 (Sub-Medium: ~4.5px): Walking, slow camera drift
    // Ring 3 (Medium-Fast: ~10px): Running, active camera pan
    // Ring 4 (Coarse: ~22px): Quick swipes, fast camera rotation
    
    const float r1 = 0.0012f;
    const float r2 = 0.0035f;
    const float r3 = 0.0080f;
    const float r4 = clamp(uniforms.searchRadius * 0.50f, 0.015f, uniforms.maxDisplacement);
    
    // 8-directional normalized vectors
    const float2 dirs[8] = {
        float2( 1.0f,  0.0f), float2(-1.0f,  0.0f),
        float2( 0.0f,  1.0f), float2( 0.0f, -1.0f),
        float2( 0.7071f,  0.7071f), float2(-0.7071f,  0.7071f),
        float2( 0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)
    };
    
    // Test prior candidate if provided
    if (dot(prior, prior) > 1e-6f) {
        float errPrior = eval_candidate_luma(prevTexture, uvsCurr, lCurr, prior);
        if (errPrior < bestError) {
            bestError = errPrior;
            bestVector = prior;
        }
    }
    
    // Search Ring 1: Micro-motion (captures subtle floating / idle bobbing: 4 cardinal directions)
    for (int i = 0; i < 4; i++) {
        float2 cand = dirs[i] * r1;
        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);
        if (isHUDZone) err += 0.04f;
        if (err < bestError) {
            bestError = err;
            bestVector = cand;
        }
    }
    
    // Search Ring 2: Sub-Medium motion (walking / gentle movement: 8 directions)
    for (int i = 0; i < 8; i++) {
        float2 cand = dirs[i] * r2;
        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);
        if (isHUDZone) err += 0.04f;
        if (err < bestError) {
            bestError = err;
            bestVector = cand;
        }
    }
    
    // Search Ring 3: Medium-Fast motion (running / standard camera pans: 8 directions)
    for (int i = 0; i < 8; i++) {
        float2 cand = dirs[i] * r3;
        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);
        if (isHUDZone) err += 0.04f;
        if (err < bestError) {
            bestError = err;
            bestVector = cand;
        }
    }
    
    // Search Ring 4: Coarse motion around prior or origin (4 cardinal directions)
    float2 coarseBase = (dot(prior, prior) > 1e-6f) ? prior : float2(0.0f, 0.0f);
    for (int i = 0; i < 4; i++) {
        float2 cand = coarseBase + dirs[i] * r4;
        float candLen = length(cand);
        if (candLen > uniforms.maxDisplacement) cand = (cand / candLen) * uniforms.maxDisplacement;
        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);
        if (isHUDZone) err += 0.04f;
        if (err < bestError) {
            bestError = err;
            bestVector = cand;
        }
    }
    
    // Fine Sub-Pixel Refinement around best candidate
    if (dot(bestVector, bestVector) > 1e-7f) {
        float refineStep = r1 * 0.5f;
        for (int i = 0; i < 4; i++) {
            float2 cand = bestVector + dirs[i] * refineStep;
            float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);
            if (err < bestError) {
                bestError = err;
                bestVector = cand;
            }
        }
    }
    
    // False-motion rejection:
    if (bestError >= errZero * 0.97f) {
        bestVector = float2(0.0f, 0.0f);
    }
    
    // Clamp final vector magnitude
    float finalLen = length(bestVector);
    if (finalLen > uniforms.maxDisplacement) {
        bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;
    }
    
    motionVectors.write(float4(bestVector, 0.0f, 1.0f), gid);
}

// ============================================================================
// Compute Kernel 2: 3x3 L1 Vector Median Filter (Preserves True Motion Angles)
// ============================================================================
kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],
                                        texture2d<float, access::read> inVectors [[texture(MetalFGSmoothTextureInput)]],
                                        texture2d<float, access::write> outVectors [[texture(MetalFGSmoothTextureOutput)]]) {
    uint width = inVectors.get_width();
    uint height = inVectors.get_height();
    if (gid.x >= width || gid.y >= height) return;
    
    float2 vectors[9];
    int idx = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);
            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);
            vectors[idx] = inVectors.read(uint2(cx, cy)).xy;
            idx++;
        }
    }
    
    // L1 Vector Median: Find vector v_i minimizing sum of Euclidean distances to all neighbors
    float minDistanceSum = 1e9f;
    int bestIndex = 4; // Center pixel default
    
    for (int i = 0; i < 9; i++) {
        float distSum = 0.0f;
        for (int j = 0; j < 9; j++) {
            distSum += distance(vectors[i], vectors[j]);
        }
        if (distSum < minDistanceSum) {
            minDistanceSum = distSum;
            bestIndex = i;
        }
    }
    
    outVectors.write(float4(vectors[bestIndex], 0.0f, 1.0f), gid);
}

// ============================================================================
// Fragment Shader: Motion-Compensated Forward Warping with Smooth Boundary Ramp
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
    
    // Static UI check: Zero motion -> bit-exact passthrough
    float mvLenSq = dot(mv, mv);
    if (mvLenSq < 1e-7f) {
        return origColor;
    }
    
    float2 warpedUV = clamp(in.texCoords - mv * uniforms.timeOffsetFactor, float2(0.001f), float2(0.999f));
    float4 warpedColor = sourceTexture.sample(linearSampler, warpedUV);
    
    // Seamless transition at motion boundaries:
    // Linearly blend from static origColor to solid warpedColor over a subtle motion threshold.
    // NO ghosting, NO double-image, NO color-distance rejection that tears moving edges!
    float mvMag = sqrt(mvLenSq);
    float motionWeight = smoothstep(0.0005f, 0.0025f, mvMag);
    float4 finalColor = mix(origColor, warpedColor, motionWeight);
    
    if (uniforms.pad[0] > 0.5f) {
        finalColor.g = min(1.0f, finalColor.g * 1.25f + 0.08f);
    }
    return finalColor;
}
