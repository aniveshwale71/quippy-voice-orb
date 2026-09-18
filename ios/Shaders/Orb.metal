#include <metal_stdlib>
#include "OrbShaderTypes.h"

using namespace metal;

// MARK: - Noise

static float hash1(float3 p) {
    p = fract(p * 0.3183099f + float3(0.1f, 0.2f, 0.3f));
    p *= 17.0f;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float valueNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0f - 2.0f * f);
    float n000 = hash1(i + float3(0, 0, 0));
    float n100 = hash1(i + float3(1, 0, 0));
    float n010 = hash1(i + float3(0, 1, 0));
    float n110 = hash1(i + float3(1, 1, 0));
    float n001 = hash1(i + float3(0, 0, 1));
    float n101 = hash1(i + float3(1, 0, 1));
    float n011 = hash1(i + float3(0, 1, 1));
    float n111 = hash1(i + float3(1, 1, 1));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z) * 2.0f - 1.0f;
}

static float3 noiseField(float3 p) {
    return float3(valueNoise(p),
                  valueNoise(p + float3(31.416f, 17.137f, 5.291f)),
                  valueNoise(p - float3(19.317f, 47.711f, 11.083f)));
}

// Divergence-free flow so particles swirl instead of piling into sinks.
static float3 curlNoise(float3 p) {
    const float e = 0.22f;
    float3 dx = float3(e, 0.0f, 0.0f);
    float3 dy = float3(0.0f, e, 0.0f);
    float3 dz = float3(0.0f, 0.0f, e);

    float3 px0 = noiseField(p - dx), px1 = noiseField(p + dx);
    float3 py0 = noiseField(p - dy), py1 = noiseField(p + dy);
    float3 pz0 = noiseField(p - dz), pz1 = noiseField(p + dz);

    float x = (py1.z - py0.z) - (pz1.y - pz0.y);
    float y = (pz1.x - pz0.x) - (px1.z - px0.z);
    float z = (px1.y - px0.y) - (py1.x - py0.x);
    return float3(x, y, z) / (2.0f * e);
}

// MARK: - Particle simulation

// Displacement is a bounded *function* of (identity, time): particles wander
// continuously but can never drift away, clump, or need a reset.
// Unit vector pointing along the surface, away from `origin`, at `dir`.
// Degenerates at the poles of that great circle, where it is simply unused.
static float3 surfaceAwayDirection(float3 dir, float3 origin) {
    float3 away = dir - origin * dot(dir, origin);
    float len = length(away);
    return len > 1e-4f ? away / len : float3(0.0f);
}

