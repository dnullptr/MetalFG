#include <metal_stdlib>
#include "../Headers/ShaderTypes.h"

using namespace metal;

// Structure passing data from vertex shader to fragment shader
struct RasterizerData {
    float4 position [[position]];       // Clip-space position
    float2 texCoords;                  // Passthrough UV coordinates
};

// Standard perceptual luminance weights (Rec. 601 / SMFG kLuma)
constant float3 kLumaWeights = float3(0.299f, 0.587f, 0.114f);

inline float rgb_to_luma(float3 c) {
    return dot(c, kLumaWeights);
}

// SMFG Colour + Luminance Difference (msm_fg.h & lf_estimate_shader.h Miss()):
// Combines perceptual luma difference with per-channel RGB difference so two objects
// of different color but identical luminance are never mistaken for each other.
inline float rgb_luma_diff(float3 a, float3 b) {
    float3 d = abs(a - b);
    return dot(d, kLumaWeights) * 0.65f + max(d.r, max(d.g, d.b)) * 0.35f;
}

// Capped patch sample error (lf_estimate_shader.h kCap = 0.25)
// Note: Matches currTexture(uv) against prevTexture(uv - candidate),
// so a matched candidate vector is v = uv_curr - uv_prev (forward displacement from Frame N-1 to Frame N).
inline float eval_candidate_patch(texture2d<float, access::sample> prevTexture,
                                  const thread float2 uvsCurr[9],
                                  const thread float3 rgbCurr[9],
                                  float2 candidate) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float error = 0.0f;
    for (int i = 0; i < 9; i++) {
        float3 rgbPrev = prevTexture.sample(s, uvsCurr[i] - candidate).rgb;
        error += min(rgb_luma_diff(rgbCurr[i], rgbPrev), 0.25f);
    }
    return error * (1.0f / 9.0f);
}

