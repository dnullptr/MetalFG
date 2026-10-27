#import "../Headers/MetalFGWarper.h"
#import "../Headers/TouchTracker.h"
#import <os/lock.h>
#import <objc/runtime.h>
#import <atomic>

extern "C" const char kMetalFGIsSyntheticKey = '\0';

static const uint32_t kGridWidth = 80;
static const uint32_t kGridHeight = 45;

// Embedded fallback Metal Shading Language source (SMFG 1.1 Super-Motion Engine)
static NSString * const kEmbeddedMetalSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct MetalFGVertex {\n"
"    float2 position;\n"
"    float2 texCoords;\n"
"};\n"
"\n"
"struct MetalFGBMEUniforms {\n"
"    float2 touchVelocity;\n"
"    uint2 gridDimensions;\n"
"    float uiThreshold;\n"
"    float searchRadius;\n"
"    float maxDisplacement;\n"
"    float pad;\n"
"};\n"
"\n"
"struct MetalFGWarpUniforms {\n"
"    float timeOffsetFactor;\n"
"    float disocclusionThreshold;\n"
"    float motionDeadzone;\n"
"    float debugTint;\n"
"};\n"
"\n"
"struct RasterizerData {\n"
"    float4 position [[position]];\n"
"    float2 texCoords;\n"
"};\n"
"\n"
"constant float3 kLumaWeights = float3(0.299f, 0.587f, 0.114f);\n"
"\n"
"inline float rgb_to_luma(float3 c) {\n"
"    return dot(c, kLumaWeights);\n"
"}\n"
"\n"
"inline float rgb_luma_diff(float3 a, float3 b) {\n"
"    float3 d = abs(a - b);\n"
"    return dot(d, kLumaWeights) * 0.65f + max(d.r, max(d.g, d.b)) * 0.35f;\n"
"}\n"
"\n"
"inline float eval_candidate_patch(texture2d<float, access::sample> prevTexture,\n"
"                                  const thread float2 uvsCurr[9],\n"
"                                  const thread float3 rgbCurr[9],\n"
"                                  float2 candidate) {\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float error = 0.0f;\n"
"    for (int i = 0; i < 9; i++) {\n"
"        float3 rgbPrev = prevTexture.sample(s, uvsCurr[i] - candidate).rgb;\n"
"        error += min(rgb_luma_diff(rgbCurr[i], rgbPrev), 0.25f);\n"
"    }\n"
"    return error * (1.0f / 9.0f);\n"
"}\n"
"\n"
"inline float4 sample_sharp_clamped(texture2d<float, access::sample> tex,\n"
"                                   float2 uv,\n"
"                                   float2 texelSize) {\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float4 center = tex.sample(s, uv);\n"
"    float3 n0 = tex.sample(s, uv + float2(-texelSize.x, 0.0f)).rgb;\n"
"    float3 n1 = tex.sample(s, uv + float2( texelSize.x, 0.0f)).rgb;\n"
"    float3 n2 = tex.sample(s, uv + float2(0.0f, -texelSize.y)).rgb;\n"
"    float3 n3 = tex.sample(s, uv + float2(0.0f,  texelSize.y)).rgb;\n"
"    float3 minNeighbor = min(center.rgb, min(min(n0, n1), min(n2, n3)));\n"
"    float3 maxNeighbor = max(center.rgb, max(max(n0, n1), max(n2, n3)));\n"
"    float3 meanCross = (n0 + n1 + n2 + n3) * 0.25f;\n"
"    float3 sharpened = center.rgb + (center.rgb - meanCross) * 0.35f;\n"
"    return float4(clamp(sharpened, minNeighbor, maxNeighbor), center.a);\n"
"}\n"
"\n"
"vertex RasterizerData metalfg_vertex(uint vertexID [[vertex_id]],\n"
"                                     constant MetalFGVertex *vertices [[buffer(0)]]) {\n"
"    RasterizerData out;\n"
"    out.position = float4(vertices[vertexID].position, 0.0, 1.0);\n"
"    out.texCoords = vertices[vertexID].texCoords;\n"
"    return out;\n"
"}\n"
"\n"
"kernel void metalfg_block_motion_estimation(uint2 gid [[thread_position_in_grid]],\n"
"                                           texture2d<float, access::sample> prevTexture [[texture(0)]],\n"
"                                           texture2d<float, access::sample> currTexture [[texture(1)]],\n"
"                                           texture2d<float, access::write> motionVectors [[texture(2)]],\n"
"                                           constant MetalFGBMEUniforms &uniforms [[buffer(0)]]) {\n"
"    if (gid.x >= uniforms.gridDimensions.x || gid.y >= uniforms.gridDimensions.y) return;\n"
"    float2 centerUV = (float2(gid) + 0.5f) / float2(uniforms.gridDimensions);\n"
"    bool isHUDZone = (centerUV.y < 0.16f) || (centerUV.x < 0.32f && centerUV.y > 0.58f) || (centerUV.x > 0.68f && centerUV.y > 0.58f);\n"
"    const float dUV = 0.0022f;\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float2 uvsCurr[9];\n"
"    float3 rgbCurr[9];\n"
"    float3 patchMean = float3(0.0f);\n"
"    int idx = 0;\n"
"    for (int py = -1; py <= 1; py++) {\n"
"        for (int px = -1; px <= 1; px++) {\n"
"            uvsCurr[idx] = centerUV + float2(px, py) * dUV;\n"
"            rgbCurr[idx] = currTexture.sample(s, uvsCurr[idx]).rgb;\n"
"            patchMean += rgbCurr[idx];\n"
"            idx++;\n"
"        }\n"
"    }\n"
"    patchMean *= (1.0f / 9.0f);\n"
"    float patchContrast = 0.0f;\n"
"    for (int i = 0; i < 9; i++) {\n"
"        patchContrast += rgb_luma_diff(rgbCurr[i], patchMean);\n"
"    }\n"
"    patchContrast *= (1.0f / 9.0f);\n"
"    float errZero = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, float2(0.0f, 0.0f));\n"
"    float effectiveThreshold = isHUDZone ? (uniforms.uiThreshold * 1.1f) : (uniforms.uiThreshold * 0.15f);\n"
"    if (errZero < effectiveThreshold && (isHUDZone || patchContrast > 0.015f)) {\n"
"        float sureZero = saturate(patchContrast * 12.0f);\n"
"        motionVectors.write(float4(0.0f, 0.0f, errZero, sureZero), gid);\n"
"        return;\n"
"    }\n"
"    const float kMargin = 0.0018f;\n"
"    const float kDistPenalty = isHUDZone ? 0.45f : 0.08f;\n"
"    float bestError = errZero;\n"
"    float bestCost = errZero;\n"
"    float2 bestVector = float2(0.0f, 0.0f);\n"
"    float2 prior = uniforms.touchVelocity;\n"
"    const float r1 = 0.0012f;\n"
"    const float r2 = 0.0036f;\n"
"    const float r3 = 0.0085f;\n"
"    const float r4 = clamp(uniforms.searchRadius * 0.50f, 0.016f, uniforms.maxDisplacement);\n"
"    const float2 dirs[8] = {\n"
"        float2( 1.0f,  0.0f), float2(-1.0f,  0.0f),\n"
"        float2( 0.0f,  1.0f), float2( 0.0f, -1.0f),\n"
"        float2( 0.7071f,  0.7071f), float2(-0.7071f,  0.7071f),\n"
"        float2( 0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)\n"
"    };\n"
"    if (dot(prior, prior) > 1e-6f) {\n"
"        float errPrior = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, prior);\n"
"        float costPrior = errPrior + kMargin * 0.5f;\n"
"        if (costPrior < bestCost) { bestCost = costPrior; bestError = errPrior; bestVector = prior; }\n"
"    }\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = dirs[i] * r1;\n"
"        float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);\n"
"        float cost = err + kMargin + kDistPenalty * length(cand - prior);\n"
"        if (cost < bestCost) { bestCost = cost; bestError = err; bestVector = cand; }\n"
"    }\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = dirs[i] * r2;\n"
"        float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);\n"
"        float cost = err + kMargin + kDistPenalty * length(cand - prior);\n"
"        if (cost < bestCost) { bestCost = cost; bestError = err; bestVector = cand; }\n"
"    }\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = dirs[i] * r3;\n"
"        float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);\n"
"        float cost = err + kMargin + kDistPenalty * length(cand - prior);\n"
"        if (cost < bestCost) { bestCost = cost; bestError = err; bestVector = cand; }\n"
"    }\n"
"    float2 coarseBase = (dot(prior, prior) > 1e-6f) ? prior : bestVector;\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = coarseBase + dirs[i] * r4;\n"
"        float candLen = length(cand);\n"
"        if (candLen > uniforms.maxDisplacement) cand = (cand / candLen) * uniforms.maxDisplacement;\n"
"        float err = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, cand);\n"
"        float cost = err + kMargin + kDistPenalty * length(cand - prior);\n"
"        if (cost < bestCost) { bestCost = cost; bestError = err; bestVector = cand; }\n"
"    }\n"
"    if (dot(bestVector, bestVector) > 1e-8f && patchContrast > 0.008f) {\n"
"        const float stepUV = 0.0008f;\n"
"        float ex0 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(-stepUV, 0.0f));\n"
"        float ex1 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2( stepUV, 0.0f));\n"
"        float ey0 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(0.0f, -stepUV));\n"
"        float ey1 = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, bestVector + float2(0.0f,  stepUV));\n"
"        float bendX = ex0 - 2.0f * bestError + ex1;\n"
"        float bendY = ey0 - 2.0f * bestError + ey1;\n"
"        float2 part = float2(0.0f);\n"
"        if (bendX > 1e-4f) part.x = clamp(0.5f * (ex0 - ex1) / bendX, -0.5f, 0.5f) * stepUV;\n"
"        if (bendY > 1e-4f) part.y = clamp(0.5f * (ey0 - ey1) / bendY, -0.5f, 0.5f) * stepUV;\n"
"        float2 subpelCand = bestVector + part;\n"
"        float errSubpel = eval_candidate_patch(prevTexture, uvsCurr, rgbCurr, subpelCand);\n"
"        if (errSubpel <= bestError) { bestError = errSubpel; bestVector = subpelCand; }\n"
"    }\n"
"    if (bestError >= errZero - 0.0008f) {\n"
"        bestVector = float2(0.0f, 0.0f);\n"
"        bestError = errZero;\n"
"    }\n"
"    float finalLen = length(bestVector);\n"
"    if (finalLen > uniforms.maxDisplacement) bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;\n"
"    float sure = saturate(patchContrast * 10.0f) * saturate(1.0f - bestError / (0.045f + patchContrast));\n"
"    motionVectors.write(float4(bestVector, bestError, sure), gid);\n"
"}\n"
"\n"
"kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],\n"
"                                        texture2d<float, access::read> inVectors [[texture(0)]],\n"
"                                        texture2d<float, access::write> outVectors [[texture(1)]]) {\n"
"    uint width = inVectors.get_width();\n"
"    uint height = inVectors.get_height();\n"
"    if (gid.x >= width || gid.y >= height) return;\n"
"    float4 ownData = inVectors.read(gid);\n"
"    float2 ownMV = ownData.xy;\n"
"    float ownSure = ownData.w;\n"
"    float2 neighbors3x3[9];\n"
"    float2 around8[8];\n"
"    int idx9 = 0;\n"
"    int idx8 = 0;\n"
"    for (int dy = -1; dy <= 1; dy++) {\n"
"        for (int dx = -1; dx <= 1; dx++) {\n"
"            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);\n"
"            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);\n"
"            float2 v = inVectors.read(uint2(cx, cy)).xy;\n"
"            neighbors3x3[idx9++] = v;\n"
"            if (dx != 0 || dy != 0) around8[idx8++] = v;\n"
"        }\n"
"    }\n"
"    float minDistanceSum = 1e9f;\n"
"    int bestIndex = 4;\n"
"    for (int i = 0; i < 9; i++) {\n"
"        float distSum = 0.0f;\n"
"        for (int j = 0; j < 9; j++) distSum += distance(neighbors3x3[i], neighbors3x3[j]);\n"
"        if (distSum < minDistanceSum) { minDistanceSum = distSum; bestIndex = i; }\n"
"    }\n"
"    float2 medianMV = neighbors3x3[bestIndex];\n"
"    float nearThresh = 0.0015f + 0.18f * length(medianMV);\n"
"    int agreeCount = 0;\n"
"    for (int i = 0; i < 8; i++) {\n"
"        if (distance(around8[i], medianMV) <= nearThresh) agreeCount++;\n"
"    }\n"
"    if (agreeCount >= 6 && distance(ownMV, medianMV) > nearThresh) ownMV = medianMV;\n"
"    float2 largeSum = float2(0.0f);\n"
"    float largeWeight = 0.0f;\n"
"    for (int dy = -2; dy <= 2; dy++) {\n"
"        for (int dx = -2; dx <= 2; dx++) {\n"
"            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);\n"
"            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);\n"
"            float4 other = inVectors.read(uint2(cx, cy));\n"
"            float w = other.w * ((abs(dx) == 2 || abs(dy) == 2) ? 0.5f : 1.0f);\n"
"            largeSum += other.xy * w;\n"
"            largeWeight += w;\n"
"        }\n"
"    }\n"
"    if (largeWeight > 0.20f) {\n"
"        float2 largeMV = largeSum / largeWeight;\n"
"        ownMV = mix(largeMV, ownMV, saturate(ownSure * 2.5f));\n"
"        ownSure = max(ownSure, min(0.7f, largeWeight * 0.08f));\n"
"    }\n"
"    float spread = 0.0020f + 0.25f * length(ownMV);\n"
"    float2 fluidSum = float2(0.0f);\n"
"    float fluidWeight = 0.0f;\n"
"    for (int dy = -2; dy <= 2; dy++) {\n"
"        for (int dx = -2; dx <= 2; dx++) {\n"
"            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);\n"
"            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);\n"
"            float4 other = inVectors.read(uint2(cx, cy));\n"
"            float2 d = other.xy - ownMV;\n"
"            float spatialW = (abs(dx) == 2 || abs(dy) == 2) ? 0.5f : 1.0f;\n"
"            float confW = 0.25f + 0.75f * other.w;\n"
"            float w = exp(-dot(d, d) / (2.0f * spread * spread)) * confW * spatialW;\n"
"            fluidSum += w * other.xy;\n"
"            fluidWeight += w;\n"
"        }\n"
"    }\n"
"    float2 finalMV = (fluidWeight > 1e-5f) ? (fluidSum / fluidWeight) : ownMV;\n"
"    float edgeSpread = 0.0f;\n"
"    for (int i = 0; i < 8; i++) edgeSpread = max(edgeSpread, distance(around8[i], finalMV));\n"
"    outVectors.write(float4(finalMV, ownSure, edgeSpread), gid);\n"
"}\n"
"\n"
"fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],\n"
"                                 texture2d<float, access::sample> sourceTexture [[texture(0)]],\n"
"                                 texture2d<float, access::sample> motionVectors [[texture(1)]],\n"
"                                 texture2d<float, access::sample> prevTexture [[texture(2)]],\n"
"                                 constant MetalFGWarpUniforms &uniforms [[buffer(1)]]) {\n"
"    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float2 uv = in.texCoords;\n"
"    float2 texelSize = 1.0f / float2(sourceTexture.get_width(), sourceTexture.get_height());\n"
"    float4 currColor = sourceTexture.sample(linearSampler, uv);\n"
"    float4 prevColor = prevTexture.sample(linearSampler, uv);\n"
"    float4 mvData = motionVectors.sample(linearSampler, uv);\n"
"    float2 mv = mvData.xy;\n"
"    float edgeSpread = mvData.w;\n"
"    float2 mvBack = motionVectors.sample(linearSampler, clamp(uv - mv * uniforms.timeOffsetFactor, float2(0.001f), float2(0.999f))).xy;\n"
"    float2 effMV = (dot(mvBack, mvBack) > dot(mv, mv) * 1.15f) ? mvBack : mv;\n"
"    float mvMag = length(effMV);\n"
"    if (mvMag < uniforms.motionDeadzone) {\n"
"        if (uniforms.debugTint > 0.5f) { currColor.b = min(1.0f, currColor.b * 1.25f + 0.10f); }\n"
"        return currColor;\n"
"    }\n"
"    float3 dStatic = abs(currColor.rgb - prevColor.rgb);\n"
"    float staticDiff = max(dStatic.r, max(dStatic.g, dStatic.b));\n"
"    float lumaCurr = rgb_to_luma(currColor.rgb);\n"
"    float lumaPrev = rgb_to_luma(prevColor.rgb);\n"
"    float aroundCurr = rgb_to_luma(sourceTexture.sample(linearSampler, uv + float2(-texelSize.x, 0.0f)).rgb +\n"
"                                   sourceTexture.sample(linearSampler, uv + float2( texelSize.x, 0.0f)).rgb +\n"
"                                   sourceTexture.sample(linearSampler, uv + float2(0.0f, -texelSize.y)).rgb +\n"
"                                   sourceTexture.sample(linearSampler, uv + float2(0.0f,  texelSize.y)).rgb) * 0.25f;\n"
"    float aroundPrev = rgb_to_luma(prevTexture.sample(linearSampler, uv + float2(-texelSize.x, 0.0f)).rgb +\n"
"                                   prevTexture.sample(linearSampler, uv + float2( texelSize.x, 0.0f)).rgb +\n"
"                                   prevTexture.sample(linearSampler, uv + float2(0.0f, -texelSize.y)).rgb +\n"
"                                   prevTexture.sample(linearSampler, uv + float2(0.0f,  texelSize.y)).rgb) * 0.25f;\n"
"    float edgeCurr = lumaCurr - aroundCurr;\n"
"    float edgePrev = lumaPrev - aroundPrev;\n"
"    bool shapeStays = (abs(edgeCurr) > 0.06f && abs(edgePrev) > 0.06f &&\n"
"                       abs(edgeCurr - edgePrev) < 0.16f * max(abs(edgeCurr), abs(edgePrev)));\n"
"    if (staticDiff < uniforms.disocclusionThreshold * 0.18f || shapeStays) {\n"
"        float2 testStep = effMV * uniforms.timeOffsetFactor;\n"
"        float3 wCurr = sourceTexture.sample(linearSampler, clamp(uv - testStep, float2(0.001f), float2(0.999f))).rgb;\n"
"        float3 wPrev = prevTexture.sample(linearSampler, clamp(uv + testStep, float2(0.001f), float2(0.999f))).rgb;\n"
"        float3 dWarpA = abs(wCurr - currColor.rgb);\n"
"        float3 dWarpB = abs(wPrev - currColor.rgb);\n"
"        float warpedDiff = max(max(dWarpA.r, max(dWarpA.g, dWarpA.b)), max(dWarpB.r, max(dWarpB.g, dWarpB.b)));\n"
"        if (shapeStays || warpedDiff > staticDiff * 2.2f + 0.015f) {\n"
"            if (uniforms.debugTint > 0.5f) { currColor.r = min(1.0f, currColor.r * 1.25f + 0.10f); }\n"
"            return currColor;\n"
"        }\n"
"    }\n"
"    float t = uniforms.timeOffsetFactor;\n"
"    if (edgeSpread > 0.0012f) {\n"
"        float2 uvA = clamp(uv - effMV * t, float2(0.001f), float2(0.999f));\n"
"        float2 uvB = clamp(uv + effMV * t, float2(0.001f), float2(0.999f));\n"
"        float fitsMixed = rgb_luma_diff(sourceTexture.sample(linearSampler, uvA).rgb, prevTexture.sample(linearSampler, uvB).rgb);\n"
"        if (fitsMixed > 0.025f) {\n"
"            constexpr sampler pointSampler(coord::normalized, filter::nearest, address::clamp_to_edge);\n"
"            float2 gridDims = float2(motionVectors.get_width(), motionVectors.get_height());\n"
"            float2 invGrid = 1.0f / gridDims;\n"
"            float2 atGrid = uv * gridDims - 0.5f;\n"
"            float2 baseGrid = floor(atGrid);\n"
"            float2 part = atGrid - baseGrid;\n"
"            float bestFit = fitsMixed;\n"
"            for (int j = 0; j < 2; j++) {\n"
"                for (int i = 0; i < 2; i++) {\n"
"                    float2 blockCenterUV = (baseGrid + float2(i, j) + 0.5f) * invGrid;\n"
"                    float2 candMV = motionVectors.sample(pointSampler, blockCenterUV).xy;\n"
"                    float2 cUvA = clamp(uv - candMV * t, float2(0.001f), float2(0.999f));\n"
"                    float2 cUvB = clamp(uv + candMV * t, float2(0.001f), float2(0.999f));\n"
"                    float fit = rgb_luma_diff(sourceTexture.sample(linearSampler, cUvA).rgb, prevTexture.sample(linearSampler, cUvB).rgb);\n"
"                    float nearBias = 0.025f * (i ? part.x : (1.0f - part.x)) * (j ? part.y : (1.0f - part.y));\n"
"                    if (fit - nearBias < bestFit) { bestFit = fit - nearBias; effMV = candMV; }\n"
"                }\n"
"            }\n"
"        }\n"
"    }\n"
"    float2 uvCurr = clamp(uv - effMV * t, float2(0.001f), float2(0.999f));\n"
"    float2 uvPrev = clamp(uv + effMV * t, float2(0.001f), float2(0.999f));\n"
"    float sharePrev = 0.5f;\n"
"    float pace = length(effMV);\n"
"    if (pace > 0.0015f) {\n"
"        float2 mvAtCurr = motionVectors.sample(linearSampler, uvCurr).xy;\n"
"        float2 mvAtPrev = motionVectors.sample(linearSampler, uvPrev).xy;\n"
"        float reach = max(0.0018f, 0.30f * pace);\n"
"        bool wrongCurr = (distance(mvAtCurr, effMV) > reach) && (length(mvAtCurr) < 0.50f * pace);\n"
"        bool wrongPrev = (distance(mvAtPrev, effMV) > reach) && (length(mvAtPrev) < 0.50f * pace);\n"
"        if (wrongPrev && !wrongCurr) sharePrev = 0.0f;\n"
"        else if (wrongCurr && !wrongPrev) sharePrev = 1.0f;\n"
"    }\n"
"    float4 sampleCurr = sample_sharp_clamped(sourceTexture, uvCurr, texelSize);\n"
"    if (sharePrev <= 0.001f) {\n"
"        if (uniforms.debugTint > 0.5f) sampleCurr.g = min(1.0f, sampleCurr.g * 1.35f + 0.15f);\n"
"        return sampleCurr;\n"
"    }\n"
"    float4 samplePrev = sample_sharp_clamped(prevTexture, uvPrev, texelSize);\n"
"    if (sharePrev >= 0.999f) {\n"
"        if (uniforms.debugTint > 0.5f) samplePrev.g = min(1.0f, samplePrev.g * 1.35f + 0.15f);\n"
"        return samplePrev;\n"
"    }\n"
"    float sampleDiff = rgb_luma_diff(sampleCurr.rgb, samplePrev.rgb);\n"
"    float confidence = smoothstep(uniforms.disocclusionThreshold * 1.35f, uniforms.disocclusionThreshold * 0.35f, sampleDiff);\n"
"    float4 finalColor = mix(sampleCurr, samplePrev, sharePrev * confidence);\n"
"    if (uniforms.debugTint > 0.5f) {\n"
"        finalColor.g = min(1.0f, finalColor.g * 1.35f + 0.15f);\n"
"    }\n"
"    return finalColor;\n"
"}\n";

// Full-screen quad consisting of 2 triangles (6 vertices)
static const MetalFGVertex kQuadVertices[6] = {
    // Triangle 1
    { { -1.0f, -1.0f }, { 0.0f, 1.0f } }, // Bottom-Left
    { {  1.0f, -1.0f }, { 1.0f, 1.0f } }, // Bottom-Right
    { { -1.0f,  1.0f }, { 0.0f, 0.0f } }, // Top-Left
    
    // Triangle 2
    { { -1.0f,  1.0f }, { 0.0f, 0.0f } }, // Top-Left
    { {  1.0f, -1.0f }, { 1.0f, 1.0f } }, // Bottom-Right
    { {  1.0f,  1.0f }, { 1.0f, 0.0f } }, // Top-Right
};

@interface MetalFGWarper () {
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLComputePipelineState> _bmePipelineState;
    id<MTLComputePipelineState> _medianPipelineState;
    id<MTLBuffer> _vertexBuffer;
    
    // Double-buffered intermediate textures to prevent race conditions with swapchain recycling
    id<MTLTexture> _cachedTextures[2];
    id<MTLTexture> _motionVectorTexture;
    id<MTLTexture> _smoothedMotionVectorTexture;
    NSInteger _activeReadIndex;
    NSInteger _activeWriteIndex;
    BOOL _hasValidBaseFrame;
    os_unfair_lock _textureLock;
    
    std::atomic<int> _inFlightGpuFrames;
}

@property (nonatomic, readwrite) id<MTLDevice> device;
@property (nonatomic, readwrite) MTLPixelFormat pixelFormat;
@property (nonatomic, readwrite) BOOL isReady;

@end

@implementation MetalFGWarper

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (self) {
        _device = device;
        _pixelFormat = pixelFormat;
        _textureLock = OS_UNFAIR_LOCK_INIT;
        _activeReadIndex = 0;
        _activeWriteIndex = 1;
        _hasValidBaseFrame = NO;
        _inFlightGpuFrames = 0;
        _debugTintEnabled = NO;
        _motionScale = 0.45f;
        _disocclusionThreshold = 0.20f;
        _uiSensitivity = 0.035f;
        _motionDeadzone = 0.0004f;
        
        _commandQueue = [_device newCommandQueue];
        _commandQueue.label = @"com.metalfg.warperqueue";
        
        // Allocate vertex buffer
        _vertexBuffer = [_device newBufferWithBytes:kQuadVertices
                                             length:sizeof(kQuadVertices)
                                            options:MTLResourceStorageModeShared];
        _vertexBuffer.label = @"com.metalfg.quadvertices";
        
        // Build pipeline
        if (![self buildPipeline]) {
            NSLog(@"[MetalFG] Error: Failed to compile MetalFG render pipeline.");
            return nil;
        }
        
        _isReady = YES;
        NSLog(@"[MetalFG] MetalFGWarper initialized successfully for pixelFormat %lu.", (unsigned long)pixelFormat);
    }
    return self;
}

