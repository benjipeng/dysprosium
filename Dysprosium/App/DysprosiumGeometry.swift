import SwiftUI
import UIKit

/// Availability-safe representation of UIKit's iOS 27.1+ `UITraitCollection.verticalBarEdge`.
public enum DuoVerticalBarPlacement: Sendable, Equatable {
    case none
    case leading
    case trailing
}

private struct DuoVerticalBarEdgeTraitKey: UITraitBridgedEnvironmentKey {
    static let defaultValue: DuoVerticalBarPlacement = .none

    static func read(from traitCollection: UITraitCollection) -> DuoVerticalBarPlacement {
        if #available(iOS 27.1, *) {
            switch traitCollection.verticalBarEdge {
            case .leading: return .leading
            case .trailing: return .trailing
            default: return .none
            }
        }
        return .none
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: DuoVerticalBarPlacement) {}
}

extension EnvironmentValues {
    public var duoVerticalBarEdge: DuoVerticalBarPlacement {
        self[DuoVerticalBarEdgeTraitKey.self]
    }
}

/// Evaluates iPhone Duo viewport geometry, hinge `.division` creases, and `.occlusion` cutouts
/// strictly from `GeometryProxy` without touching banned legacy APIs (`UIScreen.main`,
/// `UIDevice.current.orientation`, or `userInterfaceIdiom`).
public struct DuoViewportMetrics: Equatable, Sendable {
    public let size: CGSize
    public let safeAreaInsets: EdgeInsets
    public let topLeadingCornerInset: CGSize
    public let topTrailingCornerInset: CGSize
    public let activeDivisionRect: CGRect?
    public let inactiveDivisionRect: CGRect?
    public let occlusionRects: [CGRect]

    public init(proxy: GeometryProxy) {
        self.size = proxy.size
        self.safeAreaInsets = proxy.safeAreaInsets
        self.topLeadingCornerInset = proxy.containerCornerInsets.topLeading
        self.topTrailingCornerInset = proxy.containerCornerInsets.topTrailing

        if #available(iOS 27.1, *) {
            let divisions = proxy.reservedRegions(kind: .division, options: [.includeInactive])
            self.activeDivisionRect = divisions.first(where: \.isActive)?.frame
            self.inactiveDivisionRect = divisions.first(where: { !$0.isActive })?.frame
            self.occlusionRects = proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        } else {
            self.activeDivisionRect = nil
            self.inactiveDivisionRect = nil
            self.occlusionRects = []
        }
    }

    /// Computes leading and trailing horizontal padding that clears iPhone Duo's `59 pt` screen corners
    /// whenever custom floating chrome hugs the top edge (`safeAreaInsets.top == 0`).
    public func topCornerSafeHorizontalPadding(minimum: CGFloat = 16) -> (leading: CGFloat, trailing: CGFloat) {
        let leading = max(minimum, topLeadingCornerInset.width + 6)
        let trailing = max(minimum, topTrailingCornerInset.width + 6)
        return (leading, trailing)
    }

    /// True on iPhone Duo inner full-screen postures (`669×951` portrait & `951×669` landscape),
    /// false on closed outer display (`466×678`) and 50/50 inner Split View (`~469` pt).
    public var supportsSideBySideColumns: Bool {
        size.width >= 620
    }

    /// Vertical hinge crease dividing left and right halves in Book pose.
    public var verticalHingeRect: CGRect? {
        guard let rect = activeDivisionRect ?? inactiveDivisionRect,
              rect.height > rect.width,
              rect.width > 0 else { return nil }
        return activeDivisionRect != nil ? rect : nil
    }

    /// Horizontal hinge crease dividing top viewing half from bottom touch surface in Tabletop pose.
    public var horizontalHingeRect: CGRect? {
        guard let rect = activeDivisionRect,
              rect.width >= rect.height,
              rect.height > 0 else { return nil }
        return rect
    }

    /// Center gutter width that cleanly clears the 40 pt iPhone Duo hinge when partially folded.
    public var splitColumnSpacing: CGFloat {
        if let vHinge = verticalHingeRect {
            return max(24, vHinge.width + 16)
        }
        return 20
    }

    /// Enforces Apple's iPhone Duo even-column rule (`2` or `4`) so cards never straddle `.division`.
    public var evenVaultColumnCount: Int {
        size.width >= 840 ? 4 : 2
    }

    /// Computes exact leading and trailing pane widths around an active vertical fold when present.
    public func splitColumnWidths(horizontalPadding: CGFloat = 20) -> (leading: CGFloat, trailing: CGFloat) {
        let usable = max(320, size.width - horizontalPadding * 2)
        if let hinge = verticalHingeRect {
            let leftWidth = max(260, hinge.minX - horizontalPadding - 8)
            let rightWidth = max(260, (size.width - horizontalPadding) - hinge.maxX - 8)
            if leftWidth + rightWidth + hinge.width <= usable + 24 {
                return (leftWidth, rightWidth)
            }
        }
        let spacing = splitColumnSpacing
        let leading = floor((usable - spacing) * 0.54)
        let trailing = max(260, usable - spacing - leading)
        return (leading, trailing)
    }

    /// Computes `(leading, maxWidth)` in `GeometryProxy` coordinates so floating chrome
    /// docks cleanly inside the trailing half whenever an active vertical `.division` hinge
    /// is present (Book Pose or Split-Right), never straddling the 40 pt fold crease.
    public func bookPoseTrailingHalfFrame(horizontalPadding: CGFloat = 16) -> (leading: CGFloat, maxWidth: CGFloat)? {
        guard let hinge = verticalHingeRect else { return nil }
        let hingeClearance: CGFloat = 10
        let leading = hinge.maxX + hingeClearance
        let availableWidth = (size.width - horizontalPadding) - leading
        guard availableWidth >= 200 else { return nil }
        return (leading: leading, maxWidth: min(DysprosiumTokens.Space.omniboxMaxWidth, availableWidth))
    }
}

