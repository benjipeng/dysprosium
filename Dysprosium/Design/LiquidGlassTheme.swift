import SwiftUI

/// Formatting helpers and Canvas telemetry strips driven by `DysprosiumTokens`.
/// Zero synthetic `MeshGradient` backdrops: all screens and sheets rely on pure semantic system materials
/// (`Color(.systemGroupedBackground)` and native `UISheetPresentationController` translucency) so
/// Liquid Glass bars refract clean, unmuddied surfaces.
public enum DysprosiumFormatters {
    public static func bytes(_ count: Int64) -> String {
        max(0, count).formatted(.byteCount(style: .file))
    }

    public static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 1 else { return "0 B/s" }
        return "\(Int64(bytesPerSec).formatted(.byteCount(style: .file)))/s"
    }

    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return String(format: "%dm %02ds", mins, secs) }
        return String(format: "%dh %02dm", mins / 60, mins % 60)
    }

    /// Formats elapsed transfer durations with sub-minute precision (`14.2s`, `2m 18s`, `1h 04m`).
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 {
            return seconds < 10 ? String(format: "%.1fs", seconds) : String(format: "%.0fs", seconds)
        }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return String(format: "%dm %02ds", mins, secs) }
        return String(format: "%dh %02dm", mins / 60, mins % 60)
    }
}

/// Visualizes HTTP Range byte slices and active `Darwin.pwrite` worker cursors across `[0 .. totalBytes)`.
public struct ByteRangeHeatmapBar: View {
    @Environment(\.dysprosiumTokens) private var tokens

    public let slices: [ByteRangeSlice]
    public let totalBytes: Int64?
    public let fallbackProgress: Double
    public let lifecycle: TransferLifecycle

    public init(
        slices: [ByteRangeSlice],
        totalBytes: Int64?,
        fallbackProgress: Double,
        lifecycle: TransferLifecycle
    ) {
        self.slices = slices
        self.totalBytes = totalBytes
        self.fallbackProgress = fallbackProgress
        self.lifecycle = lifecycle
    }

    private var activeTint: Color {
        switch lifecycle {
        case .completed: return tokens.statusSuccess
        case .paused: return tokens.statusWarning
        case .failed: return tokens.statusDanger
        default: return tokens.accent
        }
    }

    public var body: some View {
        let fillTint = activeTint
        Canvas { context, size in
            let trackRect = CGRect(origin: .zero, size: size)
            let trackPath = Path(roundedRect: trackRect, cornerRadius: size.height / 2)
            context.fill(trackPath, with: .color(.secondary.opacity(0.16)))
            context.clip(to: trackPath)

            if let total = totalBytes, total > 0, !slices.isEmpty {
                let width = size.width
                for slice in slices {
                    guard slice.completedBytes > 0 else { continue }
                    let xStart = CGFloat(Double(slice.startOffset) / Double(total)) * width
                    let xEnd = CGFloat(Double(slice.currentOffset) / Double(total)) * width
                    let rect = CGRect(x: xStart, y: 0, width: max(1.5, xEnd - xStart), height: size.height)
                    context.fill(Path(rect), with: .color(fillTint))

                    if slice.isActiveLane, !slice.isComplete {
                        let cursor = CGRect(x: max(0, xEnd - 2), y: 0, width: 2.5, height: size.height)
                        context.fill(Path(cursor), with: .color(.primary))
                    }
                }

                for slice in slices.dropFirst() {
                    let tickX = CGFloat(Double(slice.startOffset) / Double(total)) * width
                    let tick = CGRect(x: tickX, y: 0, width: 1, height: size.height)
                    context.fill(Path(tick), with: .color(Color(.systemBackground).opacity(0.55)))
                }
            } else {
                let clamped = min(1.0, max(0.0, fallbackProgress))
                let rect = CGRect(x: 0, y: 0, width: size.width * clamped, height: size.height)
                context.fill(Path(rect), with: .color(fillTint))
            }
        }
        .frame(height: 7)
        .accessibilityLabel("Byte range progress")
        .accessibilityValue("\(Int((fallbackProgress * 100).rounded())) percent")
    }
}

/// Throughput sparkline driven by `DysprosiumTokens.accent`.
public struct ThroughputSparklineView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    public let samples: [Double]

    public init(samples: [Double]) {
        self.samples = samples
    }

    public var body: some View {
        let strokeColor = tokens.accent
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            let peak = max(samples.max() ?? 1, 1024)
            let stepX = size.width / CGFloat(max(1, samples.count - 1))

            var line = Path()
            for (idx, val) in samples.enumerated() {
                let x = CGFloat(idx) * stepX
                let normalized = CGFloat(min(1.0, max(0.0, val / peak)))
                let y = size.height - (normalized * (size.height - 4)) - 2
                if idx == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [strokeColor.opacity(0.22), .clear]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(strokeColor), lineWidth: 1.75)
        }
    }
}