- (BOOL)buildPipeline {
    NSError *error = nil;
    id<MTLLibrary> library = nil;
    
    // 1. Try loading compiled metallib from rootless or rootful directories
    NSArray<NSString *> *searchPaths = @[
        @"/var/jb/Library/Application Support/MetalFG/default.metallib",
        @"/Library/Application Support/MetalFG/default.metallib"
    ];
    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSURL *url = [NSURL fileURLWithPath:path];
            library = [_device newLibraryWithURL:url error:&error];
            if (library) {
                NSLog(@"[MetalFG] Loaded precompiled shader library from %@", path);
                break;
            }
        }
    }
    
    // 2. Fallback to runtime compilation of embedded MSL source
    if (!library) {
        MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
        options.fastMathEnabled = YES;
        library = [_device newLibraryWithSource:kEmbeddedMetalSource
                                        options:options
                                          error:&error];
        if (!library) {
            NSLog(@"[MetalFG] Error compiling embedded Metal shader: %@", error.localizedDescription);
            return NO;
        }
        NSLog(@"[MetalFG] Successfully compiled embedded Metal shader at runtime.");
    }
    
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"metalfg_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"metalfg_fragment"];
    id<MTLFunction> bmeFunc = [library newFunctionWithName:@"metalfg_block_motion_estimation"];
    id<MTLFunction> medianFunc = [library newFunctionWithName:@"metalfg_motion_median_filter"];
    
    if (!vertexFunc || !fragmentFunc) {
        NSLog(@"[MetalFG] Error: Shader entry points not found in library.");
        return NO;
    }
    
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.label = @"com.metalfg.warpPipeline";
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.colorAttachments[0].pixelFormat = _pixelFormat;
    pipeDesc.colorAttachments[0].blendingEnabled = NO;
    
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
    if (!_pipelineState) {
        NSLog(@"[MetalFG] Error creating render pipeline state: %@", error.localizedDescription);
        return NO;
    }
    
    if (bmeFunc) {
        _bmePipelineState = [_device newComputePipelineStateWithFunction:bmeFunc error:&error];
        if (_bmePipelineState) {
            NSLog(@"[MetalFG] Block Motion Estimation compute pipeline created successfully.");
        }
    }
    
    if (medianFunc) {
        _medianPipelineState = [_device newComputePipelineStateWithFunction:medianFunc error:&error];
        if (_medianPipelineState) {
            NSLog(@"[MetalFG] Motion Median Filter compute pipeline created successfully.");
        }
    }
    
    return YES;
}

