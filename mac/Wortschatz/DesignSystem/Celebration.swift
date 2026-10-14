import SwiftUI

/// A confetti burst for finished rounds and sets (spec §4.4 "celebration … particles, Reduce
/// Motion safe"). It plays when the view appears (if `playsOnAppear`) and whenever `trigger`
/// changes. Under Reduce Motion nothing flies: a soft accent glow fades in and out instead.
/// Purely decorative: no hit testing, hidden from VoiceOver.
///
/// ```swift
/// ResultsView().overlay { CelebrationView(trigger: finishedCount) }   // or .celebration(trigger:)
/// ```
struct CelebrationView: View {
    var trigger: Int = 0
    var playsOnAppear = true
    /// Where the burst starts, in unit coordinates of the view.
    var origin = UnitPoint(x: 0.5, y: 0.42)
    var particleCount = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshotRendering) private var isSnapshot
    @State private var burst: Burst?

    private struct Burst: Equatable {
        let start: Date
        let seed: UInt64
    }

    var body: some View {
        ZStack {
            if isSnapshot {
                // One representative frame for the snapshot harness.
                canvas(elapsed: 0.55, seed: 7)
            } else if let burst {
                if reduceMotion {
                    glow(start: burst.start)
                } else {
                    TimelineView(.animation) { context in
                        canvas(elapsed: context.date.timeIntervalSince(burst.start), seed: burst.seed)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if playsOnAppear { start(seed: UInt64(bitPattern: Int64(trigger)) &+ 1) }
        }
        .onChange(of: trigger) { _, new in
            start(seed: UInt64(bitPattern: Int64(new)) &+ 1)
        }
        .task(id: burst) {
            guard burst != nil else { return }
            try? await Task.sleep(for: .seconds(Confetti.duration + 0.1))
            if !Task.isCancelled { burst = nil }
        }
    }

    private func start(seed: UInt64) {
        burst = Burst(start: .now, seed: seed)
    }

    private func canvas(elapsed: TimeInterval, seed: UInt64) -> some View {
        Canvas { context, size in
            Confetti.draw(in: &context, size: size, origin: origin, elapsed: elapsed, seed: seed, count: particleCount)
        }
    }

    /// Reduce Motion: an opacity-only glow, no movement.
    private func glow(start: Date) -> some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            let opacity = t < 0.4 ? t / 0.4 : max(0, 1 - (t - 0.4) / 1.4)
            RadialGradient(
                colors: [Theme.accent.opacity(0.28), Theme.mastered.fill.opacity(0.10), .clear],
                center: origin,
                startRadius: 0,
                endRadius: 420
            )
            .opacity(opacity)
        }
    }
}

extension View {
    /// Overlays a `CelebrationView` (confetti burst, Reduce Motion safe).
    func celebration(trigger: Int = 0, playsOnAppear: Bool = true, origin: UnitPoint = UnitPoint(x: 0.5, y: 0.42)) -> some View {
        overlay {
            CelebrationView(trigger: trigger, playsOnAppear: playsOnAppear, origin: origin)
        }
    }
}

/// Deterministic confetti physics (closed form, so any frame can be drawn directly).
private nonisolated enum Confetti {
    static let duration: TimeInterval = 2.8
    static let gravity: Double = 980
    static let drag: Double = 1.6

    enum Shape { case ribbon, dot, sparkle }

    struct Particle {
        var angle: Double
        var speed: Double
        var width: Double
        var height: Double
        var spin: Double
        var flip: Double
        var phase: Double
        var colorIndex: Int
        var shape: Shape
    }

    static let colors: [Color] = [
        Theme.accent, Theme.mastered.fill, Theme.learning.fill, Theme.star,
        Color(hex: 0xFF6FA8), Color(hex: 0x2BB3C0), Color(hex: 0x9D6BFF),
    ]

    static func particles(seed: UInt64, count: Int) -> [Particle] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { i in
            let shapeRoll = rng.next()
            let shape: Shape = shapeRoll < 0.68 ? .ribbon : (shapeRoll < 0.9 ? .dot : .sparkle)
            let width = shape == .ribbon ? rng.next(in: 7...12) : rng.next(in: 5...9)
            return Particle(
                // Mostly upwards, fanned out to both sides.
                angle: -Double.pi / 2 + (rng.next() - 0.5) * Double.pi * 1.15,
                speed: rng.next(in: 420...980),
                width: width,
                height: shape == .ribbon ? width * rng.next(in: 0.38...0.6) : width,
                spin: rng.next(in: -7...7),
                flip: rng.next(in: 5...11),
                phase: rng.next(in: 0...(2 * Double.pi)),
                colorIndex: i % colors.count,
                shape: shape
            )
        }
    }

    static func draw(
        in context: inout GraphicsContext, size: CGSize, origin: UnitPoint,
        elapsed t: TimeInterval, seed: UInt64, count: Int
    ) {
        guard t >= 0, t <= duration else { return }
        let ox = origin.x * size.width
        let oy = origin.y * size.height
        // Integrated velocity with linear drag: v·(1 − e^(−k·t))/k, plus gravity.
        let travel = (1 - exp(-drag * t)) / drag
        let fade = t > duration - 0.7 ? max(0, (duration - t) / 0.7) : 1
        for particle in particles(seed: seed, count: count) {
            let x = ox + cos(particle.angle) * particle.speed * travel
            let y = oy + sin(particle.angle) * particle.speed * travel + 0.5 * gravity * t * t * 0.55
            guard y < size.height + 40 else { continue }
            var c = context
            c.opacity = fade
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(particle.phase + particle.spin * t))
            let color = colors[particle.colorIndex]
            switch particle.shape {
            case .ribbon:
                // Fake 3-D tumbling by squashing one axis.
                c.scaleBy(x: max(0.08, abs(cos(particle.phase + particle.flip * t))), y: 1)
                let rect = CGRect(x: -particle.width / 2, y: -particle.height / 2, width: particle.width, height: particle.height)
                c.fill(Path(roundedRect: rect, cornerRadius: particle.height * 0.3), with: .color(color))
            case .dot:
                let rect = CGRect(x: -particle.width / 2, y: -particle.width / 2, width: particle.width, height: particle.width)
                c.fill(Path(ellipseIn: rect), with: .color(color))
            case .sparkle:
                c.fill(sparkle(radius: particle.width * 0.8), with: .color(color))
            }
        }
    }

    /// Four-pointed star.
    static func sparkle(radius r: Double) -> Path {
        var path = Path()
        let inner = r * 0.32
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 - .pi / 2
            let radius = i.isMultiple(of: 2) ? r : inner
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Small deterministic generator for the confetti (independent of the app's `RNG`).
private nonisolated struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}
