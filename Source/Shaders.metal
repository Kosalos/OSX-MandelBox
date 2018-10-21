#include <metal_stdlib>
#import "Shader.h"

using namespace metal;

constant int MAX_ITERS = 10;  // adjust these higher for better/slower rendering
constant int MAX_STEPS = 150;

float DE    // distance estimate
(
 float3 position,
 constant Control &control)
{
    float3 c = control.isJulia ? control.julia : position;
    float3 v = position;
    float dr = 1.5;
    
    Control cc = control;
    
    for (int i = 0; i < MAX_ITERS; i++) {
        v = clamp(v, -cc.box.x, cc.box.x) * cc.box.y - v;
        if(control.isBurningShip) v = -abs(v);
        
        float mag = dot(v, v);
        if(mag < cc.sphere.x) {
            v = v * control.sphereMult;
            dr = dr * control.sphereMult;
        }
        else if (mag < cc.sphere.y) {
            v = v / mag;
            dr = dr / mag;
        }
        
        v = v * control.scaleFactor + c;
        dr = dr * abs(control.scaleFactor) + 1.0;

        cc.box *= cc.dBox;
        cc.sphere *= cc.dSphere;
        
        cc.dBox *= cc.ddBox;
        cc.dSphere *= cc.ddSphere;
    }
    
    return (length(v) - control.deFactor1) / dr - control.deFactor2;
}

//MARK: -

float3 getNormal
(
 float3 position,
 constant Control &control)
{
    float eps = control.epsilon;
    float3 normal = float3(DE(position + float3(eps, 0, 0),control) - DE(position - float3(eps, 0, 0),control),
                           DE(position + float3(0, eps, 0),control) - DE(position - float3(0, eps, 0),control),
                           DE(position + float3(0, 0, eps),control) - DE(position - float3(0, 0, eps),control));
    return normalize(normal);
}

//MARK: -

float3 lighting
(
 float3 position,
 float distance,
 constant Control &control)
{
    float3 normal = getNormal(position,control);
    float3 color = normal * control.color;
    
    float3 L = normalize(control.lighting.position - position);
    float dotLN = dot(L, normal);
    if(dotLN >= 0) {
        color += control.lighting.diffuse * dotLN;

        float3 V = normalize(float3(distance));
        float3 R = normalize(reflect(-L, normal));
        float dotRV = dot(R, V);
        if(dotRV >= 0) color += control.lighting.specular * pow(dotRV, 2);
    }
    
    return color;
}

//MARK: -

float rayMarch
(
 float3 rayDir,
 constant Control &control)
{
    float de,distance = 0.0;
    float3 position;

    for(int i = 0; i < MAX_STEPS; ++i) {
        position = control.camera + rayDir * distance;
        
        de = DE(position, control);
        if(de < control.epsilon) break;
        
        distance += de;
        if(distance > control.fog) return 0;
    }
    
    return distance;
}

//MARK: -

kernel void mandelBoxShader
(
 texture2d<float, access::write> outTexture [[texture(0)]],
 texture2d<float, access::read> coloringTexture [[texture(1)]],
 constant Control &control [[buffer(0)]],
 uint2 p [[thread_position_in_grid]])
{
    if(p.x > uint(control.xSize) || p.y > uint(control.ySize)) return;
    uint2 srcP = p;

    if(control.radialAngle > 0.01) { // 0 = don't apply
        float centerX = control.xSize/2;
        float centerY = control.ySize/2;
        float dx = float(p.x - centerX);
        float dy = float(p.y - centerY);
        float angle = fabs(atan2(dy,dx));
        float dRatio = 0.01 + control.radialAngle;
        
        while(angle > dRatio) angle -= dRatio;
        if(angle > dRatio/2) angle = dRatio - angle;

        float dist = sqrt(dx * dx + dy * dy);

        srcP.x = uint(centerX + cos(angle) * dist);
        srcP.y = uint(centerY + sin(angle) * dist);
    }

    float den = float(control.xSize);
    float dx =  control.zoom * (float(srcP.x)/den - 0.5);
    float dy = -control.zoom * (float(srcP.y)/den - 0.5);

    float3 direction = normalize((control.sideVector * dx) + (control.topVector * dy) + control.viewVector);
    float3 color = float3();

    float distance = rayMarch(direction,control);
    if(distance > 0) {
        float3 position = control.camera + distance * direction;
        float3 normal = getNormal(position,control);
    
        // use texture
        if(control.txtOnOff > 0) {
            float scale = control.txtCenter.z * 20;
            float len = length(position) / 4; //distance;
            float x = normal.x * len;
            float y = normal.z * len;
            float w = control.txtSize.x;
            float h = control.txtSize.y;
            float xx = w + (control.txtCenter.x * 10 + x * scale) * (w + len);
            float yy = h + (control.txtCenter.y * 10 + y * scale) * (h + len);
            
            uint2 pt;
            pt.x = uint(fmod(xx,w));
            pt.y = uint(control.txtSize.y - fmod(yy,h)); // flip Y coord
            color = coloringTexture.read(pt).xyz;
        }
        
        color += lighting(position,distance,control);
        
        color *= (1 - distance / control.fog);
    }

    outTexture.write(float4(color,1),p);
}
