import SwiftUI

/// A lightweight, celebratory particle burst effect for quota resets.
struct ConfettiView: View {
    let onFinished: () -> Void

    @State private var animate = false

    private struct Particle: Identifiable {
        let id = UUID()
        let color: Color
        let targetX: CGFloat
        let targetY: CGFloat
        let targetRotation: Double
        let scale: CGFloat
    }

    private let particles: [Particle] = {
        let colors: [Color] = [
            Palette.ample,
            Palette.watch,
            Color.cyan,
            Color.mint,
            Color.orange,
            Color.purple
        ]
        return (0..<32).map { _ in
            let angle = Double.random(in: 0...(2 * .pi))
            let distance = CGFloat.random(in: 40...140)
            return Particle(
                color: colors.randomElement() ?? Palette.ample,
                targetX: cos(angle) * distance,
                targetY: sin(angle) * distance + CGFloat.random(in: 20...60), // gentle gravity
                targetRotation: Double.random(in: 180...720),
                scale: CGFloat.random(in: 0.6...1.2)
            )
        }
    }()

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(p.color)
                    .frame(width: 7 * p.scale, height: 4 * p.scale)
                    .offset(x: animate ? p.targetX : 0, y: animate ? p.targetY : 0)
                    .rotationEffect(.degrees(animate ? p.targetRotation : 0))
                    .opacity(animate ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6)) {
                animate = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                onFinished()
            }
        }
    }
}
