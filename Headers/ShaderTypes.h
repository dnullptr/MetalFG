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

// Uniform buffer passed to vertex and fragment shaders
typedef struct {
    simd_float3x3 homographyMatrix;     // 3x3 homography mapping target NDC -> source NDC
    simd_float3x3 invHomographyMatrix;  // 3x3 inverse homography mapping source NDC -> target NDC
    simd_float4   edgeFadeParams;       // x: edge fade width, y: vignette power, z: aspect ratio, w: flags
    simd_float4   debugColor;           // Debug indicator color (alpha > 0 activates visual debug mode)
} MetalFGUniforms;

// Buffer indices shared between host code and MSL
enum MetalFGBufferIndices {
    MetalFGBufferIndexVertices = 0,
    MetalFGBufferIndexUniforms = 1
};

// Texture indices shared between host code and MSL
enum MetalFGTextureIndices {
    MetalFGTextureIndexSource = 0
};

#endif /* ShaderTypes_h */
