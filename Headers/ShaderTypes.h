#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#define NSInteger metal::int32_t
#else
#import <Foundation/Foundation.h>
#import <simd/simd.h>
#endif

// Vertex structure for the full-screen reprojection quad
typedef struct {
    simd_float2 position;   // Normalized Device Coordinates (NDC): [-1, 1]
    simd_float2 texCoords;  // Metal Texture Coordinates (UV): [0, 1]
} MetalFGVertex;

// Uniforms for Block Motion Estimation compute kernel (32 bytes, 16-byte aligned)
typedef struct {
    simd_float2 touchVelocity;  // Normalized UV velocity delta from touch tracking
    simd_uint2 gridDimensions;  // Number of blocks (width, height) e.g. (80, 45)
    float uiThreshold;          // Static UI luminance threshold (e.g. 0.035)
    float searchRadius;         // Search radius in UV space (e.g. 0.040)
    float maxDisplacement;      // Maximum motion vector magnitude cap (e.g. 0.035)
    float pad;                  // Explicit padding for 16-byte alignment
} MetalFGBMEUniforms;

// Uniforms for Synthetic Frame Warping fragment shader (16 bytes, 16-byte aligned)
typedef struct {
    float timeOffsetFactor;      // Configurable motion scale (0.10 to 0.70, default 0.45)
    float disocclusionThreshold; // Disocclusion color divergence threshold (0.08 to 0.35, default 0.20)
    float motionDeadzone;        // Minimum motion magnitude cutoff (0.0001 to 0.0020, default 0.0004)
    float debugTint;             // 1.0 = Visual debug tint active, 0.0 = Normal
} MetalFGWarpUniforms;

// Buffer indices shared between host code and MSL
enum MetalFGBufferIndices {
    MetalFGBufferIndexVertices = 0,
    MetalFGBufferIndexBMEUniforms = 0,
    MetalFGBufferIndexWarpUniforms = 1
};

// Texture indices shared between host code and MSL
enum MetalFGTextureIndices {
    MetalFGTextureIndexSource = 0,
    MetalFGTextureIndexMotionVectors = 1,
    MetalFGTextureIndexPrev = 2,
    
    // BME Compute Kernel Texture Indices
    MetalFGBMETexturePrev = 0,
    MetalFGBMETextureCurr = 1,
    MetalFGBMETextureMotionVectors = 2,
    
    // Median Filter Compute Kernel Texture Indices
    MetalFGSmoothTextureInput = 0,
    MetalFGSmoothTextureOutput = 1
};

#endif /* ShaderTypes_h */
