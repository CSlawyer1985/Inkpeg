import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    // Preserve the rope/card layout and room for transient intake feedback.
    static let ropeTop: CGFloat = LineInputLayout.controlHeight
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                let region = LineInputLayout.region(width: width)
                LineInputView(line: line)
                    .frame(width: region.width, height: region.height)
                    .position(x: region.midX, y: region.midY)

                if line.items.isEmpty {
                    Hint()
                        .allowsHitTesting(false)
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let x = Layout.x(index: index, count: line.items.count, width: width)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
                // Keep the small settings cue visible as cards sway across
                // the rope. This stroke adds no hit area over the cards.
                let settings = LineInputLayout.settingsStroke(width: width)
                LineRopeGeometry.path(width: width, from: settings.lowerBound, to: settings.upperBound)
                    .stroke(Color(nsColor: .systemRed), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .allowsHitTesting(false)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct Hint: View {
    var body: some View {
        Text(L(.emptyHint))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        LineRopeGeometry.path(width: width, from: -20, to: width + 20)
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

/// The real rope extends 20 points past each edge. Both its neutral stroke and
/// the red settings segment use this same quadratic, including during reveal.
enum LineRopeGeometry {
    static func y(x: CGFloat, width: CGFloat) -> CGFloat {
        let f = (x + 20) / (max(0, width) + 40)
        return Layout.ropeTop + 4 * Layout.sag(width: width) * f * (1 - f)
    }
    static func path(width: CGFloat, from start: CGFloat, to end: CGFloat) -> Path {
        let first = CGPoint(x: start, y: y(x: start, width: width))
        let last = CGPoint(x: end, y: y(x: end, width: width))
        let middleX = (start + end) / 2
        let controlY = 2 * y(x: middleX, width: width) - (first.y + last.y) / 2
        return Path { p in
            p.move(to: first)
            p.addQuadCurve(to: last, control: CGPoint(x: middleX, y: controlY))
        }
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