// SMFG Round 56 Sharp Sub-Pixel Reconstruction (Clamped Catmull-Rom 5-Tap Filter):
// Restores fine sub-pixel texture energy lost by bilinear filtering during half-step
// warps while clamping strictly to the local 2x2 neighborhood min/max to prevent halo ringing.
inline float4 sample_sharp_clamped(texture2d<float, access::sample> tex,
                                   float2 uv,
                                   float2 texelSize) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 center = tex.sample(s, uv);
    float3 n0 = tex.sample(s, uv + float2(-texelSize.x, 0.0f)).rgb;
    float3 n1 = tex.sample(s, uv + float2( texelSize.x, 0.0f)).rgb;
    float3 n2 = tex.sample(s, uv + float2(0.0f, -texelSize.y)).rgb;
    float3 n3 = tex.sample(s, uv + float2(0.0f,  texelSize.y)).rgb;
    
    float3 minNeighbor = min(center.rgb, min(min(n0, n1), min(n2, n3)));
    float3 maxNeighbor = max(center.rgb, max(max(n0, n1), max(n2, n3)));
    
    // High-frequency detail restoration (matches Catmull-Rom negative lobe weight)
    float3 meanCross = (n0 + n1 + n2 + n3) * 0.25f;
    float3 sharpened = center.rgb + (center.rgb - meanCross) * 0.35f;
    return float4(clamp(sharpened, minNeighbor, maxNeighbor), center.a);
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
// Compute Kernel 1: SMFG Coarse-to-Fine Hierarchical Flow & Parabolic Subpel
// Writes float4(vx, vy, bestError, sureConfidence) into RGBA16Float grid
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
    bool isHUDZone = (centerUV.y < 0.14f) ||
                     (centerUV.x < 0.28f && centerUV.y > 0.62f) ||
                     (centerUV.x > 0.72f && centerUV.y > 0.62f);
    
    const float dUV = 0.0022f;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    
    // 1. Pre-cache 9 RGB samples of current frame in registers & compute patch contrast (Texture/Contrast)
    float2 uvsCurr[9];
    float3 rgbCurr[9];
    float3 patchMean = float3(0.0f);
    int idx = 0;
    for (int py = -1; py <= 1; py++) {
        for (int px = -1; px <= 1; px++) {
            uvsCurr[idx] = centerUV + float2(px, py) * dUV;
            rgbCurr[idx] = currTexture.sample(s, uvsCurr[idx]).rgb;
            patchMean += rgbCurr[idx];
            idx++;
        }
    }
    patchMean *= (1.0f / 9.0f);
    
    // SMFG Contrast(here): how much texture this patch actually shows
    float patchContrast = 0.0f;
    for (int i = 0; i < 9; i++) {
        patchContrast += rgb_luma_diff(rgbCurr[i], patchMean);
    }
    patchContrast *= (1.0f / 9.0f);
    
    // 2. Test stationary candidate (0, 0) first
    float errZero = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, float2(0.0f, 0.0f));
    
    // Only anchor immediately to zero in HUD zones when stationary error is near-exact
    if (isHUDZone && errZero < uniforms.uiThreshold * 0.65f && patchContrast > 0.020f) {
        float sureZero = saturate(patchContrast * 12.0f);
        motionVectors.write(float4(0.0f, 0.0f, errZero, sureZero), gid);
        return;
    }
    
    // SMFG distance regularization margin:
    // Light penalty prevents flat/untextured patches from jumping to random far matches
    // without suppressing genuine indoor camera pans.
    const float kMargin = 0.0006f;
    const float kDistPenalty = isHUDZone ? 0.25f : 0.025f;
    
    float bestError = errZero;
    float bestCost = errZero;
    float2 bestVector = float2(0.0f, 0.0f);
    float2 prior = uniforms.touchVelocity;
    
    const float2 dirs[8] = {
        float2( 1.0f,  0.0f), float2(-1.0f,  0.0f),
        float2( 0.0f,  1.0f), float2( 0.0f, -1.0f),
        float2( 0.7071f,  0.7071f), float2(-0.7071f,  0.7071f),
        float2( 0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)
    };
    
    // Stage A: Multi-Radius Seed Search around origin and touch-velocity prior
    if (dot(prior, prior) > 1e-6f) {
        float errPrior = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, prior);
        float costPrior = errPrior + kMargin * 0.5f;
        if (costPrior < bestCost) {
            bestCost = costPrior;
            bestError = errPrior;
            bestVector = prior;
        }
    }
    
    const float seedRadii[4] = {
        0.0018f,
        0.0048f,
        0.0110f,
        clamp(uniforms.searchRadius * 0.50f, 0.018f, uniforms.maxDisplacement)
    };
    
    for (int r = 0; r < 4; r++) {
        float rad = seedRadii[r];
        for (int i = 0; i < 8; i++) {
            float2 cand = dirs[i] * rad;
            float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);
            float cost = err + kMargin + kDistPenalty * length(cand - prior);
            if (cost < bestCost) {
                bestCost = cost;
                bestError = err;
                bestVector = cand;
            }
        }
    }
    
    // Stage B: 3-Level Coarse-to-Fine Hierarchical Refinement around bestVector
    // Bridges any arbitrary angle and distance between the seed rings down to sub-millimeter precision.
    const float refineSteps[3] = { 0.0040f, 0.0020f, 0.0009f };
    for (int sIdx = 0; sIdx < 3; sIdx++) {
        float stepSize = refineSteps[sIdx];
        float2 centerCand = bestVector;
        for (int i = 0; i < 8; i++) {
            float2 cand = centerCand + dirs[i] * stepSize;
            float candLen = length(cand);
            if (candLen > uniforms.maxDisplacement) {
                cand = (cand / candLen) * uniforms.maxDisplacement;
            }
            float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);
            float cost = err + kMargin * 0.5f + kDistPenalty * length(cand - prior);
            if (cost < bestCost) {
                bestCost = cost;
                bestError = err;
                bestVector = cand;
            }
        }
    }
    
    // Stage C: SMFG Analytical Parabolic Sub-Pixel Refinement (SubpelMain, msm_fg.h lines 398-404)
    if (dot(bestVector, bestVector) > 1e-8f && patchContrast > 0.005f) {
        const float stepUV = 0.0005f;
        float ex0 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(-stepUV, 0.0f));
        float ex1 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2( stepUV, 0.0f));
        float ey0 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(0.0f, -stepUV));
        float ey1 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(0.0f,  stepUV));
        
        float bendX = ex0 - 2.0f * bestError + ex1;
        float bendY = ey0 - 2.0f * bestError + ey1;
        float2 part = float2(0.0f);
        if (bendX > 1e-4f) part.x = clamp(0.5f * (ex0 - ex1) / bendX, -0.5f, 0.5f) * stepUV;
        if (bendY > 1e-4f) part.y = clamp(0.5f * (ey0 - ey1) / bendY, -0.5f, 0.5f) * stepUV;
        
        float2 subpelCand = bestVector + part;
        float errSubpel = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, subpelCand);
        if (errSubpel <= bestError) {
            bestError = errSubpel;
            bestVector = subpelCand;
        }
    }
    
    // Still vs. Moving check (FlowFinal, lf_estimate_shader.h line 401):
    // Keep motion only where it carries the patch better than standing still.
    if (bestError >= errZero - 0.0003f) {
        bestVector = float2(0.0f, 0.0f);
        bestError = errZero;
    }
    
    // Clamp final vector magnitude
    float finalLen = length(bestVector);
    if (finalLen > uniforms.maxDisplacement) {
        bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;
    }
    
    // SMFG Sure(contrast, apart) confidence (msm_fg.h line 177):
    // Measures both how much texture the block has and how well the match succeeded.
    // Flat blocks (sky, cel-shaded skin/walls) get low `sure`, allowing kernel 2 to fill them cleanly.
    float sure = saturate(patchContrast * 12.0f) * saturate(1.0f - bestError / (0.045f + patchContrast));
    
    motionVectors.write(float4(bestVector, bestError, sure), gid);
}

