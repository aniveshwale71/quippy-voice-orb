// Motion adapted from VoiceOrbs (MIT); mesh from Paper Shaders 0.0.76
// (PolyForm Shield). See licenses/ and THIRD_PARTY_NOTICES.md.
export const referenceMesh = `
// Port of @paper-design/shaders 0.0.76 mesh-gradient. PolyForm Shield 1.0.0.
// Original source and required terms: see THIRD_PARTY_NOTICES.md and Licenses/.
vec2 paperRotate(vec2 uv, float th) {
    return vec2(cos(th) * uv.x - sin(th) * uv.y, sin(th) * uv.x + cos(th) * uv.y);
}
float paperHash21(vec2 p) {
    p = fract(p * vec2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}
float paperValueNoise(vec2 st) {
  vec2 i = floor(st);
  vec2 f = fract(st);
  float a = paperHash21(i);
  float b = paperHash21(i + vec2(1.0, 0.0));
  float c = paperHash21(i + vec2(0.0, 1.0));
  float d = paperHash21(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  float x1 = mix(a, b, u.x);
  float x2 = mix(c, d, u.x);
  return mix(x1, x2, u.y);
}

float paperNoise(vec2 n, vec2 seedOffset) {
  return paperValueNoise(n + seedOffset);
}

vec2 paperGetPosition(int i, float t) {
  float a = float(i) * .37;
  float b = .6 + fract(float(i) / 3.) * .9;
  float c = .8 + fract(float(i + 1) / 4.);

  float x = sin(t * b + a);
  float y = cos(t * c + a * 1.5);

  return .5 + .5 * vec2(x, y);
}

vec3 referenceMeshColor(vec3 n) {
  float e = meshError;
  vec3 from = mix(coreColorA, vec3(251.0, 113.0, 133.0) / 255.0, e);
  vec3 to = mix(meshPaletteTo.rgb, vec3(244.0, 63.0, 94.0) / 255.0, e);
  vec4 colors[5] = vec4[5](
    vec4(round(from * 0.65 * 255.0) / 255.0, 1.0), vec4(from, 1.0),
    vec4(round(mix(from, to, 0.5) * 255.0) / 255.0, 1.0), vec4(to, 1.0),
    vec4(round(mix(to, vec3(1.0), 0.35) * 255.0) / 255.0, 1.0)
  );

  vec2 uv = (n.xy * 0.5 / 1.15);
  uv += .5;
  vec2 grainUV = uv * 1000.;

  float grain = paperNoise(grainUV, vec2(0.));
  float mixerGrain = .4 * meshMotion.w * (grain - .5);

  const float firstFrameOffset = 41.5;
  float t = .5 * (meshMotion.x + firstFrameOffset);

  float radius = smoothstep(0., 1., length(uv - .5));
  float center = 1. - radius;
  for (float i = 1.; i <= 2.; i++) {
    uv.x += meshMotion.y * center / i * sin(t + i * .4 * smoothstep(.0, 1., uv.y)) * cos(.2 * t + i * 2.4 * smoothstep(.0, 1., uv.y));
    uv.y += meshMotion.y * center / i * cos(t + i * 2. * smoothstep(.0, 1., uv.x));
  }

  vec2 uvRotated = uv;
  uvRotated -= vec2(.5);
  float angle = 3. * meshMotion.z * radius;
  uvRotated = paperRotate(uvRotated, -angle);
  uvRotated += vec2(.5);

  vec3 color = vec3(0.);
  float opacity = 0.;
  float totalWeight = 0.;

  for (int i = 0; i < 5; i++) {
    if (i >= int(5)) break;

    vec2 pos = paperGetPosition(i, t) + mixerGrain;
    vec3 colorFraction = colors[i].rgb * colors[i].a;
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

  float grainOverlay = paperValueNoise(paperRotate(grainUV, 1.) + vec2(3.));
  grainOverlay = mix(grainOverlay, paperValueNoise(paperRotate(grainUV, 2.) + vec2(-1.)), .5);
  grainOverlay = pow(grainOverlay, 1.3);

  float grainOverlayV = grainOverlay * 2. - 1.;
  vec3 grainOverlayColor = vec3(step(0., grainOverlayV));
  float grainOverlayStrength = 0.05 * abs(grainOverlayV);
  grainOverlayStrength = pow(grainOverlayStrength, .8);
  color = mix(color, grainOverlayColor, .35 * grainOverlayStrength);

  opacity += .5 * grainOverlayStrength;
  opacity = clamp(opacity, 0., 1.);

  return color;
}

`;
export class ReferenceMotion {
  time=8; distortion=.42; swirl=.26; grain=.06; errorMix=0;
  energy=0; smoothDistortion=.42; smoothSwirl=.26; smoothSpeed=.3;
  smoothGrain=.06; smoothError=0; speed=.3; sincePush=0;
  update(dt,state,level,error,reduced){
    dt=Math.min(Math.max(dt,0),.1);
    const approach=(a,b,rate)=>a+(b-a)*(1-Math.exp(-rate*dt));
    this.energy=approach(this.energy,error?.2:state==='idle'?0:Math.max(0,Math.min(1,level)),7.5);
    const active=state==='listening'||state==='speaking';
    const distortion=error?.85:active?Math.min(1,.5+this.energy*.4):.42;
    const swirl=error?.55:active?Math.min(1,.3+this.energy*.25):.26;
    const speed=error?1.8:state==='listening'?1.6:state==='speaking'?1.1:.3;
    const grain=error?.2:state==='listening'?.16:state==='speaking'?.18:.06;
    this.smoothDistortion=approach(this.smoothDistortion,distortion,6);
    this.smoothSwirl=approach(this.smoothSwirl,swirl,6);
    this.smoothSpeed=approach(this.smoothSpeed,speed,5);
    this.smoothGrain=approach(this.smoothGrain,grain,6);
    this.smoothError=approach(this.smoothError,error?1:0,6);
    if(!reduced)this.time+=dt*this.speed;
    this.sincePush+=dt;
    if(reduced){this.time=8;this.distortion=distortion;this.swirl=swirl;this.grain=grain;this.errorMix=error?1:0;}
    else if(this.sincePush>.066){
      this.sincePush=0;
      this.distortion=Math.round(this.smoothDistortion*100)/100;
      this.swirl=Math.round(this.smoothSwirl*100)/100;
      this.speed=Math.round(this.smoothSpeed*100)/100;
      this.grain=Math.round(this.smoothGrain*200)/200;
      this.errorMix=Math.round(this.smoothError*100)/100;
    }
  }
}
