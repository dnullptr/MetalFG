#import "../Headers/MetalFGWarper.h"
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
"    float pad[3];\n"
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
"    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float2 centerUV = (float2(gid) + 0.5f) / float2(uniforms.gridDimensions);\n"
"    bool isHUDZone = (centerUV.y < 0.18f) || (centerUV.x < 0.35f && centerUV.y > 0.55f) || (centerUV.x > 0.65f && centerUV.y > 0.55f);\n"
"    const float dUV = 0.004f;\n"
"    float errZero = 0.0f;\n"
"    for (int py = -1; py <= 1; py++) {\n"
"        for (int px = -1; px <= 1; px++) {\n"
"            float2 uvCurr = centerUV + float2(px, py) * dUV;\n"
"            errZero += abs(rgb_to_luma(currTexture.sample(s, uvCurr)) - rgb_to_luma(prevTexture.sample(s, uvCurr)));\n"
"        }\n"
"    }\n"
"    errZero /= 9.0f;\n"
"    float effectiveThreshold = isHUDZone ? (uniforms.uiThreshold * 1.5f) : uniforms.uiThreshold;\n"
"    if (errZero < effectiveThreshold) {\n"
"        motionVectors.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);\n"
"        return;\n"
"    }\n"
"    float2 prior = uniforms.touchVelocity;\n"
"    float bestError = errZero;\n"
"    float2 bestVector = float2(0.0f, 0.0f);\n"
"    float stepSize = uniforms.searchRadius / 4.0f;\n"
"    for (int sy = -2; sy <= 2; sy++) {\n"
"        for (int sx = -2; sx <= 2; sx++) {\n"
"            float2 candidate = prior + float2(sx, sy) * stepSize;\n"
"            float candLen = length(candidate);\n"
"            if (candLen > uniforms.maxDisplacement) candidate = (candidate / candLen) * uniforms.maxDisplacement;\n"
"            float error = 0.0f;\n"
"            for (int py = -1; py <= 1; py++) {\n"
"                for (int px = -1; px <= 1; px++) {\n"
"                    float2 uvCurr = centerUV + float2(px, py) * dUV;\n"
"                    float2 uvPrev = uvCurr - candidate;\n"
"                    error += abs(rgb_to_luma(currTexture.sample(s, uvCurr)) - rgb_to_luma(prevTexture.sample(s, uvPrev)));\n"
"                }\n"
"            }\n"
"            error /= 9.0f;\n"
"            error += length(candidate - prior) * 0.03f;\n"
"            if (isHUDZone) error += 0.04f;\n"
"            if (error < bestError) {\n"
"                bestError = error;\n"
"                bestVector = candidate;\n"
"            }\n"
"        }\n"
"    }\n"
"    float finalLen = length(bestVector);\n"
"    if (finalLen > uniforms.maxDisplacement) bestVector = (bestVector / finalLen) * uniforms.maxDisplacement;\n"
"    motionVectors.write(float4(bestVector, 0.0f, 1.0f), gid);\n"
"}\n"
"\n"
"inline float median9(float p[9]) {\n"
"    for (int i = 0; i < 5; i++) {\n"
"        for (int j = i + 1; j < 9; j++) {\n"
"            if (p[j] < p[i]) {\n"
"                float tmp = p[i]; p[i] = p[j]; p[j] = tmp;\n"
"            }\n"
"        }\n"
"    }\n"
"    return p[4];\n"
"}\n"
"\n"
"kernel void metalfg_motion_median_filter(uint2 gid [[thread_position_in_grid]],\n"
"                                        texture2d<float, access::read> inVectors [[texture(0)]],\n"
"                                        texture2d<float, access::write> outVectors [[texture(1)]]) {\n"
"    uint width = inVectors.get_width();\n"
"    uint height = inVectors.get_height();\n"
"    if (gid.x >= width || gid.y >= height) return;\n"
"    float vx[9], vy[9];\n"
"    int idx = 0;\n"
"    for (int dy = -1; dy <= 1; dy++) {\n"
"        for (int dx = -1; dx <= 1; dx++) {\n"
"            int cx = clamp(int(gid.x) + dx, 0, int(width) - 1);\n"
"            int cy = clamp(int(gid.y) + dy, 0, int(height) - 1);\n"
"            float2 v = inVectors.read(uint2(cx, cy)).xy;\n"
"            vx[idx] = v.x; vy[idx] = v.y; idx++;\n"
"        }\n"
"    }\n"
"    outVectors.write(float4(median9(vx), median9(vy), 0.0f, 1.0f), gid);\n"
"}\n"
"\n"
"fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],\n"
"                                 texture2d<float, access::sample> sourceTexture [[texture(0)]],\n"
"                                 texture2d<float, access::sample> motionVectors [[texture(1)]],\n"
"                                 constant MetalFGWarpUniforms &uniforms [[buffer(1)]]) {\n"
"    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    float4 origColor = sourceTexture.sample(linearSampler, in.texCoords);\n"
"    float2 mv = motionVectors.sample(linearSampler, in.texCoords).xy;\n"
"    if (dot(mv, mv) < 1e-7f) {\n"
"        return origColor;\n"
"    }\n"
"    float2 warpedUV = in.texCoords + mv * uniforms.timeOffsetFactor;\n"
"    float4 warpedColor = sourceTexture.sample(linearSampler, warpedUV);\n"
"    float colorDist = distance(warpedColor.rgb, origColor.rgb);\n"
"    float confidence = smoothstep(0.38f, 0.06f, colorDist);\n"
"    return mix(origColor, warpedColor, confidence);\n"
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
    
    // 1. Try loading compiled metallib from rootless directory
    NSString *rootlessMetallibPath = @"/var/jb/Library/Application Support/MetalFG/default.metallib";
    if ([[NSFileManager defaultManager] fileExistsAtPath:rootlessMetallibPath]) {
        NSURL *url = [NSURL fileURLWithPath:rootlessMetallibPath];
        library = [_device newLibraryWithURL:url error:&error];
        if (library) {
            NSLog(@"[MetalFG] Loaded precompiled shader library from %@", rootlessMetallibPath);
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
        bmeUniforms.uiThreshold = 0.035f;
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
    
    MetalFGWarpUniforms warpUniforms;
    warpUniforms.timeOffsetFactor = 0.5f; // 50% midpoint forward extrapolation
    warpUniforms.pad[0] = 0.0f;
    warpUniforms.pad[1] = 0.0f;
    warpUniforms.pad[2] = 0.0f;
    [enc setFragmentBytes:&warpUniforms length:sizeof(warpUniforms) atIndex:MetalFGBufferIndexWarpUniforms];
    
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    
    // Tag synthetic drawable to prevent recursive presentation hooking
    objc_setAssociatedObject(targetDrawable, &kMetalFGIsSyntheticKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Present synthetic drawable at the exact hardware display timestamp hint
    if (targetTimeHint > 0.0) {
        [cmdBuffer presentDrawable:targetDrawable atTime:targetTimeHint];
    } else {
        [cmdBuffer presentDrawable:targetDrawable];
    }
    
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

@end
