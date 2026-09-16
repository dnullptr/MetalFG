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

// Buffer indices shared between host code and MSL
enum MetalFGBufferIndices {
    MetalFGBufferIndexVertices = 0
};

// Texture indices shared between host code and MSL
enum MetalFGTextureIndices {
    MetalFGTextureIndexSource = 0
};

#endif /* ShaderTypes_h */