// ============================================================================
// Compute Kernel 2: SMFG 1.1 Outlier Removal + Flat-Region Fill + Fluid Edge Filter
// Implements msm_fg.h FillMain + EdgeMain (Round 39 fluid + SMFG 1.1 alone_near)
// Writes float4(smoothedMV.x, smoothedMV.y, sure, edgeSpread)
// ============================================================================
kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],
                                        texture2d<float, access::read> inVectors [[texture(MetalFGSmoothTextureInput)]],
                                        texture2d<float, access::write> outVectors [[texture(MetalFGSmoothTextureOutput)]]) {
    uint width = inVectors.get_width();
    uint height = inVectors.get_height();
    if (gid.x >= width || gid.y >= height) return;
    
    float4 ownData = inVectors.read(gid);
    float2 ownMV = ownData.xy;
    float ownSure = ownData.w;
    
    // 1. Read 3x3 immediate neighborhood for L1 Vector Median & SMFG 1.1 Outlier Rejection
    float2 neighbors3x3[9];
    float2 around8[8];
    int idx9 = 0;
    int idx8 = 0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);
            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);
            float2 v = inVectors.read(uint2(cx, cy)).xy;
            neighbors3x3[idx9++] = v;
            if (dx != 0 || dy != 0) {
                around8[idx8++] = v;
            }
        }
    }
    
    // Find L1 Vector Median of 3x3
    float minDistanceSum = 1e9f;
    int bestIndex = 4;
    for (int i = 0; i < 9; i++) {
        float distSum = 0.0f;
        for (int j = 0; j < 9; j++) {
            distSum += distance(neighbors3x3[i], neighbors3x3[j]);
        }
        if (distSum < minDistanceSum) {
            minDistanceSum = distSum;
            bestIndex = i;
        }
    }
    float2 medianMV = neighbors3x3[bestIndex];
    
    // SMFG 1.1 Alone-Outlier Rejection (EdgeMain, msm_fg.h lines 754-758):
    // If >= 6 of the 8 neighbors agree with the median and the center block stands alone, snap to median.
    float nearThresh = 0.0015f + 0.18f * length(medianMV);
    int agreeCount = 0;
    for (int i = 0; i < 8; i++) {
        if (distance(around8[i], medianMV) <= nearThresh) {
            agreeCount++;
        }
    }
    if (agreeCount >= 6 && distance(ownMV, medianMV) > nearThresh) {
        ownMV = medianMV;
    }
    
    // 2. SMFG FillMain + Round 39 Fluid Bilateral Smoothing over 5x5 neighborhood:
    // - Computes the confidence-weighted regional motion (`largeMV`) from textured blocks
    //   so flat/cel-shaded blocks inherit the motion of the object/scene around them instead of blotching.
    // - Smooths similar motion vectors while keeping foreground/background edges sharp.
    float2 largeSum = float2(0.0f);
    float largeWeight = 0.0f;
    
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);
            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);
            float4 other = inVectors.read(uint2(cx, cy));
            float w = other.w * ((abs(dx) == 2 || abs(dy) == 2) ? 0.5f : 1.0f);
            largeSum += other.xy * w;
            largeWeight += w;
        }
    }
    
    if (largeWeight > 0.15f) {
        float2 largeMV = largeSum / largeWeight;
        // A block with low contrast/texture (`ownSure`) goes by the textured blocks around it (msm_fg.h FillMain)
        ownMV = mix(largeMV, ownMV, saturate(ownSure * 2.2f));
        ownSure = max(ownSure, min(0.75f, largeWeight * 0.08f));
    }
    
    // Round 39 Bilateral Fluid Filter (EdgeMain lines 761-781):
    float spread = 0.0020f + 0.25f * length(ownMV);
    float2 fluidSum = float2(0.0f);
    float fluidWeight = 0.0f;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);
            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);
            float4 other = inVectors.read(uint2(cx, cy));
            float2 d = other.xy - ownMV;
            float spatialW = (abs(dx) == 2 || abs(dy) == 2) ? 0.5f : 1.0f;
            float confW = 0.25f + 0.75f * other.w;
            float w = exp(-dot(d, d) / (2.0f * spread * spread)) * confW * spatialW;
            fluidSum += w * other.xy;
            fluidWeight += w;
        }
    }
    float2 finalMV = (fluidWeight > 1e-5f) ? (fluidSum / fluidWeight) : ownMV;
    
    // 3. Compute Edge Disagreement (`most`, msm_fg.h line 782):
    // Measures how far this block's vector is from its 8 immediate neighbors so WarpMain knows where edges lie.
    float edgeSpread = 0.0f;
    for (int i = 0; i < 8; i++) {
        edgeSpread = max(edgeSpread, distance(around8[i], finalMV));
    }
    
    outVectors.write(float4(finalMV, ownSure, edgeSpread), gid);
}

