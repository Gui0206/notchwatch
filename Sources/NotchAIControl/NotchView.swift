import SwiftUI

/// Geometry shared between the SwiftUI content and the window/hit-test logic.
struct NotchMetrics {
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    // Collapsed indicator lives entirely WITHIN the hardware notch, so the
    // window never covers (and never blocks) the menu bar beside it.
    var collapsedWidth: CGFloat { notchWidth }
    var collapsedHeight: CGFloat { notchHeight }

    // Expanded panel — wide and short, echoing the notch's horizontal shape.
    var panelWidth: CGFloat = 580
    var expandedWidth: CGFloat { max(panelWidth, collapsedWidth) }

    static func detect(_ screen: NSScreen) -> NotchMetrics {
        let h = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        var w: CGFloat = 200
        if let l = screen.auxiliaryTopLeftArea?.width,
           let r = screen.auxiliaryTopRightArea?.width {
            let computed = screen.frame.width - l - r
            if computed > 60 { w = computed }
        }
        return NotchMetrics(notchWidth: w, notchHeight: h)
    }
}

/// Observable expansion flag so the view tree stays mounted and SwiftUI always
/// animates the open/close transition (rather than re-mounting a fresh tree).
@MainActor
final class NotchUIState: ObservableObject {
    @Published var expanded = false
}

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: NotchUIState
    let metrics: NotchMetrics
    var onClose: () -> Void
    var onActivate: (Session) -> Void = { _ in }
    var onPanelHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if ui.expanded {
                expandedPanel
                    // Symmetric: closing is the exact reverse of opening.
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
            } else {
                collapsedPill
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Springy unfurl from the notch: quick to open, gentle overshoot on settle.
        .animation(.spring(response: 0.44, dampingFraction: 0.68), value: ui.expanded)
    }

    // MARK: Collapsed

    // Nothing is drawn when collapsed — the notch looks completely normal.
    // This transparent frame just gives the layout its size + hover target.
    private var collapsedPill: some View {
        Color.clear
            .frame(width: metrics.collapsedWidth, height: metrics.collapsedHeight)
    }

    // MARK: Expanded

    /// One continuous black shape that hangs from the top of the screen and
    /// absorbs the notch — square at the top (flush with the bezel), rounded at
    /// the bottom — so it reads as the notch itself growing, not a separate card.
    private var blobShape: NotchShape {
        NotchShape(topRadius: 13, bottomRadius: 28)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The physical notch lives in this top strip; keep it content-free.
            Color.clear.frame(height: metrics.notchHeight)
            if store.sessions.isEmpty {
                emptyState
            } else if store.sessions.count > 6 {
                // Only scroll when there are genuinely too many to fit.
                ScrollView { sessionList }.frame(height: 300)
            } else {
                // Hug the content so the panel is exactly as tall as it needs.
                sessionList
            }
        }
        .frame(width: metrics.panelWidth)
        // Pure #000000 — same value as the notch — and flat (no shadow) so it
        // reads as the notch extending down rather than a card floating above it.
        .background(blobShape.fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)))
        .clipShape(blobShape)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onPanelHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, h in onPanelHeight(h) }
            }
        )
    }

    private var sessionList: some View {
        VStack(spacing: 5) {
            ForEach(store.sorted) { session in
                SessionRow(
                    session: session,
                    onActivate: { onActivate(session) },
                    onDismiss: { store.remove(id: session.id) }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        Text("No active sessions")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session
    var onActivate: () -> Void = {}
    var onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PulsingDot(color: session.state.color, active: session.state.pulses, size: 10)
                .frame(width: 12)
            Text(session.project)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            Text(session.tool)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize()
            Text(session.activity.isEmpty ? "—" : session.activity)
                .font(.system(size: 12.5))
                .foregroundStyle(activityColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            if hovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            } else {
                Text(elapsed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onHover { hovering = $0 }
    }

    private var activityColor: Color {
        switch session.state {
        case .waiting, .error: return session.state.color
        default: return .white.opacity(0.55)
        }
    }

    private var elapsed: String {
        let ref = (session.state == .done) ? session.updatedAt : Date()
        let secs = max(0, Int(ref.timeIntervalSince(session.startedAt)))
        let m = secs / 60, s = secs % 60
        if m >= 60 { return "\(m/60)h \(m%60)m" }
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

/// A dot (or ring) that softly pulses to draw attention.
struct PulsingDot: View {
    let color: Color
    var active: Bool
    var size: CGFloat
    var ring: Bool = false
    @State private var animate = false

    var body: some View {
        Group {
            if ring {
                Circle()
                    .strokeBorder(color.opacity(0.5), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 1.25 : 0.9)
                    .opacity(animate ? 0 : 0.8)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 1.0 : 0.7)
                    .shadow(color: color.opacity(animate ? 0.8 : 0.2), radius: animate ? 5 : 1)
            }
        }
        .onAppear { if active { start() } }
        .onChange(of: active) { _, now in if now { start() } else { animate = false } }
    }

    private func start() {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: !ring)) {
            animate = true
        }
    }
}

/// Rounded-bottom shape that visually extends the physical notch.
/// The expanded panel's outline, matching the MacBook notch: the top corners
/// are *concave* — they curve outward from the panel's vertical sides up into
/// the top edge of the screen — while the bottom corners are convex/rounded.
struct NotchShape: Shape {
    var topRadius: CGFloat = 12
    var bottomRadius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, rect.height / 2)
        let br = min(bottomRadius, rect.width / 2 - tr)

        // Top edge meets the screen at full width.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left concave fillet: top edge curves down into the left side.
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        // Left side down.
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        // Bottom-left convex corner.
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        // Bottom-right convex corner.
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        // Right side up.
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        // Top-right concave fillet: right side curves up into the top edge.
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
