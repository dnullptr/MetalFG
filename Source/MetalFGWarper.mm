#import "../Headers/MetalFGWarper.h"
#import <os/lock.h>
#import <objc/runtime.h>
#import <atomic>

extern "C" const char kMetalFGIsSyntheticKey = '\0';

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
"struct RasterizerData {\n"
"    float4 position [[position]];\n"
"    float2 texCoords;\n"
"};\n"
"\n"
"vertex RasterizerData metalfg_vertex(uint vertexID [[vertex_id]],\n"
"                                     constant MetalFGVertex *vertices [[buffer(0)]]) {\n"
"    RasterizerData out;\n"
"    out.position = float4(vertices[vertexID].position, 0.0, 1.0);\n"
"    out.texCoords = vertices[vertexID].texCoords;\n"
"    return out;\n"
"}\n"
"\n"
"fragment float4 metalfg_fragment(RasterizerData in [[stage_in]],\n"
"                                 texture2d<float, access::sample> sourceTexture [[texture(0)]]) {\n"
"    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);\n"
"    return sourceTexture.sample(linearSampler, in.texCoords);\n"
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
    id<MTLBuffer> _vertexBuffer;
    
    // Double-buffered intermediate textures to prevent race conditions with swapchain recycling
    id<MTLTexture> _cachedTextures[2];
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
        _edgeFadeWidth = 0.0f; // 0.0f: full edge-to-edge reprojection without vignette
        
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
        NSLog(@"[MetalFG] Error creating pipeline state: %@", error.localizedDescription);
        return NO;
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
        desc.storageMode = MTLStorageModePrivate; // Optimal high-bandwidth on Apple Silicon GPU
        
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
    
    os_unfair_lock_unlock(&_textureLock);
}

- (void)captureBaseTexture:(id<MTLTexture>)sourceTexture
             withTimestamp:(CFTimeInterval)timestamp
               orientation:(simd_quatf)orientation {
    if (!sourceTexture || sourceTexture.width < 250 || sourceTexture.height < 150) return;
    
    [self ensureTextureStorageForSource:sourceTexture];
    
    os_unfair_lock_lock(&_textureLock);
    NSInteger writeIdx = _activeWriteIndex;
    id<MTLTexture> destTexture = _cachedTextures[writeIdx];
    os_unfair_lock_unlock(&_textureLock);
    
    if (!destTexture) return;
    
    id<MTLCommandBuffer> blitCmd = [_commandQueue commandBuffer];
    blitCmd.label = @"com.metalfg.baseFrameBlit";
    
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
        // Swap read and write indices now that the blit is complete
        strongSelf->_activeReadIndex = writeIdx;
        strongSelf->_activeWriteIndex = (writeIdx == 0 ? 1 : 0);
        strongSelf->_hasValidBaseFrame = YES;
        os_unfair_lock_unlock(&strongSelf->_textureLock);
    }];
    
    [blitCmd commit];
}

- (BOOL)renderSyntheticFrameToDrawable:(id<CAMetalDrawable>)targetDrawable
                     homographyMatrix:(simd_float3x3)homography
                  invHomographyMatrix:(simd_float3x3)invHomography
                        targetTimeHint:(CFTimeInterval)targetTimeHint {
    if (!targetDrawable || !_isReady) return NO;
    
    os_unfair_lock_lock(&_textureLock);
    if (!_hasValidBaseFrame) {
        os_unfair_lock_unlock(&_textureLock);
        return NO; // No native base frame received yet
    }
    id<MTLTexture> sourceTex = _cachedTextures[_activeReadIndex];
    os_unfair_lock_unlock(&_textureLock);
    
    if (!sourceTex) return NO;
    
    // Backpressure fail-safe: prevent queue buildup if GPU is saturated
    if (_inFlightGpuFrames.load() >= 2) {
        // Drop synthetic frame immediately to prioritize native frames
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
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    
    // Tag the synthetic drawable to prevent recursive presentation hooking
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
