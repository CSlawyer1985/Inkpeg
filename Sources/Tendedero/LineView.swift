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

/// Production follows the system preference; tests/previews may inject only
/// this view value, without writing UserDefaults or changing macOS settings.
private struct ShelfReduceMotionOverride: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    var shelfReduceMotionOverride: Bool? {
        get { self[ShelfReduceMotionOverride.self] }
        set { self[ShelfReduceMotionOverride.self] = newValue }
    }
}
enum ShelfMotion {
    static func animation(reduceMotion: Bool, normal: Animation) -> Animation? { reduceMotion ? nil : normal }
}

struct LineView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shelfReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
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

                if line.showsEntryHint {
                    Text(L(.redRopeEntryHint))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: PanelAppearance.forest))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(nsColor: PanelAppearance.paper), in: RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false)
                        .position(x: min(width - 140, max(140, LineInputLayout.settingsRegion(width: width).midX)), y: 12)
                }
                if line.items.isEmpty && !line.snapshot.privacyHidden {
                    Hint()
                        .allowsHitTesting(false)
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                if !line.snapshot.privacyHidden {
                    ForEach(line.presentedIndices(width: width).map { (index: $0, item: line.items[$0]) }, id: \.item.id) { index, item in
                        let x = line.cardX(index: index, width: width)
                        let ropeY = Layout.ropeY(x: min(width, max(0, x)), width: width)
                        PeggedView(item: item, line: line)
                            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                            .accessibilityHidden(x < 0 || x > width)
                    }
                }
                if line.maximumScrollOffset > 0 {
                    HStack(spacing: 14) {
                        Button { line.scrollPage(forward: false) } label: { Image(systemName: "chevron.left") }
                            .disabled(line.scrollOffset <= 0).accessibilityLabel(L(.shelfPrevious))
                        Text("\(line.items.count)").font(.system(size: 11).monospacedDigit())
                        Button { line.scrollPage(forward: true) } label: { Image(systemName: "chevron.right") }
                            .disabled(line.scrollOffset >= line.maximumScrollOffset).accessibilityLabel(L(.shelfNext))
                    }
                    .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: width / 2, y: Layout.panelHeight - 15)
                }
                // Keep the small settings cue visible as cards sway across
                // the rope. This stroke adds no hit area over the cards.
                let settings = LineInputLayout.settingsStroke(width: width)
                LineRopeGeometry.path(width: width, from: settings.lowerBound, to: settings.upperBound)
                    .stroke(Color(nsColor: .systemRed), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .allowsHitTesting(false)
            }
            .clipped()
            .transaction { if line.snapshot.privacyHidden { $0.disablesAnimations = true; $0.animation = nil } }
            .onAppear { line.resizeViewport(width) }
            .onChange(of: width) { _, newWidth in line.resizeViewport(newWidth) }
            .animation(ShelfMotion.animation(reduceMotion: reduceMotion, normal: .spring(response: 0.55, dampingFraction: 0.78)), value: line.items.map(\.id))
            .animation(ShelfMotion.animation(reduceMotion: reduceMotion, normal: .easeInOut(duration: 0.3)), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(ShelfMotion.animation(reduceMotion: reduceMotion, normal: line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22)), value: line.revealed)
            .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            let viewport = CGRect(x: 0, y: 0, width: line.viewportWidth, height: Layout.panelHeight)
            line.hitRects = rects.reduce(into: [:]) { result, entry in
                let clipped = entry.value.intersection(viewport)
                if !clipped.isNull && !clipped.isEmpty { result[entry.key] = clipped }
            }
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
            path.stroke(Color(nsColor: PanelAppearance.rope), lineWidth: 1.4)
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
