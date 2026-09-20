# Quippy Voice Orb

A standalone interactive voice-orb prototype, with a browser preview and the native SwiftUI + Metal iPhone source.

## Browser preview

Run `npm start`, then open http://localhost:4173. There is no dependency installation or build step. Deploy the repository to Vercel using the included `vercel.json` (static output directory: `web`). Microphone input needs HTTPS or localhost. Audio is processed locally; no recordings are saved or uploaded.

- 2,000 particles, evenly split between two colours.
- 1.5× dot size, soft colour-matched particle halos, and doubled edge feathering.
- Five-position colour sliders, darker particle shades, softened 500 pigments.
- Glassier upper-left reflection, thin luminous rim, reduced white haze, and colour swirling during speech.
- Inner core diameter is 65.025% of the nominal outer sphere diameter.
- A bundled synthetic sample, measured during playback using Web Audio.
- Live microphone response, tap ripple and drag rotation.
- Synchronized idle breathing (3% expansion) and a continuous surface ripple.
- Reduced-motion support.

The browser is a WebGL adaptation, not an execution of the Metal renderer. The shader colour field and lighting follow the native prototype. The browser gesture response uses a lightweight ripple and rotation; the native version includes the full particle spring simulation. Browser and native text-to-speech voices can differ.

## Five variants

Use the page dots or swipe beside the orb to compare Current orb, Plasma interior, Refined glass, Plasma glass, and Flowing plasma glass. Dragging on the orb keeps its rotation interaction. Audio controls are shared. Variants 1–4 use two colour sliders; variant five has its own 15-pair grid including five matching-colour choices.

The Plasma interior includes the latest native update: audio/state activity increases colour deformation and introduces additional interleaved colour patches. Refined glass keeps the original colour field with clearer reflections, a defined contour, and a separate tinted halo. The Plasma material is an original native interpretation of the VoiceOrbs reference, not a literal port of its shader.

The browser implements the corresponding material formulas in WebGL. Native and browser gesture simulations remain different as described above.

## Latest native version

The iOS source and downloadable ZIP include 2,000 particles (1,000 per colour), a continuous idle ripple at 25% of tap force, and synchronized 3% core breathing over 4.8 seconds. The browser preview includes matching 4.8-second breathing and a gentler idle surface ripple, using its lightweight displacement model. Automatic Git deployments to Vercel are disabled; publishing remains an explicit step.

## Run on an iPhone

1. Download the source ZIP or clone this repository on a Mac.
2. Open `ios/VoiceOrbPlayground.xcodeproj` in Xcode.
3. Select the VoiceOrbPlayground app target → Signing & Capabilities. Enable automatic signing, select your Apple development team, and change the bundle identifier to one unique to you.
4. Connect and trust your iPhone. Select it as the run destination and enable Developer Mode if prompted.
5. Press Run. Use Play sample or Listen, and explore the two colour sliders.

The ZIP is source code, not an IPA or a TestFlight installation. Native device installation requires Xcode and development signing. Minimum deployment target is iOS 17. If Xcode reports a missing Metal toolchain, install the Metal Toolchain component through Xcode. The project is included; XcodeGen is only needed if you want to regenerate it from `ios/project.yml`.

Apple instructions: [run on a device](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html) · [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/).

## Native dimensions

The orb is responsive, not a fixed-size asset. The host uses a square canvas equal to `0.92 × min(available width, available height)`.

On the current iPhone 17 Pro simulator (402 × 874 logical points), with sufficient vertical space:

| Measure | Points | @3× pixels |
|---|---:|---:|
| Square rendering canvas | 369.84 × 369.84 | 1109.52 × 1109.52 |
| Nominal outer particle diameter | 232.62936 | 697.88808 |
| Inner core diameter before feathering | 151.26724134 | 453.80172402 |

The nominal shell is 62.9% of the canvas; the core is 40.900725%. Raster dimensions round to whole pixels. Perspective, shell thickness, stray particles, gestures and speech alter the visible outer bounds; there is no single exact visible diameter for an animated cloud. Glow and edge feathering also have gradual boundaries. Browser measurements are shown in the preview's Dimensions disclosure.

## Source layout

- `web/`: dependency-free browser preview and downloadable native source.
- `ios/Sources/Orb/`: reusable native orb component.
- `ios/Shaders/`: Metal rendering and particle simulation.
- `ios/Sources/Audio/`: native sample generation, playback and microphone metering.
- `ios/Sources/App/`: prototype controls.
- `ios/Tests/`: native audio and component tests.

This package includes only the standalone orb, not the Quippy production app or backend.

Plasma glass blends the plasma and refined-glass colour fields equally, with midpoint reflection strength and halo width. All five materials share the existing particle, gesture, and audio controls.

Flowing plasma glass is a fifth option that preserves the fourth material’s dimensions, lighting, halo, and particles. Only its interior changes: five overlapping colour regions drift independently through a gently swirling field, using shades of the selected two colours. Integrated phase and exponentially smoothed activity keep audio transitions continuous. The ten mixed-colour pairs use this original native/WebGL flow. The five matching-colour pairs and error state use the Paper mesh shader port described below.

## Variant five: latest controls

Choose one of 15 unordered colour pairs, including the five matching-colour choices. Matching-colour pairs use neighbouring hues and the Paper Shaders 0.0.76 mesh motion with VoiceOrbs timing. Preview error shows the rose-red error palette; End error preview restores the selected pair. Audio failures also show the error material. Native playback restores the audio session on every play attempt, and the iOS playground keeps a readable light appearance.

The web demo runs directly in iPhone Safari. The downloadable ZIP contains the full Xcode source project, tests, and shader licence notices; it requires a Mac, Xcode and development signing to install natively. It is not an IPA or TestFlight link. See [third-party notices](ios/THIRD_PARTY_NOTICES.md).