- (void)ensureTextureStorageForSource:(id<MTLTexture>)sourceTexture {
    os_unfair_lock_lock(&_textureLock);
    
    BOOL needsRealloc = NO;
    for (int i = 0; i < 2; i++) {
        if (!_cachedTextures[i] ||
            _cachedTextures[i].width != sourceTexture.width ||
            _cachedTextures[i].height != sourceTexture.height ||
            _cachedTextures[i].pixelFormat != sourceTexture.pixelFormat) {
            needsRealloc = YES;
            break;
        }
    }
    
    if (needsRealloc) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:sourceTexture.pixelFormat
                                                                                         width:sourceTexture.width
                                                                                        height:sourceTexture.height
                                                                                     mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModePrivate;
        
        for (int i = 0; i < 2; i++) {
            _cachedTextures[i] = [_device newTextureWithDescriptor:desc];
            _cachedTextures[i].label = [NSString stringWithFormat:@"com.metalfg.cacheTexture.%d", i];
        }
        _hasValidBaseFrame = NO;
        _activeReadIndex = 0;
        _activeWriteIndex = 1;
        NSLog(@"[MetalFG] Reallocated texture cache: %lux%lu, format: %lu",
              (unsigned long)sourceTexture.width, (unsigned long)sourceTexture.height, (unsigned long)sourceTexture.pixelFormat);
    }
    
    // Allocate SMFG 4-channel motion vector grid textures (80x45, RGBA16Float: ~28 KB each)
    // Stores float4(vx, vy, error/sure, sure/edgeSpread)
    if (!_motionVectorTexture) {
        MTLTextureDescriptor *mvDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                          width:kGridWidth
                                                                                         height:kGridHeight
                                                                                      mipmapped:NO];
        mvDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        mvDesc.storageMode = MTLStorageModePrivate;
        _motionVectorTexture = [_device newTextureWithDescriptor:mvDesc];
        _motionVectorTexture.label = @"com.metalfg.rawMotionVectors";
        
        _smoothedMotionVectorTexture = [_device newTextureWithDescriptor:mvDesc];
        _smoothedMotionVectorTexture.label = @"com.metalfg.smoothedMotionVectors";
        NSLog(@"[MetalFG] Allocated SMFG RGBA16Float motion vector grids: %ux%u", kGridWidth, kGridHeight);
    }
    
    os_unfair_lock_unlock(&_textureLock);
}