// ============================================================================
// Fragment Shader: SMFG 1.1 True Midpoint Interpolator (S_{N-0.5} between Frame N-1 and Frame N)
// Note on Vector Signs:
//   effMV = uv_curr - uv_prev (displacement from Frame N-1 to Frame N).
//   At midpoint S_{N-0.5} (time t = 0.5 between Frame N-1 and Frame N):
//   - In Frame N (sourceTexture), the moving object is at:   uvCurr = uv + effMV * t
//   - In Frame N-1 (prevTexture), the moving object was at:  uvPrev = uv - effMV * t
// ============================================================================
fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],
                                 texture2d<float, access::sample> sourceTexture [[texture(MetalFGTextureIndexSource)]],
                                 texture2d<float, access::sample> motionVectors [[texture(MetalFGTextureIndexMotionVectors)]],
                                 texture2d<float, access::sample> prevTexture [[texture(MetalFGTextureIndexPrev)]],
                                 constant MetalFGWarpUniforms &uniforms [[buffer(MetalFGBufferIndexWarpUniforms)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    filter::linear,
                                    address::clamp_to_edge);
    
    float2 uv = in.texCoords;
    float2 texelSize = 1.0f / float2(sourceTexture.get_width(), sourceTexture.get_height());
    
    float4 currColor = sourceTexture.sample(linearSampler, uv);
    float4 prevColor = prevTexture.sample(linearSampler, uv);
    
    // Read smoothed motion vector & edge spread at destination pixel
    float4 mvData = motionVectors.sample(linearSampler, uv);
    float2 mv = mvData.xy;
    float edgeSpread = mvData.w;
    float t = uniforms.timeOffsetFactor;
    
    // Bidirectional silhouette guidance: check both Frame N (+mv*t) and Frame N-1 (-mv*t)
    // so moving foreground objects passing through the midpoint pixel carry their full motion vector.
    float2 mvFwd  = motionVectors.sample(linearSampler, clamp(uv + mv * t, float2(0.001f), float2(0.999f))).xy;
    float2 mvBack = motionVectors.sample(linearSampler, clamp(uv - mv * t, float2(0.001f), float2(0.999f))).xy;
    float2 effMV = mv;
    if (dot(mvFwd, mvFwd) > dot(effMV, effMV) * 1.15f) {
        effMV = mvFwd;
    }
    if (dot(mvBack, mvBack) > dot(effMV, effMV) * 1.15f) {
        effMV = mvBack;
    }
    
    float mvMag = length(effMV);
    if (mvMag < uniforms.motionDeadzone) {
        if (uniforms.debugTint > 0.5f) {
            currColor.b = min(1.0f, currColor.b * 1.25f + 0.10f);
        }
        return currColor;
    }
    
    // ========================================================================
    // 1. SMFG 1.1 MarkMain UI & HUD Protection:
    // A pixel is static UI/HUD only if:
    //   (a) Its color at `uv` stayed nearly identical between Frame N-1 and Frame N (`staticDiff` is tiny), AND
    //   (b) Warping it along `effMV` to `uv + testStep` / `uv - testStep` significantly changes its color (`Changed()`).
    // This keeps static text, damage numbers, crosshairs, and HUD icons 100% locked
    // without ever falsely freezing moving 3D walls, floors, or character edges!
    // ========================================================================
    float3 dStatic = abs(currColor.rgb - prevColor.rgb);
    float staticDiff = max(dStatic.r, max(dStatic.g, dStatic.b));
    
    if (staticDiff < uniforms.disocclusionThreshold * 0.14f) {
        float2 testStep = effMV * t;
        float3 wCurr = sourceTexture.sample(linearSampler, clamp(uv + testStep, float2(0.001f), float2(0.999f))).rgb;
        float3 wPrev = prevTexture.sample(linearSampler, clamp(uv - testStep, float2(0.001f), float2(0.999f))).rgb;
        float3 dWarpA = abs(wCurr - currColor.rgb);
        float3 dWarpB = abs(wPrev - currColor.rgb);
        float warpedDiff = max(max(dWarpA.r, max(dWarpA.g, dWarpA.b)),
                               max(dWarpB.r, max(dWarpB.g, dWarpB.b)));
        
        if (warpedDiff > staticDiff * 2.5f + 0.018f) {
            if (uniforms.debugTint > 0.5f) {
                currColor.r = min(1.0f, currColor.r * 1.25f + 0.10f);
            }
            return currColor;
        }
    }
    
    // ========================================================================
    // 2. SMFG 1.1 Sub-Block Edge Resolver (WarpMain lines 914-976):
    // Where adjacent motion blocks disagree (a foreground silhouette against background),
    // bilinearly mixing their motion vectors creates a false vector belonging to neither.
    // Pick the block vector under which sourceTexture(uv + candMV*t) and prevTexture(uv - candMV*t)
    // agree best at this pixel!
    // ========================================================================
    if (edgeSpread > 0.0012f) {
        float2 uvA = clamp(uv + effMV * t, float2(0.001f), float2(0.999f));
        float2 uvB = clamp(uv - effMV * t, float2(0.001f), float2(0.999f));
        float fitsMixed = rgb_luma_diff(sourceTexture.sample(linearSampler, uvA).rgb,
                                        prevTexture.sample(linearSampler, uvB).rgb);
        
        // Only resolve across the 4 surrounding block centers if the mixed vector doesn't already agree tightly
        if (fitsMixed > 0.025f) {
            constexpr sampler pointSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
            float2 gridDims = float2(motionVectors.get_width(), motionVectors.get_height());
            float2 invGrid = 1.0f / gridDims;
            float2 atGrid = uv * gridDims - 0.5f;
            float2 baseGrid = floor(atGrid);
            float2 part = atGrid - baseGrid;
            
            float bestFit = fitsMixed;
            for (int j = 0; j < 2; j++) {
                for (int i = 0; i < 2; i++) {
                    float2 blockCenterUV = (baseGrid + float2(i, j) + 0.5f) * invGrid;
                    float2 candMV = motionVectors.sample(pointSampler, blockCenterUV).xy;
                    float2 cUvA = clamp(uv + candMV * t, float2(0.001f), float2(0.999f));
                    float2 cUvB = clamp(uv - candMV * t, float2(0.001f), float2(0.999f));
                    float fit = rgb_luma_diff(sourceTexture.sample(linearSampler, cUvA).rgb,
                                              prevTexture.sample(linearSampler, cUvB).rgb);
                    // Slight preference for nearer block center (msm_fg.h nearer_word = 0.03)
                    float nearBias = 0.025f * (i ? part.x : (1.0f - part.x)) * (j ? part.y : (1.0f - part.y));
                    if (fit - nearBias < bestFit) {
                        bestFit = fit - nearBias;
                        effMV = candMV;
                    }
                }
            }
        }
    }
    
    // ========================================================================
    // 3. Round 53 Foreground / Head Silhouette Anti-Ghosting (msm_fg.h lines 848-869):
    // When a slow/stationary foreground object (e.g. player character/head) occludes a moving
    // background, one of the warped sample points (`uvCurr` or `uvPrev`) lands on the stationary
    // foreground object. Check the motion vector at both sample points and switch cleanly to the
    // unoccluded frame when one side hits a slower foreground object!
    // ========================================================================
    float2 uvCurr = clamp(uv + effMV * t, float2(0.001f), float2(0.999f));
    float2 uvPrev = clamp(uv - effMV * t, float2(0.001f), float2(0.999f));
    
    float sharePrev = 0.5f; // Default 50/50 midpoint synthesis
    float pace = length(effMV);
    if (pace > 0.0015f) {
        float2 mvAtCurr = motionVectors.sample(linearSampler, uvCurr).xy;
        float2 mvAtPrev = motionVectors.sample(linearSampler, uvPrev).xy;
        float reach = max(0.0018f, 0.30f * pace);
        
        bool wrongCurr = (distance(mvAtCurr, effMV) > reach) && (length(mvAtCurr) < 0.50f * pace);
        bool wrongPrev = (distance(mvAtPrev, effMV) > reach) && (length(mvAtPrev) < 0.50f * pace);
        
        if (wrongPrev && !wrongCurr) {
            sharePrev = 0.0f; // Prev frame is occluded by foreground; take 100% warped Curr frame
        } else if (wrongCurr && !wrongPrev) {
            sharePrev = 1.0f; // Curr frame is occluded by foreground; take 100% warped Prev frame
        }
    }
    
    // ========================================================================
    // 4. Round 56 Clamped Catmull-Rom Sharp Read & Anti-Double-Image Lean:
    // Preserves native texture crispness during sub-pixel warps and smoothly leans to a
    // single warped frame when sampleCurr and samplePrev diverge, eliminating ghosting and smearing.
    // ========================================================================
    float4 sampleCurr = sample_sharp_clamped(sourceTexture, uvCurr, texelSize);
    if (sharePrev <= 0.001f) {
        if (uniforms.debugTint > 0.5f) {
            sampleCurr.g = min(1.0f, sampleCurr.g * 1.35f + 0.15f);
        }
        return sampleCurr;
    }
    
    float4 samplePrev = sample_sharp_clamped(prevTexture, uvPrev, texelSize);
    if (sharePrev >= 0.999f) {
        if (uniforms.debugTint > 0.5f) {
            samplePrev.g = min(1.0f, samplePrev.g * 1.35f + 0.15f);
        }
        return samplePrev;
    }
    
    // Where both frames show the same, blend 50/50; where they diverge beyond disocclusionThreshold,
    // lean smoothly to sampleCurr (warped to midpoint) so there is never a double image or t=1.0 smear.
    float sampleDiff = rgb_luma_diff(sampleCurr.rgb, samplePrev.rgb);
    float confidence = smoothstep(uniforms.disocclusionThreshold * 1.35f,
                                  uniforms.disocclusionThreshold * 0.35f,
                                  sampleDiff);
    float4 finalColor = mix(sampleCurr, samplePrev, sharePrev * confidence);
    
    if (uniforms.debugTint > 0.5f) {
        finalColor.g = min(1.0f, finalColor.g * 1.35f + 0.15f); // Synthetic frame glow: emerald green
    }
    return finalColor;
}
