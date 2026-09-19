#import "../Headers/MetalFGWarper.h"
#import "../Headers/TouchTracker.h"
#import <os/lock.h>
#import <objc/runtime.h>
#import <atomic>

extern "C" const char kMetalFGIsSyntheticKey = '\0';

static const uint32_t kGridWidth = 80;
static const uint32_t kGridHeight = 45;

// Embedded fallback Metal Shading Language source
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
"inline float rgb_to_luma(float4 c) {\n"
"    return dot(c.rgb, float3(0.299f, 0.587f, 0.114f));\n"
"}\n"
"\n"
"inline float eval_candidate_luma(texture2d<float, access::sample> prevTexture,\n"
"                                const thread float2 uvsCurr[9],\n"
"                                const thread float lCurr[9],\n"
"                                float2 candidate) {\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float error = 0.0f;\n"
"    for (int i = 0; i < 9; i++) {\n"
"        float lPrev = rgb_to_luma(prevTexture.sample(s, uvsCurr[i] - candidate));\n"
"        error += abs(lCurr[i] - lPrev);\n"
"    }\n"
"    return error * (1.0f / 9.0f);\n"
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
"    bool isHUDZone = (centerUV.y < 0.18f) || (centerUV.x < 0.35f && centerUV.y > 0.55f) || (centerUV.x > 0.65f && centerUV.y > 0.55f);\n"
"    const float dUV = 0.002f;\n"
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float2 uvsCurr[9];\n"
"    float lCurr[9];\n"
"    int idx = 0;\n"
"    for (int py = -1; py <= 1; py++) {\n"
"        for (int px = -1; px <= 1; px++) {\n"
"            uvsCurr[idx] = centerUV + float2(px, py) * dUV;\n"
"            lCurr[idx] = rgb_to_luma(currTexture.sample(s, uvsCurr[idx]));\n"
"            idx++;\n"
"        }\n"
"    }\n"
"    float errZero = eval_candidate_luma(prevTexture, uvsCurr, lCurr, float2(0.0f, 0.0f));\n"
"    float effectiveThreshold = isHUDZone ? (uniforms.uiThreshold * 1.5f) : (uniforms.uiThreshold * 0.25f);\n"
"    if (errZero < effectiveThreshold) {\n"
"        motionVectors.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);\n"
"        return;\n"
"    }\n"
"    float bestError = errZero;\n"
"    float2 bestVector = float2(0.0f, 0.0f);\n"
"    float2 prior = uniforms.touchVelocity;\n"
"    const float r1 = 0.0012f;\n"
"    const float r2 = 0.0035f;\n"
"    const float r3 = 0.0080f;\n"
"    const float r4 = clamp(uniforms.searchRadius * 0.50f, 0.015f, uniforms.maxDisplacement);\n"
"    const float2 dirs[8] = {\n"
"        float2( 1.0f,  0.0f), float2(-1.0f,  0.0f),\n"
"        float2( 0.0f,  1.0f), float2( 0.0f, -1.0f),\n"
"        float2( 0.7071f,  0.7071f), float2(-0.7071f,  0.7071f),\n"
"        float2( 0.7071f, -0.7071f), float2(-0.7071f, -0.7071f)\n"
"    };\n"
"    if (dot(prior, prior) > 1e-6f) {\n"
"        float errPrior = eval_candidate_luma(prevTexture, uvsCurr, lCurr, prior);\n"
"        if (errPrior < bestError) { bestError = errPrior; bestVector = prior; }\n"
"    }\n"
"    // Ring 1 (Micro: 4 cardinal)\n"
"    for (int i = 0; i < 4; i++) {\n"
"        float2 cand = dirs[i] * r1;\n"
"        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);\n"
"        if (isHUDZone) err += 0.04f;\n"
"        if (err < bestError) { bestError = err; bestVector = cand; }\n"
"    }\n"
"    // Ring 2 (Sub-Medium: 8 directions)\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = dirs[i] * r2;\n"
"        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);\n"
"        if (isHUDZone) err += 0.04f;\n"
"        if (err < bestError) { bestError = err; bestVector = cand; }\n"
"    }\n"
"    // Ring 3 (Medium: 8 directions)\n"
"    for (int i = 0; i < 8; i++) {\n"
"        float2 cand = dirs[i] * r3;\n"
"        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);\n"
"        if (isHUDZone) err += 0.04f;\n"
"        if (err < bestError) { bestError = err; bestVector = cand; }\n"
"    }\n"
"    // Ring 4 (Coarse: 4 cardinal)\n"
"    float2 coarseBase = (dot(prior, prior) > 1e-6f) ? prior : float2(0.0f, 0.0f);\n"
"    for (int i = 0; i < 4; i++) {\n"
"        float2 cand = coarseBase + dirs[i] * r4;\n"
"        float candLen = length(cand);\n"
"        if (candLen > uniforms.maxDisplacement) cand = (cand / candLen) * uniforms.maxDisplacement;\n"
"        float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);\n"
"        if (isHUDZone) err += 0.04f;\n"
"        if (err < bestError) { bestError = err; bestVector = cand; }\n"
"    }\n"
"    if (dot(bestVector, bestVector) > 1e-7f) {\n"
"        float refineStep = r1 * 0.5f;\n"
"        for (int i = 0; i < 4; i++) {\n"
"            float2 cand = bestVector + dirs[i] * refineStep;\n"
"            float err = eval_candidate_luma(prevTexture, uvsCurr, lCurr, cand);\n"
"            if (err < bestError) { bestError = err; bestVector = cand; }\n"
"        }\n"
"    }\n"
"    if (bestError >= errZero * 0.97f) {\n"
"        bestVector = float2(0.0f, 0.0f);\n"
"    }\n"
"    float finalLen = length(bestVector);\n"
"    if (finalLen > uniforms.maxDisplacement) bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;\n"
"    motionVectors.write(float4(bestVector, 0.0f, 1.0f), gid);\n"
"}\n"
"\n"
"kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],\n"
"                                        texture2d<float, access::read> inVectors [[texture(0)]],\n"
"                                        texture2d<float, access::write> outVectors [[texture(1)]]) {\n"
"    uint width = inVectors.get_width();\n"
"    uint height = inVectors.get_height();\n"
"    if (gid.x >= width || gid.y >= height) return;\n"
"    float2 vectors[9];\n"
"    int idx = 0;\n"
"    for (int dy = -1; dy <= 1; dy++) {\n"
"        for (int dx = -1; dx <= 1; dx++) {\n"
"            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);\n"
"            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);\n"
"            vectors[idx] = inVectors.read(uint2(cx, cy)).xy;\n"
"            idx++;\n"
"        }\n"
"    }\n"
"    float minDistanceSum = 1e9f;\n"
"    int bestIndex = 4;\n"
"    for (int i = 0; i < 9; i++) {\n"
"        float distSum = 0.0f;\n"
"        for (int j = 0; j < 9; j++) {\n"
"            distSum += distance(vectors[i], vectors[j]);\n"
"        }\n"
"        if (distSum < minDistanceSum) {\n"
"            minDistanceSum = distSum;\n"
"            bestIndex = i;\n"
"        }\n"
"    }\n"
"    outVectors.write(float4(vectors[bestIndex], 0.0f, 1.0f), gid);\n"
"}\n"
"\n"
"fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],\n"
"                                 texture2d<float, access::sample> sourceTexture [[texture(0)]],\n"
"                                 texture2d<float, access::sample> motionVectors [[texture(1)]],\n"
"                                 texture2d<float, access::sample> prevTexture [[texture(2)]],\n"
"                                 constant MetalFGWarpUniforms &uniforms [[buffer(1)]]) {\n"
"    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float4 currColor = sourceTexture.sample(linearSampler, in.texCoords);\n"
"    float4 prevColor = prevTexture.sample(linearSampler, in.texCoords);\n"
"    float pixelDiff = distance(currColor.rgb, prevColor.rgb);\n"
"    if (pixelDiff < uniforms.disocclusionThreshold * 0.35f) {\n"
"        if (uniforms.debugTint > 0.5f) { currColor.r = min(1.0f, currColor.r * 1.25f + 0.10f); }\n"
"        return currColor;\n"
"    }\n"
"    float2 mv = motionVectors.sample(linearSampler, in.texCoords).xy;\n"
"    float2 mvSrc = motionVectors.sample(linearSampler, in.texCoords - mv * uniforms.timeOffsetFactor).xy;\n"
"    float2 effMV = (dot(mvSrc, mvSrc) > dot(mv, mv)) ? mvSrc : mv;\n"
"    float mvLenSq = dot(effMV, effMV);\n"
"    if (mvLenSq < 1e-7f) {\n"
"        if (uniforms.debugTint > 0.5f) { currColor.b = min(1.0f, currColor.b * 1.25f + 0.10f); }\n"
"        return currColor;\n"
"    }\n"
"    float2 warpedUV = clamp(in.texCoords - effMV * uniforms.timeOffsetFactor, float2(0.001f), float2(0.999f));\n"
"    float4 sampleCurr = sourceTexture.sample(linearSampler, warpedUV);\n"
"    float2 uvPrev = clamp(in.texCoords + effMV * uniforms.timeOffsetFactor, float2(0.001f), float2(0.999f));\n"
"    float4 samplePrev = prevTexture.sample(linearSampler, uvPrev);\n"
"    float sampleDist = distance(sampleCurr.rgb, samplePrev.rgb);\n"
"    float confidence = smoothstep(uniforms.disocclusionThreshold * 1.6f, uniforms.disocclusionThreshold * 0.5f, sampleDist);\n"
"    float4 interpolated = mix(sampleCurr, samplePrev, 0.5f * confidence);\n"
"    float mvMag = sqrt(mvLenSq);\n"
"    float motionWeight = smoothstep(uniforms.motionDeadzone, uniforms.motionDeadzone * 3.0f, mvMag);\n"
"    float4 finalColor = mix(currColor, interpolated, motionWeight);\n"
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
    
    // Allocate lightweight motion vector grid textures (80x45, RG16Float: ~14 KB each)
    if (!_motionVectorTexture) {
        MTLTextureDescriptor *mvDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                          width:kGridWidth
                                                                                         height:kGridHeight
                                                                                      mipmapped:NO];
        mvDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        mvDesc.storageMode = MTLStorageModePrivate;
        _motionVectorTexture = [_device newTextureWithDescriptor:mvDesc];
        _motionVectorTexture.label = @"com.metalfg.rawMotionVectors";
        
        _smoothedMotionVectorTexture = [_device newTextureWithDescriptor:mvDesc];
        _smoothedMotionVectorTexture.label = @"com.metalfg.smoothedMotionVectors";
        NSLog(@"[MetalFG] Allocated motion vector grids: %ux%u", kGridWidth, kGridHeight);
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