kernel void orbParticleUpdate(device const OrbParticleSeed *seeds   [[buffer(0)]],
                              device OrbParticleState *states       [[buffer(1)]],
                              device OrbParticleRender *out         [[buffer(2)]],
                              constant OrbUniforms &u               [[buffer(3)]],
                              device const OrbImpulse *impulses     [[buffer(4)]],
                              uint id                               [[thread_position_in_grid]])
{
    if (id >= u.particleCount) { return; }

    OrbParticleSeed seed = seeds[id];
    float3 dir = normalize(seed.base.xyz);
    float phase = seed.params.z;

    float t = u.time * u.flowSpeed;
    float3 samplePoint = dir * u.flowFrequency + float3(0.0f, 0.0f, t) + phase;
    float3 flow = curlNoise(samplePoint);

    // Keep the swirl on the shell: strip the radial component.
    float3 tangential = flow - dir * dot(flow, dir);
    float audio = clamp(u.audioLevel, 0.0f, 1.0f);
    float3 wandered = normalize(dir + tangential * u.flowAmplitude * (1.0f + audio * 0.6f));

    float breathing = valueNoise(dir * u.radialFrequency + float3(t * 0.7f, phase, -t * 0.5f));
    float shell = seed.params.x + breathing * u.radialAmplitude;
    float radius = u.orbRadius * shell * (1.0f + audio * u.outerAudioGain);

    float3 resting = (u.spin * float4(wandered * radius, 1.0f)).xyz;

    // MARK: Gesture springs
    //
    // Every particle is a damped spring anchored to its own resting point, so
    // any gesture, however violent, decays back to the idle sphere.

    float3 displacement = states[id].displacement.xyz;
    float3 velocity = states[id].velocity.xyz;
    float3 force = float3(0.0f);

    float3 outward = normalize(resting);

    for (uint k = 0; k < u.impulseCount; ++k) {
        OrbImpulse impulse = impulses[k];
        float age = u.time - impulse.origin.w;
        if (age < 0.0f) { continue; }

        // An expanding band of arc, not a uniform push: the tap reads as a
        // ripple crossing the surface rather than the whole sphere inflating.
        float arc = acos(clamp(dot(dir, impulse.origin.xyz), -1.0f, 1.0f));
        float offset = (arc - u.rippleSpeed * age) / u.rippleWidth;
        float band = exp(-offset * offset);
        float amplitude = impulse.params.x * band * exp(-age * u.rippleDecay);

        float3 away = surfaceAwayDirection(dir, impulse.origin.xyz);
        float3 awayWorld = (u.spin * float4(away, 0.0f)).xyz;
        force += (outward + awayWorld * 0.35f) * amplitude;
    }

    if (u.dragOrigin.w > 0.5f) {
        float arc = acos(clamp(dot(dir, u.dragOrigin.xyz), -1.0f, 1.0f));
        float reach = arc / u.dragRadius;
        force += u.dragVector.xyz * u.dragStrength * exp(-reach * reach);
    }

    force += -u.springStiffness * displacement - u.springDamping * velocity;

    velocity += force * u.deltaTime;
    displacement += velocity * u.deltaTime;

    // Hard bound on the final position, not on the displacement, so every
    // particle gets the same reach and a stray whose resting radius already sits
    // too far out is pulled back in rather than being clipped by the canvas.
    float3 world = resting + displacement;
    float distance = length(world);
    if (distance > u.maxRadius) {
        float3 overshoot = world / distance;
        world = overshoot * u.maxRadius;
        displacement = world - resting;
        velocity -= overshoot * max(dot(velocity, overshoot), 0.0f);
    }

    states[id].displacement = float4(displacement, 0.0f);
    states[id].velocity = float4(velocity, 0.0f);

    // Depth and silhouette shading.
    float3 toCamera = u.cameraPosition.xyz - world;
    float viewDistance = max(length(toCamera), 0.001f);
    float3 viewDir = toCamera / viewDistance;
    float cameraDistance = length(u.cameraPosition.xyz);

    float front = saturate((cameraDistance - viewDistance) / (2.0f * u.orbRadius) + 0.5f);
    float facing = abs(dot(normalize(world), viewDir));
    float rim = pow(saturate(1.0f - facing), u.rimExponent);

    // Depth only dims the interior. A silhouette particle sits at mid-depth, so
    // folding depth into the rim term would stop the outline ever going fully dark.
    float depthDim = mix(u.backDimming, 1.0f, front);
    float alpha = mix(u.interiorAlpha * depthDim, u.rimStrength, rim) * u.particleColor.a;

    float worldSize = u.particlePointSize * seed.params.y * (1.0f - u.sizeDepthGain + u.sizeDepthGain * 2.0f * front);
    float pixelSize = worldSize * u.pointScale / viewDistance;

    OrbParticleRender r;
    r.positionSize = float4(world, max(pixelSize, 0.75f));
    // Alternating Fibonacci identities each cover the entire sphere evenly.
    // Stable IDs preserve an exact 50/50 split for the default 2880 dots.
    float3 tint = (id & 1u) == 0u ? u.particleColorA.rgb : u.particleColorB.rgb;
    r.tint = float4(tint, alpha);
    out[id] = r;
}

// MARK: - Particle rendering

struct ParticleVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 tint;
};

vertex ParticleVertexOut orbParticleVertex(device const OrbParticleRender *particles [[buffer(0)]],
                                           constant OrbUniforms &u                   [[buffer(1)]],
                                           uint id                                   [[vertex_id]])
{
    OrbParticleRender p = particles[id];
    ParticleVertexOut out;
    out.position = u.viewProjection * float4(p.positionSize.xyz, 1.0f);
    // Reserve sprite space for a soft halo without enlarging the dot core.
    out.pointSize = p.positionSize.w * 2.0f;
    out.tint = p.tint;
    return out;
}

