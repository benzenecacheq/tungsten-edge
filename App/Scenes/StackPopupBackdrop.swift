import AppKit
import SwiftUI

/// The plate of the folder / shelf / Trash popup: the native Dock's stack material — regular Liquid
/// Glass in its dark appearance, whatever the system appearance is — shaped by one path that
/// carries the arrow. Below macOS 26 (or with glass switched off) a dark frosted plate takes the
/// same outline.
///
/// The view is `arrowHeight` taller than the plate: the arrow hangs in that strip.
struct StackPopupBackdrop: View {
    let plateSize: CGSize
    /// Arrow centre from the plate's left edge; nil draws the plate without an arrow.
    let arrowCenterX: CGFloat?
    let usesLiquidGlass: Bool

    @Environment(\.colorScheme) private var colorScheme
    private var theme: DockThemeTokens { .resolved(for: colorScheme) }

    var body: some View {
        Group {
            if #available(macOS 26.0, *), usesLiquidGlass {
                StackGlassPlate(plateSize: plateSize, arrowCenterX: arrowCenterX)
            } else {
                let shape = StackPopupShape(plateSize: plateSize, arrowCenterX: arrowCenterX)
                StackFrostedPlate()
                    .clipShape(shape)
                    .overlay(shape.stroke(theme.stackPopupHairline.color, lineWidth: 0.5))
                    .dockShadow(theme.stackPopupShadow)
            }
        }
        .frame(width: plateSize.width, height: plateSize.height + StackPopupMetrics.arrowHeight)
        .allowsHitTesting(false)
    }
}

struct StackPopupShape: Shape {
    let plateSize: CGSize
    let arrowCenterX: CGFloat?

    func path(in rect: CGRect) -> Path {
        Path(StackPopupOutline.path(plateSize: plateSize, arrowCenterX: arrowCenterX))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The glass itself. A plain container owns the `NSGlassEffectView` so the no-`_setPath:` fallback
/// can keep the glass off the arrow strip instead of painting a plate 8pt too tall.
@available(macOS 26.0, *)
private struct StackGlassPlate: NSViewRepresentable {
    let plateSize: CGSize
    let arrowCenterX: CGFloat?

    func makeNSView(context: Context) -> StackGlassContainer {
        let view = StackGlassContainer()
        view.apply(plateSize: plateSize, arrowCenterX: arrowCenterX)
        return view
    }

    // SwiftUI re-runs update, never re-creates the view: width and arrow follow the content here.
    func updateNSView(_ view: StackGlassContainer, context: Context) {
        view.apply(plateSize: plateSize, arrowCenterX: arrowCenterX)
    }
}

@available(macOS 26.0, *)
final class StackGlassContainer: NSView {
    private let glass = NSGlassEffectView()
    private var plateSize = CGSize.zero
    private var arrowCenterX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.contentView = NSView()
        glass.style = .regular
        // On the view, not the window: the app is pinned to `.aqua` and everything else in this
        // panel (menus included) stays light.
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.cornerRadius = StackPopupMetrics.cornerRadius
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(plateSize: CGSize, arrowCenterX: CGFloat?) {
        guard plateSize != self.plateSize || arrowCenterX != self.arrowCenterX else { return }
        self.plateSize = plateSize
        self.arrowCenterX = arrowCenterX
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let arrow = StackPopupMetrics.arrowHeight
        let full = CGRect(x: 0, y: 0, width: plateSize.width, height: plateSize.height + arrow)
        // AppKit's y runs up: flip the outline, whose arrow hangs below the plate.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: full.height)
        let outline = StackPopupOutline.path(plateSize: plateSize, arrowCenterX: arrowCenterX)
        if let path = outline.copy(using: &flip), TEDockGlassSetPath(glass, path) {
            glass.frame = full
        } else {
            glass.frame = CGRect(x: 0, y: arrow, width: plateSize.width, height: plateSize.height)
        }
    }
}

private struct StackFrostedPlate: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
