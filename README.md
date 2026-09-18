# Quippy Voice Orb

A standalone interactive voice-orb prototype, with a browser preview and the native SwiftUI + Metal iPhone source.

## Browser preview

Run `npm start`, then open http://localhost:4173. There is no dependency installation or build step. Deploy the repository to Vercel using the included `vercel.json` (static output directory: `web`). Microphone input needs HTTPS or localhost. Audio is processed locally; no recordings are saved or uploaded.

- 1,600 particles, evenly split between two colours.
- 1.5× dot size, soft colour-matched particle halos, and doubled edge feathering.
- Five-position colour sliders, darker particle shades, softened 500 pigments.
- White glow, angled lighting, more colour swirling during speech.
- A bundled synthetic sample, measured during playback using Web Audio.
- Live microphone response, tap ripple and drag rotation.
- Reduced-motion support.

The browser is a WebGL adaptation, not an execution of the Metal renderer. The shader colour field and lighting follow the native prototype. The browser gesture response uses a lightweight ripple and rotation; the native version includes the full particle spring simulation. Browser and native text-to-speech voices can differ.

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
| Inner core diameter before feathering | 164.20896 | 492.62688 |

The nominal shell is 62.9% of the canvas; the core is 44.4%. Raster dimensions round to whole pixels. Perspective, shell thickness, stray particles, gestures and speech alter the visible outer bounds; there is no single exact visible diameter for an animated cloud. Glow and edge feathering also have gradual boundaries. Browser measurements are shown in the preview's Dimensions disclosure.

## Source layout

- `web/`: dependency-free browser preview and downloadable native source.
- `ios/Sources/Orb/`: reusable native orb component.
- `ios/Shaders/`: Metal rendering and particle simulation.
- `ios/Sources/Audio/`: native sample generation, playback and microphone metering.
- `ios/Sources/App/`: prototype controls.
- `ios/Tests/`: native audio and component tests.

This package includes only the standalone orb, not the Quippy production app or backend.
