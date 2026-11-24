import SwiftUI

/// Native transfer row designed to live inside a standard SwiftUI `List`.
/// - Zero `.glassEffect()` or `.buttonStyle(.glass)` inside scrolling cells (obeys Invariant #4).
/// - Driven strictly by `DysprosiumTokens` (`@Environment(\.dysprosiumTokens)`).
struct TransferCardView: View {
    @Environment(\.dysprosiumTokens) private var tokens

    let job: TransferJob
    var isSelected: Bool = false
    let onTogglePauseResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(job.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                statusBadge
            }

            HStack(spacing: 6) {
                Text(job.siteDomain)
                Text("·")
                Text(job.kind.localizedTitle)
                    .foregroundStyle(tokens.accent)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)

            ByteRangeHeatmapBar(
                slices: job.slices,
                totalBytes: job.totalBytes,
                fallbackProgress: job.progressFraction,
                lifecycle: job.lifecycle
            )

            HStack(spacing: 6) {
                Text(progressCaption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if job.lifecycle == .downloading {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(job.activeLanes)/\(job.configuredLanes)×")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(tokens.accent)
                        .fixedSize()
                } else if !job.slices.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(L("\(job.slices.count) slices"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                if job.lifecycle == .downloading {
                    Text(DysprosiumFormatters.speed(job.speedBytesPerSec))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .fixedSize()
                } else if let err = job.errorMessage, job.lifecycle == .failed {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(tokens.statusDanger)
                        .lineLimit(1)
                }

                if job.lifecycle != .completed {
                    Button(action: onTogglePauseResume) {
                        Label(
                            job.lifecycle.isActive || job.lifecycle == .queued ? L("Pause") : L("Resume"),
                            systemImage: job.lifecycle.isActive || job.lifecycle == .queued ? "pause.fill" : "play.fill"
                        )
                        .labelStyle(.iconOnly)
                        .symbolRenderingMode(.monochrome)
                        .contentTransition(.symbolEffect(.replace))
                    }
                    .controlSize(.small)
                    .tint(tokens.accent)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, fg, bg): (String, Color, Color) = switch job.lifecycle {
        case .queued:
            (L("Queued"), .secondary, Color.secondary.opacity(0.14))
        case .resolving:
            (L("Resolving"), tokens.accent, tokens.accentSubtleFill)
        case .downloading:
            ("\(Int((job.progressFraction * 100).rounded()))%", tokens.accent, tokens.accentSubtleFill)
        case .muxing:
            (L("Muxing"), tokens.statusSuccess, tokens.statusSuccessFill)
        case .paused:
            (L("Paused"), tokens.statusWarning, tokens.statusWarningFill)
        case .completed:
            (L("Saved"), tokens.statusSuccess, tokens.statusSuccessFill)
        case .failed:
            (L("Error"), tokens.statusDanger, tokens.statusDangerFill)
        }

        Text(label)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }

    private var progressCaption: String {
        if let totalSegs = job.totalSegments, totalSegs > 0 {
            return L("\(job.completedSegments)/\(totalSegs) segs · \(DysprosiumFormatters.bytes(job.downloadedBytes))")
        }
        if let total = job.totalBytes, total > 0 {
            return "\(DysprosiumFormatters.bytes(job.downloadedBytes)) / \(DysprosiumFormatters.bytes(total))"
        }
        return DysprosiumFormatters.bytes(job.downloadedBytes)
    }
}
