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

    // A smooth outward / inward surface wave shares the core's breathing phase.
    // Use the same Gaussian band and spring response as taps, at one quarter of their force.
    float idleArc = acos(clamp(dot(dir, float3(0.0f, 0.0f, 1.0f)), -1.0f, 1.0f));
    float breath = 0.5f - 0.5f * cos(u.idleMotion.x);
    float idleOffset = (idleArc - M_PI_F * breath) / u.rippleWidth;
    float idleBand = exp(-idleOffset * idleOffset);
    float3 idleAway = surfaceAwayDirection(dir, float3(0.0f, 0.0f, 1.0f));
    float3 idleAwayWorld = (u.spin * float4(idleAway, 0.0f)).xyz;
    force += (outward + idleAwayWorld * 0.35f) * u.idleMotion.y * idleBand;

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
    // Stable IDs preserve an exact 50/50 split for the default 2000 dots.
    float3 tint = (id & 1u) == 0u ? u.particleColorA.rgb : u.particleColorB.rgb;
    if (u.idleMotion.w > 3.5f) {
        float3 errorTint = (id & 1u) == 0u ? float3(251, 113, 133) / 255.0f : float3(244, 63, 94) / 255.0f;
        tint = mix(tint, errorTint * 0.8f, u.meshError.x);
    }
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
    // Half the previous transition width again, retaining the outer dot radius.
    float featherWidth = 0.5f * (0.27f - max(0.25f - edge, 0.10f));
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

// Original native interpretation of the VoiceOrbs Plasma visual reference.
// Smooth advected colour lobes, rather than a rotating two-region boundary.
// `coreMotionIntensity` already ramps with state (idle/listening/speaking)
// and live audio elsewhere in the pipeline; here it also feeds the mixing
// itself, not just its speed, so speaking reads as the two pigments actively
// churning and interleaving rather than the same pattern spinning faster.
static float3 plasmaColor(float3 n, constant OrbUniforms &u) {
    float t = u.coreMotionPhase * 1.8f;
    float activity = clamp(u.coreMotionIntensity, 0.0f, 1.5f);
    float churn = 0.30f + activity * 0.55f;
    float3 q = n;
    q.xy += churn * float2(sin(n.y * 2.7f + t), cos(n.x * 2.3f - t * 0.73f));
    float a = sin(q.x * 2.5f + q.y * 1.4f + t * 0.64f);
    float b = cos(q.y * 2.8f - q.z * 1.8f - t * 0.53f);
    float c = sin((q.x - q.y) * 2.0f + t * 0.37f);
    // A faster fourth lobe fades in with activity, breaking the boundary into
    // extra interleaved patches instead of one smooth flowing seam.
    float d = sin(q.x * 4.1f - q.y * 3.3f + t * 1.7f) * activity;
    float mixField = a * 0.52f + b * 0.42f + c * 0.30f + d * 0.34f;
    float blend = smoothstep(-0.85f, 0.85f, mixField);
    float3 pigment = mix(u.coreColorA.rgb, u.coreColorB.rgb, blend);
    float luminous = 0.16f + 0.13f * (0.5f + 0.5f * sin(q.x * 2.0f + q.y * 3.0f - t));
    return mix(pigment, float3(1.0f, 0.99f, 0.98f), luminous);
}

