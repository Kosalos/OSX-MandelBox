#pragma once
#include <simd/simd.h>

typedef struct {
    matrix_float4x4 transformMatrix;
    matrix_float3x3 endPosition;
} ArcBallData;

typedef struct {
    vector_float3 position;
    float diffuse;
    float specular;
    float saturation;
    float gamma;
} Lighting;

typedef struct {
    int version;
    vector_float3 camera;
    vector_float3 focus;
    
    int xSize,ySize;
    float zoom;
    float scaleFactor;
    float epsilon;
    
    ArcBallData aData;
    
    vector_float3 julia;
    char isJulia;
    
    vector_float3 sphere;
    float sphereMult;
    vector_float3 box;
    vector_float3 color;
    
    Lighting lighting;
    
    vector_float3 viewVector,topVector,sideVector;
    
    float parallax;
    char isBurningShip;
    float fog;
    
    float deFactor1,deFactor2;
    float radialAngle;
    vector_float3 dBox;         // alter box,sphere during DE iterations
    vector_float3 dSphere;
    vector_float3 ddBox;        // alter dBox,dSsphere
    vector_float3 ddSphere;
    
    int txtOnOff;
    vector_float2 txtSize;
    vector_float3 txtCenter;

} Control;