- (void)captureBaseTexture:(id<MTLTexture>)sourceTexture
             withTimestamp:(CFTimeInterval)timestamp
             touchVelocity:(simd_float2)touchVelocity {
    if (!sourceTexture || sourceTexture.width < 250 || sourceTexture.height < 150) return;
    
    [self ensureTextureStorageForSource:sourceTexture];
    
    os_unfair_lock_lock(&_textureLock);
    NSInteger writeIdx = _activeWriteIndex;
    NSInteger readIdx = _activeReadIndex;
    id<MTLTexture> destTexture = _cachedTextures[writeIdx];
    id<MTLTexture> prevTexture = _cachedTextures[readIdx];
    BOOL hasPrevFrame = _hasValidBaseFrame;
    id<MTLTexture> rawMVTexture = _motionVectorTexture;
    id<MTLTexture> smoothMVTexture = _smoothedMotionVectorTexture;
    id<MTLComputePipelineState> bmePipeline = _bmePipelineState;
    id<MTLComputePipelineState> medianPipeline = _medianPipelineState;
    os_unfair_lock_unlock(&_textureLock);
    
    if (!destTexture) return;
    
    id<MTLCommandBuffer> cmdBuffer = [_commandQueue commandBuffer];
    cmdBuffer.label = @"com.metalfg.captureAndBME";
    
    // Pass 1: Copy native frame into double-buffered cache
    id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
    [blit copyFromTexture:sourceTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(sourceTexture.width, sourceTexture.height, 1)
                toTexture:destTexture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    
    // Pass 2: Block Motion Estimation with Static UI Prior
    if (hasPrevFrame && prevTexture && bmePipeline && rawMVTexture) {
        id<MTLComputeCommandEncoder> comp = [cmdBuffer computeCommandEncoder];
        comp.label = @"com.metalfg.bmePass";
        [comp setComputePipelineState:bmePipeline];
        [comp setTexture:prevTexture atIndex:MetalFGBMETexturePrev];
        [comp setTexture:destTexture atIndex:MetalFGBMETextureCurr];
        [comp setTexture:rawMVTexture atIndex:MetalFGBMETextureMotionVectors];
        
        MetalFGBMEUniforms bmeUniforms;
        bmeUniforms.touchVelocity = touchVelocity;
        bmeUniforms.gridDimensions = simd_make_uint2(kGridWidth, kGridHeight);
        bmeUniforms.uiThreshold = self.uiSensitivity;
        bmeUniforms.searchRadius = 0.040f;
        bmeUniforms.maxDisplacement = 0.035f; // Cap displacement to prevent tearing
        bmeUniforms.pad = 0.0f;
        
        [comp setBytes:&bmeUniforms length:sizeof(bmeUniforms) atIndex:MetalFGBufferIndexBMEUniforms];
        
        MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
        MTLSize threadgroups = MTLSizeMake((kGridWidth + 15) / 16, (kGridHeight + 15) / 16, 1);
        [comp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
        [comp endEncoding];
        
        // Pass 3: 3x3 Spatial Median Smoothing (kills boiling shimmer)
        if (medianPipeline && smoothMVTexture) {
            id<MTLComputeCommandEncoder> medComp = [cmdBuffer computeCommandEncoder];
            medComp.label = @"com.metalfg.medianSmoothPass";
            [medComp setComputePipelineState:medianPipeline];
            [medComp setTexture:rawMVTexture atIndex:MetalFGSmoothTextureInput];
            [medComp setTexture:smoothMVTexture atIndex:MetalFGSmoothTextureOutput];
            [medComp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
            [medComp endEncoding];
        }
    }
    
    __weak MetalFGWarper *weakSelf = self;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        MetalFGWarper *strongSelf = weakSelf;
        if (!strongSelf) return;
        
        os_unfair_lock_lock(&strongSelf->_textureLock);
        strongSelf->_activeReadIndex = writeIdx;
        strongSelf->_activeWriteIndex = (writeIdx == 0 ? 1 : 0);
        strongSelf->_hasValidBaseFrame = YES;
        os_unfair_lock_unlock(&strongSelf->_textureLock);
    }];
    
    [cmdBuffer commit];
}

- (BOOL)renderSyntheticFrameToDrawable:(id<CAMetalDrawable>)targetDrawable
                        targetTimeHint:(CFTimeInterval)targetTimeHint {
    if (!targetDrawable || !_isReady) return NO;
    
    os_unfair_lock_lock(&_textureLock);
    if (!_hasValidBaseFrame) {
        os_unfair_lock_unlock(&_textureLock);
        return NO;
    }
    id<MTLTexture> sourceTex = _cachedTextures[_activeReadIndex];
    NSInteger prevIdx = (_activeReadIndex == 0 ? 1 : 0);
    id<MTLTexture> prevTex = _cachedTextures[prevIdx] ? _cachedTextures[prevIdx] : sourceTex;
    id<MTLTexture> mvTex = _smoothedMotionVectorTexture ? _smoothedMotionVectorTexture : _motionVectorTexture;
    os_unfair_lock_unlock(&_textureLock);
    
    if (!sourceTex) return NO;
    
    // Backpressure fail-safe: drop synthetic frame if GPU is backed up
    if (_inFlightGpuFrames.load() >= 2) {
        return NO;
    }
    
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = targetDrawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLCommandBuffer> cmdBuffer = [_commandQueue commandBuffer];
    cmdBuffer.label = @"com.metalfg.syntheticWarpPass";
    
    id<MTLRenderCommandEncoder> enc = [cmdBuffer renderCommandEncoderWithDescriptor:passDesc];
    [enc setRenderPipelineState:_pipelineState];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:MetalFGBufferIndexVertices];
    [enc setFragmentTexture:sourceTex atIndex:MetalFGTextureIndexSource];
    
    if (mvTex) {
        [enc setFragmentTexture:mvTex atIndex:MetalFGTextureIndexMotionVectors];
    }
    if (prevTex) {
        [enc setFragmentTexture:prevTex atIndex:MetalFGTextureIndexPrev];
    }
    
    MetalFGWarpUniforms warpUniforms;
    warpUniforms.timeOffsetFactor = self.motionScale;
    warpUniforms.disocclusionThreshold = self.disocclusionThreshold;
    warpUniforms.motionDeadzone = self.motionDeadzone;
    warpUniforms.debugTint = self.debugTintEnabled ? 1.0f : 0.0f;
    [enc setFragmentBytes:&warpUniforms length:sizeof(warpUniforms) atIndex:MetalFGBufferIndexWarpUniforms];
    
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    
    // Tag synthetic drawable to prevent recursive presentation hooking
    objc_setAssociatedObject(targetDrawable, &kMetalFGIsSyntheticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Present synthetic drawable directly for the 120Hz VSYNC tick without presentation queue locking
    [cmdBuffer presentDrawable:targetDrawable];
    
    _inFlightGpuFrames.fetch_add(1);
    __weak MetalFGWarper *weakSelf = self;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        MetalFGWarper *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_inFlightGpuFrames.fetch_sub(1);
        }
    }];
    
    [cmdBuffer commit];
    return YES;
}