fragment float4 orbParticleFragment(ParticleVertexOut in [[stage_in]],
                                    float2 pointCoord [[point_coord]])
{
    float d = length(pointCoord - float2(0.5f));
    // The original dot occupies the central half of this enlarged sprite.
    // Feather its edge, then blend a restrained colour-matched halo around it.
    float edge = max(fwidth(d), 0.055f);
    // Double the previous transition width, retaining the outer dot radius.
    float featherWidth = 2.0f * (0.27f - max(0.25f - edge, 0.10f));
    float core = 1.0f - smoothstep(0.27f - featherWidth, 0.27f, d);
    float halo = 0.40f * exp(-12.0f * d * d)
        * (1.0f - smoothstep(0.36f, 0.5f, d));
    float mask = core + halo * (1.0f - core);
    if (mask <= 0.001f) { discard_fragment(); }
    float3 haloTint = mix(in.tint.rgb, float3(1.0f), 0.28f);
    float3 tint = mix(haloTint, in.tint.rgb, core);
    return float4(tint, in.tint.a * mask);
}

// MARK: - Inner core
//
// A shaded impostor sphere: one screen quad, the sphere solved analytically per
// fragment. Two explicit colours occupy broad regions either side of a slowly
// turning, noise-bent boundary. Nothing here deforms the shape — only the
// colour regions move.

static float fbm3(float3 p) {
    float sum = 0.0f;
    float amplitude = 0.5f;
    for (int i = 0; i < 3; ++i) {
        sum += valueNoise(p) * amplitude;
        p *= 2.03f;
        amplitude *= 0.5f;
    }
    return sum;
}

struct CoreVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CoreVertexOut orbCoreVertex(uint id [[vertex_id]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[id];
    CoreVertexOut out;
    out.position = float4(c, 0.0f, 1.0f);
    out.uv = c;
    return out;
}

// Shared field keeps the coloured halo aligned with the core's moving regions.
static float3 coreRegionColor(float3 n, constant OrbUniforms &u) {
    float t = u.coreMotionPhase;
    float tilt = sin(t * 0.37f) * 0.28f;
    float3 axis = normalize(float3(cos(t), sin(t), tilt));
    float activity = u.coreMotionIntensity;
    // Twist the coordinate field continuously so the two regions fold around
    // one another. No per-frame random values and no sudden phase changes.
    float swirl = max(activity - 0.12f, 0.0f);
    float twist = swirl * (n.y * 1.55f + sin(n.x * 2.2f + t * 0.8f) * 0.50f);
    float cs = cos(twist), sn = sin(twist);
    float3 q = float3(cs * n.x - sn * n.y, sn * n.x + cs * n.y, n.z);
    float warp = fbm3(q * u.coreWarpFrequency + float3(t * 0.35f, -t * 0.24f, t * 0.6f));
    float detail = valueNoise(q * 3.1f + float3(-t * 0.7f, t * 0.45f, t));
    float field = dot(q, axis) + warp * u.coreWarpAmount * (1.0f + activity * 2.1f)
                + detail * activity * 0.16f;
    float feather = max(u.coreBoundarySoftness, 0.01f);
    float3 pigment = mix(u.coreColorA.rgb, u.coreColorB.rgb, smoothstep(-feather, feather, field));
    // Diffuse the exact 500 pigments through a softly lit material. The core
    // and halo share this tint; particles retain their darker raw swatches.
    return mix(pigment, float3(1.0f, 0.985f, 0.965f), 0.38f);
}

fragment float4 orbGlowFragment(CoreVertexOut in [[stage_in]],
                                constant OrbUniforms &u [[buffer(0)]]) {
    float worldRadius = u.orbRadius * u.coreRadiusRatio * (1.0f + clamp(u.audioLevel, 0.0f, 1.0f) * u.coreAudioGain);
    float ndcRadius = worldRadius / length(u.cameraPosition.xyz) / u.tanHalfFov;
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) / max(ndcRadius, 0.0001f);
    float radius = length(p);
    if (radius > 1.65f) { discard_fragment(); }
    // White bloom, independent of the selected emotion pigments.
    float3 tint = float3(1.0f);
    float falloff = exp(-pow(max(radius - 0.76f, 0.0f) / 0.43f, 2.0f));
    float alpha = falloff * (0.50f + u.audioLevel * 0.08f)
                * (1.0f - smoothstep(1.45f, 1.65f, radius));
    return float4(tint, alpha);
}

