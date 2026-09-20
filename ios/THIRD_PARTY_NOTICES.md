# Reference plasma attribution

The native reference mesh in `Shaders/Orb.metal` is adapted from Paper Design Shaders 0.0.76, `packages/shaders/src/shaders/mesh-gradient.ts`, its vertex UV sizing and shader helpers.

Source: https://github.com/paper-design/shaders
Published package: https://www.npmjs.com/package/@paper-design/shaders/v/0.0.76
Terms: [PolyForm Shield 1.0.0](Licenses/Paper-Shaders.txt).

The state coefficients, palette construction and smoothing in `ReferencePlasmaMotion` are adapted from VoiceOrbs PlasmaOrb (MIT): https://github.com/amunozdev/voiceorbs/blob/main/src/registry/orbe/plasma-orb/plasma-orb.tsx . See [MIT notice](Licenses/VoiceOrbs.txt).

Only variant five’s matching-colour pairs and error state use the reference mesh. The existing glass lighting, spherical clipping, outer particles and live audio input remain native. Mathematical motion and state targets follow the reference; GPU precision, frame scheduling, palette and the retained glass lighting can affect the final pixels. The ten mixed-colour options retain the previous native flow. The browser preview implements the same reference mesh and state coefficients. Native and browser particle and gesture simulations remain different.