- (BOOL)isGpuBusy {
    return _inFlightGpuFrames.load() >= 2;
}

- (BOOL)synthesizeAndPresentWithSourceTexture:(id<MTLTexture>)sourceTexture
                                        layer:(CAMetalLayer *)layer
                                touchVelocity:(simd_float2)touchVelocity {
    if (!sourceTexture || !layer || !_isReady) return NO;
    if (sourceTexture.width < 250 || sourceTexture.height < 150) return NO;
    
    [self ensureTextureStorageForSource:sourceTexture];
    
    os_unfair_lock_lock(&_textureLock);
    NSInteger writeIdx = _activeWriteIndex;
    NSInteger readIdx = _activeReadIndex;
    id<MTLTexture> destTexture = _cachedTextures[writeIdx];
    id<MTLTexture> prevTexture = _cachedTextures[readIdx];
    BOOL hasPrevFrame = _hasValidBaseFrame;
    id<MTLTexture> rawMVTexture = _motionVectorTexture;
    id<MTLTexture> smoothMVTexture = _smoothedMotionVectorTexture;
    id<MTLComputePipelineState> bmePipeline = _bmePipelineState;
    id<MTLComputePipelineState> medianPipeline = _medianPipelineState;
    id<MTLRenderPipelineState> warpPipeline = _pipelineState;
    id<MTLBuffer> vertexBuffer = _vertexBuffer;
    os_unfair_lock_unlock(&_textureLock);
    
    if (!destTexture) return NO;
    
    // 1. If we don't have a valid previous frame yet, blit this frame into cache and return
    if (!hasPrevFrame || !prevTexture || !bmePipeline || !rawMVTexture || !warpPipeline) {
        id<MTLCommandBuffer> blitCmd = [_commandQueue commandBuffer];
        blitCmd.label = @"com.metalfg.initialBlit";
        id<MTLBlitCommandEncoder> blit = [blitCmd blitCommandEncoder];
        [blit copyFromTexture:sourceTexture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(sourceTexture.width, sourceTexture.height, 1)
                    toTexture:destTexture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        
        __weak MetalFGWarper *weakSelf = self;
        [blitCmd addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            MetalFGWarper *strongSelf = weakSelf;
            if (!strongSelf) return;
            os_unfair_lock_lock(&strongSelf->_textureLock);
            strongSelf->_activeReadIndex = writeIdx;
            strongSelf->_activeWriteIndex = (writeIdx == 0 ? 1 : 0);
            strongSelf->_hasValidBaseFrame = YES;
            os_unfair_lock_unlock(&strongSelf->_textureLock);
        }];
        [blitCmd commit];
        return NO;
    }
    
    // 2. Backpressure guard: drop frame if GPU has >= 2 synthetic frames in flight
    if (_inFlightGpuFrames.load() >= 2) {
        return NO;
    }
    
    // 3. Acquire synthetic drawable from the swapchain
    id<CAMetalDrawable> syntheticDrawable = [layer nextDrawable];
    if (!syntheticDrawable || !syntheticDrawable.texture) {
        return NO;
    }
    
    // 4. Encode unified GPU command buffer: Blit -> BME -> Median -> Warp -> Present
    id<MTLCommandBuffer> cmdBuffer = [_commandQueue commandBuffer];
    cmdBuffer.label = @"com.metalfg.unifiedPipeline";
    
    // Pass A: Copy sourceTexture into destTexture
    id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
    [blit copyFromTexture:sourceTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(sourceTexture.width, sourceTexture.height, 1)
                toTexture:destTexture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    
    // Pass B: Hierarchical Multi-Scale BME Pass
    id<MTLComputeCommandEncoder> comp = [cmdBuffer computeCommandEncoder];
    comp.label = @"com.metalfg.bmePass";
    [comp setComputePipelineState:bmePipeline];
    [comp setTexture:prevTexture atIndex:MetalFGBMETexturePrev];
    [comp setTexture:destTexture atIndex:MetalFGBMETextureCurr];
    [comp setTexture:rawMVTexture atIndex:MetalFGBMETextureMotionVectors];
    
    MetalFGBMEUniforms bmeUniforms;
    bmeUniforms.touchVelocity = touchVelocity;
    bmeUniforms.gridDimensions = simd_make_uint2(kGridWidth, kGridHeight);
    bmeUniforms.uiThreshold = self.uiSensitivity;
    bmeUniforms.searchRadius = 0.040f;
    bmeUniforms.maxDisplacement = 0.035f;
    bmeUniforms.pad = 0.0f;
    [comp setBytes:&bmeUniforms length:sizeof(bmeUniforms) atIndex:MetalFGBufferIndexBMEUniforms];
    
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroups = MTLSizeMake((kGridWidth + 15) / 16, (kGridHeight + 15) / 16, 1);
    [comp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
    [comp endEncoding];
    
    // Pass C: 3x3 Spatial Median Filter Pass
    id<MTLTexture> mvToUse = rawMVTexture;
    if (medianPipeline && smoothMVTexture) {
        id<MTLComputeCommandEncoder> medComp = [cmdBuffer computeCommandEncoder];
        medComp.label = @"com.metalfg.medianSmoothPass";
        [medComp setComputePipelineState:medianPipeline];
        [medComp setTexture:rawMVTexture atIndex:MetalFGSmoothTextureInput];
        [medComp setTexture:smoothMVTexture atIndex:MetalFGSmoothTextureOutput];
        [medComp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
        [medComp endEncoding];
        mvToUse = smoothMVTexture;
    }
    
    // Pass D: Warp Render Pass into syntheticDrawable
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = syntheticDrawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLRenderCommandEncoder> enc = [cmdBuffer renderCommandEncoderWithDescriptor:passDesc];
    [enc setRenderPipelineState:warpPipeline];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:MetalFGBufferIndexVertices];
    [enc setFragmentTexture:destTexture atIndex:MetalFGTextureIndexSource];
    [enc setFragmentTexture:mvToUse atIndex:MetalFGTextureIndexMotionVectors];
    [enc setFragmentTexture:prevTexture atIndex:MetalFGTextureIndexPrev];
    
    MetalFGWarpUniforms warpUniforms;
    warpUniforms.timeOffsetFactor = self.motionScale;
    warpUniforms.disocclusionThreshold = self.disocclusionThreshold;
    warpUniforms.motionDeadzone = self.motionDeadzone;
    warpUniforms.debugTint = self.debugTintEnabled ? 1.0f : 0.0f;
    [enc setFragmentBytes:&warpUniforms length:sizeof(warpUniforms) atIndex:MetalFGBufferIndexWarpUniforms];
    
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    
    // Tag synthetic drawable to prevent recursive presentation hooking
    objc_setAssociatedObject(syntheticDrawable, &kMetalFGIsSyntheticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Pass E: Present with symmetric 8.33ms minimum duration (120Hz VSYNC pace)
    [cmdBuffer presentDrawable:syntheticDrawable afterMinimumDuration: 1.0 / 120.0];
    
    _inFlightGpuFrames.fetch_add(1);
    __weak MetalFGWarper *weakSelf = self;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        MetalFGWarper *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_inFlightGpuFrames.fetch_sub(1);
            os_unfair_lock_lock(&strongSelf->_textureLock);
            strongSelf->_activeReadIndex = writeIdx;
            strongSelf->_activeWriteIndex = (writeIdx == 0 ? 1 : 0);
            strongSelf->_hasValidBaseFrame = YES;
            os_unfair_lock_unlock(&strongSelf->_textureLock);
        }
    }];
    
    [cmdBuffer commit];
    return YES;
}