struct CoreFragmentOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
};

fragment CoreFragmentOut orbCoreFragment(CoreVertexOut in [[stage_in]],
                                         constant OrbUniforms &u [[buffer(0)]])
{
    float cameraDistance = length(u.cameraPosition.xyz);
    float audio = clamp(u.audioLevel, 0.0f, 1.0f);
    float worldRadius = u.orbRadius * u.coreRadiusRatio * (1.0f + audio * u.coreAudioGain);
    float ndcRadius = (worldRadius / cameraDistance) / u.tanHalfFov;

    // NDC x is compressed by the aspect ratio, so undo it before solving the disc.
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) / max(ndcRadius, 0.0001f);
    float r2 = dot(p, p);
    if (r2 > 1.0f) { discard_fragment(); }

    // The camera sits on +z looking down -z with no rotation, so the view-space
    // normal is also the world normal.
    float z = sqrt(saturate(1.0f - r2));
    float3 n = float3(p, z);

    // MARK: Two colour regions
    //
    // A great circle whose axis turns slowly, bent off-true by noise so the
    // boundary is organic rather than a drawn arc.
    //
    // The axis is built from a full-length direction in the view plane plus a
    // small bounded tilt. It can therefore never swing toward the camera, which
    // would push the boundary off the visible face and leave one colour filling
    // the whole disc.

    float3 base = coreRegionColor(n, u);

    // MARK: Shading

    float3 lightDir = normalize(u.coreLightDirection.xyz);
    float ndotl = dot(n, lightDir);

    // Wrapped diffuse: the terminator is broad and the unlit side keeps its hue
    // instead of going grey, which is what makes it read as a soft volume.
    // `coreAmbient` is the floor, so the body glows rather than fading to black.
    float wrapped = saturate((ndotl + 0.75f) / 1.75f);

    // Milk-glass diffusion: keep shadows close to the base hue instead of
    // squaring the colour (which created a saturated, muddy lower hemisphere).
    float3 shade = base * mix(u.coreAmbient, 1.0f, wrapped);

    // Broad transmitted light gives a rounded highlight without a glossy hotspot.
    float3 halfway = normalize(lightDir + float3(0.0f, 0.0f, 1.0f));
    float ndoth = saturate(dot(n, halfway));
    // Bevel-inspired broad softbox: a pale, hue-tinted light pool, not
    // a clipped specular spot. Both colour regions receive the same lighting.
    float diffusion = pow(ndoth, 3.5f) * 0.48f + (1.0f - r2) * 0.04f;
    float3 transmittedLight = mix(base, float3(1.0f), 0.52f);
    shade = mix(shade, transmittedLight, diffusion);
    shade += base * pow(ndoth, 6.0f) * u.coreSpecular;

    // Modest grazing light balances gentle edge shading: enough depth to read
    // as a sphere, without the original hard, dark silhouette.
    float rim = pow(1.0f - z, 2.0f);
    // Let the white bloom scatter just inside the surface as well.
    shade = mix(shade, float3(1.0f), rim * 0.20f);
    shade *= mix(1.0f - u.coreEdgeDarkening, 1.0f, sqrt(z));

    // A small diffuse silhouette roll-off is resolved analytically, not via
    // a full-view blur that would soften the outer particles as well.
    float radial = sqrt(r2);
    float edge = max(fwidth(radial) * 1.5f, 0.26f);
    float alpha = 1.0f - smoothstep(1.0f - edge, 1.0f, radial);

    // Real depth, so the sphere occludes rear particles instead of the whole scene.
    float zView = -cameraDistance + z * worldRadius;
    float zc = u.farPlane / (u.nearPlane - u.farPlane);

    CoreFragmentOut out;
    out.color = float4(shade, alpha);
    out.depth = saturate(zc * (zView + u.nearPlane) / max(-zView, 0.0001f));
    return out;
}
