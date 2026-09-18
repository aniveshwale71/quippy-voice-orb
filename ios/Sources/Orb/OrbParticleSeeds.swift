import simd

/// Builds the orb's particle identities exactly once, from a fixed seed.
/// Nothing in the render loop may call this.
enum OrbParticleSeeds {

    static func make(configuration: OrbConfiguration) -> [OrbParticleSeed] {
        let count = max(configuration.particleCount, 1)
        var rng = SeededGenerator(seed: configuration.particleSeed)
        var seeds: [OrbParticleSeed] = []
        seeds.reserveCapacity(count)

        // A Fibonacci lattice gives even coverage with no polar pinching; the
        // jitter breaks up the spiral so it reads as organic rather than woven.
        let golden = Float.pi * (3.0 - sqrt(5.0))

        for i in 0..<count {
            let t = (Float(i) + 0.5) / Float(count)
            let y = 1 - 2 * t
            let r = sqrt(max(0, 1 - y * y))
            let theta = golden * Float(i)

            var direction = SIMD3<Float>(cos(theta) * r, y, sin(theta) * r)
            let jitter = SIMD3<Float>(rng.float(in: -1...1), rng.float(in: -1...1), rng.float(in: -1...1))
            direction = normalize(direction + jitter * 0.055)

            let isStray = rng.unitFloat() < configuration.strayFraction
            let shell = 1 + rng.float(in: -1...1) * configuration.shellThickness
            // Strays sit outside the shell but still inside `maxRadius`, so the
            // renderer never has to haul them back in.
            let radiusScale = isStray ? shell + rng.float(in: 0.04...0.12) : shell

            // Stray particles read as fainter specks, not as a second sphere.
            let sizeScale = isStray
                ? rng.float(in: 0.55...0.95)
                : rng.float(in: 0.62...1.55)

            seeds.append(
                OrbParticleSeed(
                    base: SIMD4(direction, rng.unitFloat()),
                    params: SIMD4(radiusScale, sizeScale, rng.float(in: 0...50), isStray ? 1 : 0)
                )
            )
        }

        return seeds
    }
}