- (BOOL)processAndInterpolateNativeDrawable:(id<CAMetalDrawable>)drawable {
    if (!drawable || !_isReady) return NO;
    id<MTLTexture> sourceTexture = drawable.texture;
    if (!sourceTexture || sourceTexture.width < 250 || sourceTexture.height < 150) return NO;
    
    [self ensureTextureStorageForSource:sourceTexture];
    
    os_unfair_lock_lock(&_textureLock);
    NSInteger writeIdx = _activeWriteIndex;
    NSInteger readIdx = _activeReadIndex;
    id<MTLTexture> destTexture = _cachedTextures[writeIdx];
    id<MTLTexture> prevTexture = _cachedTextures[readIdx];
    BOOL hasPrevFrame = _hasValidBaseFrame;
    id<MTLTexture> rawMVTexture = _motionVectorTexture;
    id<MTLTexture> smoothMVTexture = _smoothedMotionVectorTexture;
    id<MTLComputePipelineState> bmePipeline = _bmePipelineState;
    id<MTLComputePipelineState> medianPipeline = _medianPipelineState;
    id<MTLRenderPipelineState> warpPipeline = _pipelineState;
    id<MTLBuffer> vertexBuffer = _vertexBuffer;
    os_unfair_lock_unlock(&_textureLock);
    
    if (!destTexture) return NO;
    
    id<MTLCommandBuffer> cmdBuffer = [_commandQueue commandBuffer];
    cmdBuffer.label = @"com.metalfg.processAndInterpolate";
    
    // Pass 1: Copy native frame into double-buffered cache (saving Frame N)
    id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
    [blit copyFromTexture:sourceTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(sourceTexture.width, sourceTexture.height, 1)
                toTexture:destTexture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    
    BOOL didInterpolate = NO;
    
    if (hasPrevFrame && prevTexture && bmePipeline && rawMVTexture && warpPipeline) {
        // Pass 2: Block Motion Estimation between Frame N-1 and Frame N
        id<MTLComputeCommandEncoder> comp = [cmdBuffer computeCommandEncoder];
        comp.label = @"com.metalfg.bmePass";
        [comp setComputePipelineState:bmePipeline];
        [comp setTexture:prevTexture atIndex:MetalFGBMETexturePrev];
        [comp setTexture:destTexture atIndex:MetalFGBMETextureCurr];
        [comp setTexture:rawMVTexture atIndex:MetalFGBMETextureMotionVectors];
        
        simd_float2 touchVel = [[MetalFGTouchTracker sharedTracker] normalizedVelocityForScreenSize:CGSizeMake(sourceTexture.width, sourceTexture.height)];
        MetalFGBMEUniforms bmeUniforms;
        bmeUniforms.touchVelocity = touchVel;
        bmeUniforms.gridDimensions = simd_make_uint2(kGridWidth, kGridHeight);
        bmeUniforms.uiThreshold = self.uiSensitivity;
        bmeUniforms.searchRadius = 0.040f;
        bmeUniforms.maxDisplacement = 0.035f;
        bmeUniforms.pad = 0.0f;
        [comp setBytes:&bmeUniforms length:sizeof(bmeUniforms) atIndex:MetalFGBufferIndexBMEUniforms];
        
        MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
        MTLSize threadgroups = MTLSizeMake((kGridWidth + 15) / 16, (kGridHeight + 15) / 16, 1);
        [comp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
        [comp endEncoding];
        
        id<MTLTexture> mvToUse = rawMVTexture;
        if (medianPipeline && smoothMVTexture) {
            id<MTLComputeCommandEncoder> medComp = [cmdBuffer computeCommandEncoder];
            medComp.label = @"com.metalfg.medianSmoothPass";
            [medComp setComputePipelineState:medianPipeline];
            [medComp setTexture:rawMVTexture atIndex:MetalFGSmoothTextureInput];
            [medComp setTexture:smoothMVTexture atIndex:MetalFGSmoothTextureOutput];
            [medComp dispatchThreadgroups:threadgroups threadsPerThreadgroup:threadsPerGroup];
            [medComp endEncoding];
            mvToUse = smoothMVTexture;
        }
        
        // Pass 3: Bidirectional Interpolation Render Pass into drawable
        MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = drawable.texture;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        
        id<MTLRenderCommandEncoder> enc = [cmdBuffer renderCommandEncoderWithDescriptor:passDesc];
        [enc setRenderPipelineState:warpPipeline];
        [enc setVertexBuffer:vertexBuffer offset:0 atIndex:MetalFGBufferIndexVertices];
        [enc setFragmentTexture:destTexture atIndex:MetalFGTextureIndexSource]; // Frame N
        [enc setFragmentTexture:mvToUse atIndex:MetalFGTextureIndexMotionVectors];
        [enc setFragmentTexture:prevTexture atIndex:MetalFGTextureIndexPrev];   // Frame N-1
        
        MetalFGWarpUniforms warpUniforms;
        warpUniforms.timeOffsetFactor = self.motionScale;
        warpUniforms.disocclusionThreshold = self.disocclusionThreshold;
        warpUniforms.motionDeadzone = self.motionDeadzone;
        warpUniforms.debugTint = self.debugTintEnabled ? 1.0f : 0.0f;
        [enc setFragmentBytes:&warpUniforms length:sizeof(warpUniforms) atIndex:MetalFGBufferIndexWarpUniforms];
        
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [enc endEncoding];
        
        didInterpolate = YES;
    }
    
    // Tag drawable to prevent recursive presentation hooking
    objc_setAssociatedObject(drawable, &kMetalFGIsSyntheticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Present drawable directly (displays S_{N-0.5} if interpolated, or F_0 if first frame)
    [cmdBuffer presentDrawable:drawable];
    
    _inFlightGpuFrames.fetch_add(1);
    
    // Update activeReadIndex to point to the newly cached Frame N
    os_unfair_lock_lock(&_textureLock);
    _activeReadIndex = writeIdx;
    _activeWriteIndex = (writeIdx == 0 ? 1 : 0);
    _hasValidBaseFrame = YES;
    os_unfair_lock_unlock(&_textureLock);
    
    __weak MetalFGWarper *weakSelf = self;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        MetalFGWarper *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_inFlightGpuFrames.fetch_sub(1);
        }
    }];
    
    [cmdBuffer commit];
    return didInterpolate;
}