/// Posture-resolved coordinates for Dysprosium's floating Liquid Glass browser chrome.
/// Pure value type so every iPhone Duo posture (Outer Portrait, Inner Landscape, Book Pose,
/// Inner Portrait idle/Live-Activity) and non-Duo fallback is regression-tested deterministically.
public struct BrowserTopChromeLayout: Equatable, Sendable {
    public let top: CGFloat
    public let leading: CGFloat
    public let trailing: CGFloat
    public let maxWidth: CGFloat?

    public let compactTop: CGFloat
    public let compactLeading: CGFloat
    public let compactTrailing: CGFloat
    public let compactMaxWidth: CGFloat

    public static let compactPillMaxWidth: CGFloat = 204

    public static func resolve(
        size: CGSize,
        topLeadingCornerInset: CGSize,
        topTrailingCornerInset: CGSize,
        occlusionRects: [CGRect],
        verticalHingeRect: CGRect?,
        verticalBarEdge: DuoVerticalBarPlacement,
        windowTopSafeAreaInset: CGFloat = 0
    ) -> BrowserTopChromeLayout {
        let width = size.width
        let isVerticalRailActive = (verticalBarEdge != .none)
        let isWideCanvas = width >= 620

        // Side-by-side status occlusion in top-right corner (e.g. `525..669` in Inner Portrait `669×951`)
        let topRightStatusOcclusion = occlusionRects
            .filter { $0.minY < 84 && $0.minX >= width * 0.50 && $0.minX < width - 8 }
            .min(by: { $0.minX < $1.minX })

        let baseLeading: CGFloat
        if verticalBarEdge == .leading {
            baseLeading = 12
        } else if isWideCanvas {
            baseLeading = 18
        } else if topLeadingCornerInset.width > 16 {
            baseLeading = 20
        } else {
            // Closed Outer Display hinge side (`8 pt` corner radius)
            baseLeading = 14
        }

        let baseTrailing: CGFloat
        if verticalBarEdge == .trailing {
            // Trailing edge already abuts the 84 pt vertical hardware bar (`safeAreaInsets.trailing == 84`);
            // never re-apply `topTrailingCornerInset` on top of the rail safe area.
            baseTrailing = 12
        } else if let statusOcclusion = topRightStatusOcclusion {
            baseTrailing = max(16, width - statusOcclusion.minX)
        } else if topTrailingCornerInset.width > 16 {
            baseTrailing = 20
        } else {
            baseTrailing = 14
        }

        // Book Pose: dock floating chrome strictly inside the trailing half, never straddling the 40 pt hinge.
        let bookTrailingFrame: (leading: CGFloat, maxWidth: CGFloat)? = {
            guard isVerticalRailActive, let hinge = verticalHingeRect else { return nil }
            let leading = hinge.maxX + 10
            let available = (width - baseTrailing) - leading
            guard available >= 200 else { return nil }
            return (leading: leading, maxWidth: min(DysprosiumTokens.Space.omniboxMaxWidth, available))
        }()

        let expandedLeading = bookTrailingFrame?.leading ?? baseLeading
        let expandedMaxWidth: CGFloat? = bookTrailingFrame?.maxWidth ?? (isWideCanvas ? DysprosiumTokens.Space.omniboxMaxWidth : nil)

        let expandedTop: CGFloat
        let compactTop: CGFloat
        if topRightStatusOcclusion != nil {
            // Inner Portrait (`669×951`, `safeAreaInsets.top == 82`):
            // - Expanded 36 pt bar centers at `midY = 48 pt`, aligned to the corner clock & Wi-Fi ring.
            // - Minimized 24 pt domain pill tucks close to the top display edge (`y = 10..34`), centered horizontally.
            expandedTop = 30
            compactTop = 10
        } else if isVerticalRailActive {
            // Closed Outer Portrait (`382 pt` safe width) aligns expanded bar with the adjacent 37×37 camera circle (`midY ≈ 47.8`);
            // wide Inner Landscape (`867 pt` safe width) tucks closer to the top edge (`14 pt`).
            // Minimized 24 pt domain pill hugs the top edge (`6 pt`) for maximum reading canvas.
            expandedTop = width < 500 ? 29 : 14
            compactTop = 6
        } else {
            // Standard notched / Dynamic Island iPhone (`windowTopSafeAreaInset > 0`) vs Duo split-left (`0 pt`).
            expandedTop = windowTopSafeAreaInset > 0 ? (windowTopSafeAreaInset + 6) : 20
            compactTop = windowTopSafeAreaInset > 0 ? (windowTopSafeAreaInset + 2) : 6
        }

        // Center the compact domain pill symmetrically across the viewport whenever it clears any
        // top-right status occlusion by >= 12 pt (true on Inner Portrait `669×951` idle and Live Activity);
        // otherwise keep it bounded inside the unobscured leading corridor.
        let compactLeading: CGFloat
        let compactTrailing: CGFloat
        if let bookFrame = bookTrailingFrame {
            compactLeading = bookFrame.leading
            compactTrailing = baseTrailing
        } else if let statusOcclusion = topRightStatusOcclusion {
            let halfPill = Self.compactPillMaxWidth * 0.5
            let canTrueCenter = (statusOcclusion.minX - 12) >= (width * 0.5 + halfPill)
            compactLeading = baseLeading
            compactTrailing = canTrueCenter ? baseLeading : baseTrailing
        } else {
            compactLeading = baseLeading
            compactTrailing = baseTrailing
        }

        return BrowserTopChromeLayout(
            top: expandedTop,
            leading: expandedLeading,
            trailing: baseTrailing,
            maxWidth: expandedMaxWidth,
            compactTop: compactTop,
            compactLeading: compactLeading,
            compactTrailing: compactTrailing,
            compactMaxWidth: Self.compactPillMaxWidth
        )
    }

