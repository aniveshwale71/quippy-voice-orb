#ifndef OrbShaderTypes_h
#define OrbShaderTypes_h

#ifdef __METAL_VERSION__
typedef metal::float4x4 matrix_float4x4;
typedef metal::float4 vector_float4;
typedef metal::float3 vector_float3;
typedef metal::float2 vector_float2;
#else
#import <simd/simd.h>
#endif

typedef struct {
    matrix_float4x4 viewProjection;
    matrix_float4x4 spin;

    vector_float4 cameraPosition;      // xyz world, w unused
    vector_float4 particleColor;       // rgb, a = master opacity
    vector_float4 coreColorA;          // rgb, a unused
    vector_float4 coreColorB;          // rgb, a unused
    vector_float4 particleColorA;      // darker swatch of emotion A
    vector_float4 particleColorB;      // darker swatch of emotion B

    // Drag. Origin is pre-spin so it stays pinned to the surface it grabbed.
    vector_float4 dragOrigin;          // xyz unit direction (pre-spin), w = 1 while dragging
    vector_float4 dragVector;          // xyz world-space drag direction × magnitude

    vector_float4 coreLightDirection;  // xyz unit, w unused

    vector_float4 idleMotion; // x cycle phase, y ripple force, z core scale, w unused

    float time;
    float deltaTime;
    float orbRadius;
    float pointScale;                  // (drawableHeight / 2) / tan(fovY / 2)
    float particlePointSize;           // world-space diameter of one particle

    float flowAmplitude;
    float flowFrequency;
    float flowSpeed;
    float radialAmplitude;

    float radialFrequency;
    float shellThickness;
    float rimStrength;
    float rimExponent;

    float interiorAlpha;
    float backDimming;
    float sizeDepthGain;
    float audioLevel;                  // shared normalized envelope, 0...1

    float outerAudioGain;
    float coreAudioGain;
    float coreRadiusRatio;
    float tanHalfFov;                  // tan(fovY / 2)

    unsigned int particleCount;
    float nearPlane;
    float farPlane;
    float maxRadius;                   // no particle may travel past this, in orb radii

    // Gesture response.
    float rippleSpeed;                 // radians of arc the tap front crosses per second
    float rippleWidth;                 // angular thickness of the front
    float rippleDecay;                 // per-second amplitude decay of a tap
    float dragRadius;                  // angular falloff of the drag grab

    float dragStrength;
    float springStiffness;
    float springDamping;
    unsigned int impulseCount;

    // Core.
    float aspect;                      // drawable width / height
    float coreBoundarySoftness;        // half-width of the feather between the two colours
    float coreRegionDrift;             // radians per second the colour axis turns
    float coreWarpAmount;              // how far noise bends the boundary off a great circle

    float coreWarpFrequency;
    float coreAmbient;                 // floor brightness, so the unlit side still glows
    float coreSpecular;
    float coreEdgeDarkening;           // how much the silhouette falls off
    float coreMotionPhase;             // integrated clock; never jumps on state changes
    float coreMotionIntensity;         // smoothed idle/listening/speaking activity
} OrbUniforms;

// One tap. Lives in its own buffer so the uniform block stays a flat struct.
typedef struct {
    vector_float4 origin;   // xyz unit direction (pre-spin), w = start time
    vector_float4 params;   // x = strength, yzw spare
} OrbImpulse;

// Immutable, seeded. Generated once; never regenerated per frame.
typedef struct {
    vector_float4 base;     // xyz = unit direction on the sphere, w = per-particle seed 0...1
    vector_float4 params;   // x = radius scale, y = size scale, z = phase offset, w = stray flag
} OrbParticleSeed;

// Mutable per-particle simulation state (gesture springs land here in phase 3).
typedef struct {
    vector_float4 displacement;  // xyz world-space offset, w unused
    vector_float4 velocity;      // xyz world-space velocity, w unused
} OrbParticleState;

// Compute-shader output consumed by the point vertex shader.
typedef struct {
    vector_float4 positionSize;  // xyz = world position, w = point size in drawable pixels
    vector_float4 tint;          // rgb = colour, a = alpha
} OrbParticleRender;

#endif /* OrbShaderTypes_h */