- (BOOL)presentCachedNativeFrameToDrawable:(id<CAMetalDrawable>)targetDrawable {
    if (!targetDrawable || !_isReady) return NO;
    
    os_unfair_lock_lock(&_textureLock);
    if (!_hasValidBaseFrame) {
        os_unfair_lock_unlock(&_textureLock);
        return NO;
    }
    id<MTLTexture> nativeTex = _cachedTextures[_activeReadIndex];
    os_unfair_lock_unlock(&_textureLock);
    
    if (!nativeTex) return NO;
    
    id<MTLCommandBuffer> cmdBuffer = [_commandQueue commandBuffer];
    cmdBuffer.label = @"com.metalfg.presentCachedNative";
    
    id<MTLBlitCommandEncoder> blit = [cmdBuffer blitCommandEncoder];
    [blit copyFromTexture:nativeTex
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(nativeTex.width, nativeTex.height, 1)
                toTexture:targetDrawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    
    objc_setAssociatedObject(targetDrawable, &kMetalFGIsSyntheticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cmdBuffer presentDrawable:targetDrawable];
    
    _inFlightGpuFrames.fetch_add(1);
    __weak MetalFGWarper *weakSelf = self;
    [cmdBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        MetalFGWarper *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_inFlightGpuFrames.fetch_sub(1);
        }
    }];
    
    [cmdBuffer commit];
    return YES;
}

@end