    public static func resolve(
        metrics: DuoViewportMetrics,
        verticalBarEdge: DuoVerticalBarPlacement,
        windowTopSafeAreaInset: CGFloat = 0
    ) -> BrowserTopChromeLayout {
        resolve(
            size: metrics.size,
            topLeadingCornerInset: metrics.topLeadingCornerInset,
            topTrailingCornerInset: metrics.topTrailingCornerInset,
            occlusionRects: metrics.occlusionRects,
            verticalHingeRect: metrics.verticalHingeRect,
            verticalBarEdge: verticalBarEdge,
            windowTopSafeAreaInset: windowTopSafeAreaInset
        )
    }

    /// Computes exact interpolated omnibox frame (`x, y, width, height`) in the root viewport coordinate space
    /// for a continuous collapse `progress` in `0.0` (expanded 36 pt bar) ... `1.0` (24 pt centered domain pill).
    /// Interpolating a single persistent glass capsule eliminates view-tree teardown and container padding jumps.
    public func omniboxFrame(
        viewportWidth: CGFloat,
        isVerticalRailActive: Bool,
        hasBackButton: Bool,
        trailingClusterWidth: CGFloat,
        compactPillWidth: CGFloat,
        progress: CGFloat
    ) -> CGRect {
        let p = min(1, max(0, progress))

        let expandedX: CGFloat
        let expandedW: CGFloat
        if isVerticalRailActive {
            let corridorW = max(120, viewportWidth - leading - trailing)
            if let maxW = maxWidth {
                expandedW = min(maxW, corridorW)
                expandedX = leading + (corridorW - expandedW) * 0.5
            } else {
                expandedW = corridorW
                expandedX = leading
            }
        } else {
            let backSlot: CGFloat = hasBackButton ? 44 : 0
            let trailingSlot: CGFloat = trailingClusterWidth + 8
            expandedX = leading + backSlot
            expandedW = max(120, viewportWidth - leading - trailing - backSlot - trailingSlot)
        }

        let compactCorridorW = max(72, viewportWidth - compactLeading - compactTrailing)
        let compactW = min(compactPillWidth, compactCorridorW)
        let compactX = compactLeading + (compactCorridorW - compactW) * 0.5

        let x = expandedX + (compactX - expandedX) * p
        let y = top + (compactTop - top) * p
        let w = expandedW + (compactW - expandedW) * p
        let h = 36 - 12 * p
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Continuous scroll-driven state machine powering Safari-style finger-tracked chrome compaction.
/// Tracks `progress` in `0.0...1.0` directly with the user's scroll delta across a `56 pt` travel band,
/// snaps cleanly to `0` or `1` on gesture settle, and stays completely quiescent once clamped so
/// 120 Hz ProMotion scrolling incurs zero steady-state SwiftUI invalidations.
public struct BrowserChromeScrollState: Equatable, Sendable {
    public static let collapseTravelDistance: CGFloat = 56

    /// `0.0` = fully expanded omnibox; `1.0` = compact centered top-edge domain pill.
    public private(set) var progress: CGFloat = 0
    public var isMinimized: Bool { progress >= 0.5 }

    private var lastContentOffsetY: CGFloat? = nil
    private var lastEffectiveY: CGFloat? = nil

    public init() {}

    public mutating func reset() {
        progress = 0
        lastContentOffsetY = nil
        lastEffectiveY = nil
    }

    /// Synchronizes an external expand/collapse (e.g. tapping the compact pill or switching tabs)
    /// anchored to raw `contentOffset.y` so dynamic top-inset changes never inject false deltas.
    public mutating func syncExternal(progress: CGFloat, contentOffsetY: CGFloat) {
        self.progress = min(1, max(0, progress))
        self.lastContentOffsetY = contentOffsetY
        self.lastEffectiveY = nil
    }

    /// Synchronizes an external expand/collapse using an effective offset (`contentOffsetY + topInset`).
    public mutating func syncExternal(progress: CGFloat, currentEffectiveY: CGFloat) {
        self.progress = min(1, max(0, progress))
        self.lastContentOffsetY = nil
        self.lastEffectiveY = currentEffectiveY
    }

    /// Synchronizes an external boolean state (`false -> 0`, `true -> 1`).
    public mutating func syncExternal(isMinimized: Bool, currentEffectiveY: CGFloat) {
        syncExternal(progress: isMinimized ? 1 : 0, currentEffectiveY: currentEffectiveY)
    }

    /// Processes a scroll-offset update and returns `true` only when `progress` meaningfully changed.
    /// Scroll deltas are computed from raw `contentOffsetY` whenever available so shrinking or
    /// expanding `additionalSafeAreaInsets.top` (to uplift fixed site navbars) never creates a feedback loop.
    @discardableResult
    public mutating func handleScroll(
        contentOffsetY: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        isUserDriven: Bool
    ) -> Bool {
        let effectiveY = contentOffsetY + topInset
        let maxScrollableY = max(0, contentHeight + bottomInset - viewportHeight + topInset)
        let previous = progress

        let deltaY: CGFloat?
        if let prevOffset = lastContentOffsetY {
            deltaY = contentOffsetY - prevOffset
        } else if let prevEffective = lastEffectiveY {
            deltaY = effectiveY - prevEffective
        } else {
            deltaY = nil
        }

        // Short pages never collapse chrome.
        guard maxScrollableY > 80 else {
            progress = 0
            lastContentOffsetY = contentOffsetY
            lastEffectiveY = effectiveY
            return abs(progress - previous) > 0.001
        }

        // Near the very top of the page, expand smoothly to `0`—unless the user is actively
        // pushing downward past `0` while `topInset` has collapsed toward `0`.
        if effectiveY <= 8 && (!isUserDriven || (deltaY ?? 0) <= 0) {
            progress = 0
            lastContentOffsetY = contentOffsetY
            lastEffectiveY = effectiveY
            return abs(progress - previous) > 0.001
        }

        // Ignore programmatic / layout scroll adjustments unless returning to top above.
        guard isUserDriven else {
            lastContentOffsetY = contentOffsetY
            lastEffectiveY = effectiveY
            return false
        }

        // Ignore footer rubber-band bounce so overscroll recoil never flickers the bar.
        if effectiveY >= maxScrollableY - 4 {
            lastContentOffsetY = contentOffsetY
            lastEffectiveY = effectiveY
            return false
        }

        guard let deltaY else {
            lastContentOffsetY = contentOffsetY
            lastEffectiveY = effectiveY
            return false
        }

        lastContentOffsetY = contentOffsetY
        lastEffectiveY = effectiveY
        guard abs(deltaY) > 0.05 else { return false }

        // Below `16 pt` from top (while still expanded), damp downward collapse so micro-jiggles at top don't twitch the bar.
        if deltaY > 0 && effectiveY < 16 && progress < 0.01 {
            return false
        }

        let next = min(1, max(0, progress + (deltaY / Self.collapseTravelDistance)))
        progress = next
        return abs(progress - previous) > 0.001
    }

    /// Resolves any partial mid-flight progress (`0 < progress < 1`) to a crisp resting endpoint (`0` or `1`)
    /// when the user lifts their finger or deceleration finishes. Returns `true` if `progress` snapped.
    @discardableResult
    public mutating func settleIfPartial(preferMinimize: Bool? = nil) -> Bool {
        guard progress > 0.001 && progress < 0.999 else { return false }
        let target: CGFloat
        if let preferMinimize {
            target = preferMinimize ? 1 : 0
        } else {
            target = progress >= 0.45 ? 1 : 0
        }
        progress = target
        return true
    }
}