// Fifth material only: continuous overlapping colour regions, not a rotating texture.
static float3 flowingPlasmaColor(float3 n, constant OrbUniforms &u) {

    float t = u.coreMotionPhase * 2.4;
    float energy = clamp(u.coreMotionIntensity, 0.0, 1.5) / 1.5;
    float2 q = n.xy;
    q += (0.16 + energy * 0.18) * float2(
        sin(q.y * 2.2 + t * 0.63), cos(q.x * 2.0 - t * 0.57));
    float twist = 0.32 * sin(t * 0.31 + dot(q, q) * 1.8);
    q = float2(cos(twist) * q.x - sin(twist) * q.y,
             sin(twist) * q.x + cos(twist) * q.y);
    float3 total = float3(0.0);
    float weights = 0.0;
    for (int i = 0; i < 5; ++i) {
        float k = float(i);
        float angle = k * 1.25663706;
        float2 center = float2(cos(angle), sin(angle)) * 0.72;
        center += 0.34 * float2(sin(t * (0.47 + k * 0.035) + k * 2.1),
                              cos(t * (0.39 + k * 0.027) + k * 1.7));
        float2 delta = q - center;
        float weight = exp(-3.6 * dot(delta, delta));
        float3 pigment = i == 0 ? u.coreColorA.rgb * 0.85
                     : i == 1 ? u.coreColorA.rgb
                     : i == 2 ? mix(u.coreColorA.rgb, u.coreColorB.rgb, 0.5)
                     : i == 3 ? u.coreColorB.rgb : mix(u.coreColorB.rgb, float3(1.0), 0.18);
        total += pigment * weight;
        weights += weight;
    }
    return mix(total / max(weights, 0.0001), float3(1.0, 0.99, 0.98), 0.11);
}

// Port of @paper-design/shaders 0.0.76 mesh-gradient. PolyForm Shield 1.0.0.
// Original source and required terms: see THIRD_PARTY_NOTICES.md and Licenses/.
static float2 paperRotate(float2 uv, float th) {
    return float2(cos(th) * uv.x - sin(th) * uv.y, sin(th) * uv.x + cos(th) * uv.y);
}
static float paperHash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}
float paperValueNoise(float2 st) {
  float2 i = floor(st);
  float2 f = fract(st);
  float a = paperHash21(i);
  float b = paperHash21(i + float2(1.0, 0.0));
  float c = paperHash21(i + float2(0.0, 1.0));
  float d = paperHash21(i + float2(1.0, 1.0));
  float2 u = f * f * (3.0 - 2.0 * f);
  float x1 = mix(a, b, u.x);
  float x2 = mix(c, d, u.x);
  return mix(x1, x2, u.y);
}

float paperNoise(float2 n, float2 seedOffset) {
  return paperValueNoise(n + seedOffset);
}

float2 paperGetPosition(int i, float t) {
  float a = float(i) * .37;
  float b = .6 + fract(float(i) / 3.) * .9;
  float c = .8 + fract(float(i + 1) / 4.);

  float x = sin(t * b + a);
  float y = cos(t * c + a * 1.5);

  return .5 + .5 * float2(x, y);
}

