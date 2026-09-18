export const noise = `float hash1(vec3 p) {
    p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float valueNoise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash1(i + vec3(0, 0, 0));
    float n100 = hash1(i + vec3(1, 0, 0));
    float n010 = hash1(i + vec3(0, 1, 0));
    float n110 = hash1(i + vec3(1, 1, 0));
    float n001 = hash1(i + vec3(0, 0, 1));
    float n101 = hash1(i + vec3(1, 0, 1));
    float n011 = hash1(i + vec3(0, 1, 1));
    float n111 = hash1(i + vec3(1, 1, 1));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z) * 2.0 - 1.0;
}

vec3 noiseField(vec3 p) {
    return vec3(valueNoise(p),
                  valueNoise(p + vec3(31.416, 17.137, 5.291)),
                  valueNoise(p - vec3(19.317, 47.711, 11.083)));
}

// Divergence-free flow so particles swirl instead of piling into sinks.
vec3 curlNoise(vec3 p) {
    const float e = 0.22;
    vec3 dx = vec3(e, 0.0, 0.0);
    vec3 dy = vec3(0.0, e, 0.0);
    vec3 dz = vec3(0.0, 0.0, e);

    vec3 px0 = noiseField(p - dx), px1 = noiseField(p + dx);
    vec3 py0 = noiseField(p - dy), py1 = noiseField(p + dy);
    vec3 pz0 = noiseField(p - dz), pz1 = noiseField(p + dz);

    float x = (py1.z - py0.z) - (pz1.y - pz0.y);
    float y = (pz1.x - pz0.x) - (px1.z - px0.z);
    float z = (px1.y - px0.y) - (py1.x - py0.x);
    return vec3(x, y, z) / (2.0 * e);
}

float fbm3(vec3 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; ++i) {
        sum += valueNoise(p) * amplitude;
        p *= 2.03;
        amplitude *= 0.5;
    }
    return sum;
}

`;
export const region = `vec3 coreRegionColor(vec3 n) {
    float t = coreMotionPhase;
    float tilt = sin(t * 0.37) * 0.28;
    vec3 axis = normalize(vec3(cos(t), sin(t), tilt));
    float activity = coreMotionIntensity;
    // Twist the coordinate field continuously so the two regions fold around
    // one another. No per-frame random values and no sudden phase changes.
    float swirl = max(activity - 0.12, 0.0);
    float twist = swirl * (n.y * 1.55 + sin(n.x * 2.2 + t * 0.8) * 0.50);
    float cs = cos(twist), sn = sin(twist);
    vec3 q = vec3(cs * n.x - sn * n.y, sn * n.x + cs * n.y, n.z);
    float warp = fbm3(q * coreWarpFrequency + vec3(t * 0.35, -t * 0.24, t * 0.6));
    float detail = valueNoise(q * 3.1 + vec3(-t * 0.7, t * 0.45, t));
    float field = dot(q, axis) + warp * coreWarpAmount * (1.0 + activity * 2.1)
                + detail * activity * 0.16;
    float feather = max(coreBoundarySoftness, 0.01);
    vec3 pigment = mix(coreColorA.rgb, coreColorB.rgb, smoothstep(-feather, feather, field));
    // Diffuse the exact 500 pigments through a softly lit material. The core
    // and halo share this tint; particles retain their darker raw swatches.
    return mix(pigment, vec3(1.0, 0.985, 0.965), 0.38);
}

`;
