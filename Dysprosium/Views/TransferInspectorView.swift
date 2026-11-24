import SwiftUI

/// Native `.insetGrouped` live transfer inspector displaying multi-lane byte-range slices and socket telemetry.
struct TransferInspectorView: View {
    @Environment(\.dysprosiumTokens) private var tokens

    let job: TransferJob
    let vaultFileURL: URL?
    var isEmbeddedInSplit: Bool = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.title)
                        .font(.headline)

                    ByteRangeHeatmapBar(
                        slices: job.slices,
                        totalBytes: job.totalBytes,
                        fallbackProgress: job.progressFraction,
                        lifecycle: job.lifecycle
                    )

                    HStack {
                        LabeledContent(L("Transferred"), value: DysprosiumFormatters.bytes(job.downloadedBytes))
                        Spacer()
                        LabeledContent(L("Total"), value: job.totalBytes.map(DysprosiumFormatters.bytes) ?? L("Stream"))
                    }
                    .font(.caption.monospacedDigit())
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text(job.kind.localizedTitle)
                    Spacer()
                    Text(L("\(job.configuredLanes)× Lanes"))
                        .foregroundStyle(tokens.accent)
                }
                .font(.caption.monospacedDigit())
            }

            Section(L("Throughput")) {
                ThroughputSparklineView(samples: job.throughputSamples)
                    .frame(height: 52)
                    .padding(.vertical, 4)

                LabeledContent(L("Speed"), value: DysprosiumFormatters.speed(job.speedBytesPerSec))
                    .font(.subheadline.monospacedDigit())
                LabeledContent(L("Active Workers"), value: "\(job.activeLanes) / \(job.configuredLanes)")
                    .font(.subheadline.monospacedDigit())
                LabeledContent(L("Remaining"), value: DysprosiumFormatters.eta(job.etaSeconds))
                    .font(.subheadline.monospacedDigit())
            }

            if !job.slices.isEmpty {
                Section(L("Byte-Range Slices (\(job.slices.filter(\.isComplete).count)/\(job.slices.count))")) {
                    ForEach(job.slices.prefix(16)) { slice in
                        HStack(spacing: 8) {
                            Image(
                                systemName: slice.isComplete
                                    ? "checkmark.circle.fill"
                                    : (slice.isActiveLane ? "bolt.circle.fill" : "circle.dotted")
                            )
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(
                                slice.isComplete
                                    ? tokens.statusSuccess
                                    : (slice.isActiveLane ? tokens.accent : .secondary)
                            )
                            .font(.caption)
                            .frame(width: 16, alignment: .center)

                            Text(String(format: "#%02d", slice.id))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            Text("\(DysprosiumFormatters.bytes(slice.startOffset)) → \(DysprosiumFormatters.bytes(slice.endOffset))")
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)

                            Spacer()

                            let pct = slice.totalBytes > 0 ? Int((Double(slice.completedBytes) / Double(slice.totalBytes) * 100).rounded()) : 0
                            Text("\(pct)%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(slice.isComplete ? tokens.statusSuccess : .primary)
                        }
                    }
                }
            }

            Section(L("Source")) {
                Text(job.sourceURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let err = job.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(tokens.statusDanger)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .toolbar {
            if !isEmbeddedInSplit, let vaultFileURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: vaultFileURL) {
                        Label(L("Export"), systemImage: "square.and.arrow.up")
                            .symbolRenderingMode(.monochrome)
                    }
                }
            }
        }
    }
}