static float3 referenceMeshColor(float3 n, constant OrbUniforms &u) {
  float e = u.meshError.x;
  float3 from = mix(u.coreColorA.rgb, float3(251.0, 113.0, 133.0) / 255.0, e);
  float3 to = mix(u.meshPaletteTo.rgb, float3(244.0, 63.0, 94.0) / 255.0, e);
  float4 colors[5] = {
    float4(round(from * 0.65 * 255.0) / 255.0, 1.0), float4(from, 1.0),
    float4(round(mix(from, to, 0.5) * 255.0) / 255.0, 1.0), float4(to, 1.0),
    float4(round(mix(to, float3(1.0), 0.35) * 255.0) / 255.0, 1.0)
  };

  float2 uv = (n.xy * 0.5 / 1.15);
  uv += .5;
  float2 grainUV = uv * 1000.;

  float grain = paperNoise(grainUV, float2(0.));
  float mixerGrain = .4 * u.meshMotion.w * (grain - .5);

  const float firstFrameOffset = 41.5;
  float t = .5 * (u.meshMotion.x + firstFrameOffset);

  float radius = smoothstep(0., 1., length(uv - .5));
  float center = 1. - radius;
  for (float i = 1.; i <= 2.; i++) {
    uv.x += u.meshMotion.y * center / i * sin(t + i * .4 * smoothstep(.0, 1., uv.y)) * cos(.2 * t + i * 2.4 * smoothstep(.0, 1., uv.y));
    uv.y += u.meshMotion.y * center / i * cos(t + i * 2. * smoothstep(.0, 1., uv.x));
  }

  float2 uvRotated = uv;
  uvRotated -= float2(.5);
  float angle = 3. * u.meshMotion.z * radius;
  uvRotated = paperRotate(uvRotated, -angle);
  uvRotated += float2(.5);

  float3 color = float3(0.);
  float opacity = 0.;
  float totalWeight = 0.;

  for (int i = 0; i < 5; i++) {
    if (i >= int(5)) break;

    float2 pos = paperGetPosition(i, t) + mixerGrain;
    float3 colorFraction = colors[i].rgb * colors[i].a;
    float opacityFraction = colors[i].a;

    float dist = length(uvRotated - pos);

    dist = pow(dist, 3.5);
    float weight = 1. / (dist + 1e-3);
    color += colorFraction * weight;
    opacity += opacityFraction * weight;
    totalWeight += weight;
  }

  color /= max(1e-4, totalWeight);
  opacity /= max(1e-4, totalWeight);

  float grainOverlay = paperValueNoise(paperRotate(grainUV, 1.) + float2(3.));
  grainOverlay = mix(grainOverlay, paperValueNoise(paperRotate(grainUV, 2.) + float2(-1.)), .5);
  grainOverlay = pow(grainOverlay, 1.3);

  float grainOverlayV = grainOverlay * 2. - 1.;
  float3 grainOverlayColor = float3(step(0., grainOverlayV));
  float grainOverlayStrength = 0.05 * abs(grainOverlayV);
  grainOverlayStrength = pow(grainOverlayStrength, .8);
  color = mix(color, grainOverlayColor, .35 * grainOverlayStrength);

  opacity += .5 * grainOverlayStrength;
  opacity = clamp(opacity, 0., 1.);

  return color;
}

