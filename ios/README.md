# Native five-variant playground

Open VoiceOrbPlayground.xcodeproj and run the VoiceOrbPlayground scheme. Swipe beside the orb or tap a page dot to compare Current orb, Plasma interior, Refined glass, Plasma glass, and Flowing plasma glass. Dragging on the orb preserves its gesture interaction. Audio controls and colour selections are shared.

The Plasma shader includes activity-dependent colour churning and interleaving. Launch with -orbVariant 0, 1, 2, 3, or 4 to select an initial material. Actual touch interaction verification was previously blocked by simulator UI automation timeouts; a successful build is not a touch-test result.

# Quippy Voice Orb

A standalone interactive voice-orb prototype, with a browser preview and the native SwiftUI + Metal iPhone source.

## Browser preview

Run `npm start`, then open http://localhost:4173. There is no dependency installation or build step. Deploy the repository to Vercel using the included `vercel.json` (static output directory: `web`). Microphone input needs HTTPS or localhost. Audio is processed locally; no recordings are saved or uploaded.

- 2,000 particles, evenly split between two colours (1,000 each).
- Continuous idle ripple at 25% of tap force, synchronized with 3% inner-core breathing on a 4.8-second cycle.
- 1.5× dot size, soft colour-matched particle halos, and doubled edge feathering.
- Five-position colour sliders, darker particle shades, softened 500 pigments.
- Glassier upper-left reflection, thin luminous rim, reduced white haze, and colour swirling during speech.
- Inner core diameter is 65.025% of the nominal outer sphere diameter.
- A bundled synthetic sample, measured during playback using Web Audio.
- Live microphone response, tap ripple and drag rotation.
- Reduced-motion support.

The browser is a WebGL adaptation, not an execution of the Metal renderer. The shader colour field and lighting follow the native prototype. The browser gesture response uses a lightweight ripple and rotation; the native version includes the full particle spring simulation. Browser and native text-to-speech voices can differ.

## Run on an iPhone

1. Download the source ZIP or clone this repository on a Mac.
2. Open `VoiceOrbPlayground.xcodeproj` in Xcode.
3. Select the VoiceOrbPlayground app target → Signing & Capabilities. Enable automatic signing, select your Apple development team, and change the bundle identifier to one unique to you.
4. Connect and trust your iPhone. Select it as the run destination and enable Developer Mode if prompted.
5. Press Run. Use Play sample or Listen, and explore the two colour sliders.

The ZIP is source code, not an IPA or a TestFlight installation. Native device installation requires Xcode and development signing. Minimum deployment target is iOS 17. If Xcode reports a missing Metal toolchain, install the Metal Toolchain component through Xcode. The project is included; XcodeGen is only needed if you want to regenerate it from `project.yml`.

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

Flowing plasma glass is the first displayed option (originally fifth) that preserves the fourth material’s dimensions, lighting, halo, and particles. Only its interior changes: five overlapping colour regions drift independently through a gently swirling field, using shades of the selected two colours. Integrated phase and exponentially smoothed activity keep audio transitions continuous. The ten mixed-colour pairs use this original native/WebGL flow. The five matching-colour pairs and error state use the Paper mesh shader port described below.

The five same-colour choices now use a native port of Paper Shaders 0.0.76 mesh-gradient, with adjacent hues and VoiceOrbs motion settings. Preview error shows the reference rose-red palette and error movement; actual audio failures also activate it in variant five. Tap End error preview or choose a palette to leave the preview. See THIRD_PARTY_NOTICES.md for attribution and pixel-parity limits. The first four variants and the ten mixed-colour choices retain their existing materials.

The display order is Flowing plasma glass, Plasma interior, Refined glass, Plasma glass, Current orb. Only Flowing plasma glass uses the emotion palette: Joy #FFD83D, Sadness #3498DB, Disgust #78B84A, Fear #A878D1, Anger #EF3E36. Its 15 unordered pairs retain the existing flow and error animation. The other four materials retain their original palette.