fragment float4 orbGlowFragment(CoreVertexOut in [[stage_in]],
                                constant OrbUniforms &u [[buffer(0)]]) {
    float worldRadius = u.orbRadius * u.coreRadiusRatio * u.idleMotion.z * (1.0f + clamp(u.audioLevel, 0.0f, 1.0f) * u.coreAudioGain);
    float ndcRadius = worldRadius / length(u.cameraPosition.xyz) / u.tanHalfFov;
    float2 p = float2(in.uv.x * u.aspect, in.uv.y) / max(ndcRadius, 0.0001f);
    float radius = length(p);
    if (radius > 1.65f) { discard_fragment(); }
    if (u.idleMotion.w > 0.5f) {
        float3 n = normalize(float3(p, 0.55f));
        float glassBlend = u.idleMotion.w > 2.5f ? 0.5f : (u.idleMotion.w < 1.5f ? 0.0f : 1.0f);
        float3 tint = mix(plasmaColor(n, u), coreRegionColor(n, u), glassBlend);
        if (u.meshPaletteTo.w > 0.5f) { tint = referenceMeshColor(n, u); }
        float width = mix(0.24f, 0.32f, glassBlend);
        float halo = exp(-pow((radius - 0.94f) / width, 2.0f));
        float alpha = halo * (0.18f + u.audioLevel * 0.025f)
                    * (1.0f - smoothstep(1.35f, 1.65f, radius));
        return float4(tint, alpha);
    }
    // White bloom, independent of the selected emotion pigments.
    float3 tint = float3(1.0f);
    float falloff = exp(-pow(max(radius - 0.76f, 0.0f) / 0.43f, 2.0f));
    float alpha = falloff * (0.34f + u.audioLevel * 0.06f)
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
    float worldRadius = u.orbRadius * u.coreRadiusRatio * u.idleMotion.z * (1.0f + audio * u.coreAudioGain);
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
    float3 shade = base * mix(u.coreAmbient - 0.08f, 1.0f, wrapped);

    // Broad transmitted light gives a rounded highlight without a glossy hotspot.
    float3 halfway = normalize(lightDir + float3(0.0f, 0.0f, 1.0f));
    float ndoth = saturate(dot(n, halfway));
    // Bevel-inspired broad softbox: a pale, hue-tinted light pool, not
    // a clipped specular spot. Both colour regions receive the same lighting.
    float diffusion = pow(ndoth, 3.5f) * 0.48f + (1.0f - r2) * 0.04f;
    float3 transmittedLight = mix(base, float3(1.0f), 0.52f);
    shade = mix(shade, transmittedLight, diffusion);
    shade += base * pow(ndoth, 6.0f) * u.coreSpecular;

    // A softbox reflection sits on the upper-left surface, with a smaller
    // glossy centre so the lighting reads as glass rather than white fog.
    float reflection = 0.30f * pow(ndoth, 24.0f) + 0.16f * pow(ndoth, 72.0f);
    shade = mix(shade, float3(1.0f, 0.995f, 0.985f), reflection);
    float opposite = pow(saturate(-ndotl), 1.5f);
    shade *= 1.0f - opposite * 0.10f;

    // Modest grazing light balances gentle edge shading: enough depth to read
    // as a sphere, without the original hard, dark silhouette.
    float rim = pow(1.0f - z, 2.0f);
    // Let the white bloom scatter just inside the surface as well.
    shade = mix(shade, float3(1.0f), rim * 0.08f);
    // Narrow luminous rim follows the curved surface, strongest near the light.
    float rimBand = exp(-pow((sqrt(r2) - 0.91f) / 0.035f, 2.0f));
    float rimLight = 0.08f + 0.16f * saturate(ndotl);
    shade = mix(shade, float3(1.0f), rimBand * rimLight);
    shade *= mix(1.0f - u.coreEdgeDarkening, 1.0f, sqrt(z));

    if (u.idleMotion.w > 0.5f) {
        // The fourth material sits halfway between the two existing interiors.
        float glassBlend = u.idleMotion.w > 2.5f ? 0.5f : (u.idleMotion.w < 1.5f ? 0.0f : 1.0f);
        float3 pigment = u.idleMotion.w > 3.5f
            ? (u.meshPaletteTo.w > 0.5f ? referenceMeshColor(n, u) : flowingPlasmaColor(n, u))
            : mix(plasmaColor(n, u), base, glassBlend);
        // Broad reflection and a smaller soft highlight convey a curved surface.
        float lighting = mix(mix(0.69f, 0.72f, glassBlend), 1.0f, wrapped);
        shade = pigment * lighting;
        float softbox = pow(ndoth, 19.0f) * mix(0.27f, 0.43f, glassBlend)
                      + pow(ndoth, 65.0f) * mix(0.10f, 0.18f, glassBlend);
        shade = mix(shade, float3(1.0f, 0.995f, 0.985f), softbox);
        shade *= 1.0f - opposite * 0.13f;
        // Colour-bearing grazing light, without a white contour stripe.
        float grazing = pow(1.0f - z, 3.0f) * (0.035f + 0.06f * saturate(ndotl));
        shade += pigment * grazing;
    }

    // A small diffuse silhouette roll-off is resolved analytically, not via
    // a full-view blur that would soften the outer particles as well.
    float radial = sqrt(r2);
    float edge = max(fwidth(radial) * 1.5f, u.idleMotion.w > 0.5f ? 0.018f : 0.14f);
    float alpha = 1.0f - smoothstep(1.0f - edge, 1.0f, radial);

    // Real depth, so the sphere occludes rear particles instead of the whole scene.
    float zView = -cameraDistance + z * worldRadius;
    float zc = u.farPlane / (u.nearPlane - u.farPlane);

    CoreFragmentOut out;
    out.color = float4(shade, alpha);
    out.depth = saturate(zc * (zView + u.nearPlane) / max(-zView, 0.0001f));
    return out;
}
