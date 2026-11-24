import SwiftUI
import UIKit

/// Native Media Radar sheet/popover built strictly on Apple system sheet material (`Z = 1`),
/// using `ToolbarItemGroup(placement: .bottomBar)` for multi-select batch download instead of
/// stacking nested `.glassEffect()` capsules inside a Popover.
struct MediaRadarSheet: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var session: CleanroomWebKitSession
    @Bindable var scheduler: TransferScheduler
    let defaultLanes: Int
    let onPlayStream: (SniffedVariantOption, String) -> Void
    let onEnqueueSingle: (SniffedVariantOption, String, String) -> Void
    let onEnqueueBatch: ([(variant: SniffedVariantOption, domain: String, filename: String)]) -> Void
    let onInspectTransfer: (UUID) -> Void
    let onOpenDownloads: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let multiGroup = session.mediaGroups.count > 1
        let selectedGroups = session.selectedGroupsForDownload
        let effectiveIsProbing = session.isProbingMedia || session.activeProbeCount > 0
        let effectiveHost = session.currentBypassableHost
        let effectiveShieldBypassed = session.isShieldBypassedForCurrentHost
        let reachableGroupCount = session.mediaGroups.filter { !$0.isUnreachable }.count
        let isAllUnreachable: Bool = {
            if case .allUnreachable = session.capturePhase { return true }
            return !session.mediaGroups.isEmpty && reachableGroupCount == 0
        }()
        let hasZeroReachableStreams = (reachableGroupCount == 0)
            && !effectiveIsProbing
            && !session.isLoading
            && session.pendingCandidateCount == 0

        NavigationStack {
            List {
                if session.mediaGroups.isEmpty {
                    Section {
                        if session.isLoading || effectiveIsProbing || session.pendingCandidateCount > 0 {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.mini)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Inspecting streams…"))
                                        .font(.subheadline.weight(.medium))
                                    Text(L("Probing resolution tiers, durations, and byte sizes."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .accessibilityIdentifier("radar-probing-indicator")
                        } else {
                            ContentUnavailableView(
                                L("No Streams Detected Yet"),
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text(L("Play any video on the webpage—captured HLS and MP4 streams appear here automatically."))
                            )
                        }
                    }

                    if hasZeroReachableStreams, session.isShieldEnabled, let host = effectiveHost {
                        shieldEscapeHatchSection(
                            host: host,
                            isBypassed: effectiveShieldBypassed,
                            isAllUnreachable: false
                        )
                    }
                } else {
                    if effectiveIsProbing {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(L("Inspecting streams…"))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier("radar-probing-indicator")
                        }
                    }

                    if hasZeroReachableStreams, isAllUnreachable, session.isShieldEnabled, let host = effectiveHost {
                        shieldEscapeHatchSection(
                            host: host,
                            isBypassed: effectiveShieldBypassed,
                            isAllUnreachable: true
                        )
                    }

                    ForEach(Array(session.mediaGroups.enumerated()), id: \.element.id) { index, group in
                        let liveJob = group.selectedVariant.flatMap { scheduler.matchingJob(for: $0.url) }
                        Section {
                            DiscoveredMediaCardView(
                                group: group,
                                displayIndex: multiGroup ? (index + 1) : nil,
                                showBatchCheckbox: multiGroup,
                                trackedJob: liveJob,
                                onSelectVariant: { variantID in
                                    session.selectVariant(groupID: group.id, variantID: variantID)
                                },
                                onToggleChecked: {
                                    session.toggleGroupSelection(groupID: group.id)
                                },
                                onPlayStream: {
                                    guard let chosen = group.selectedVariant else { return }
                                    let trimmedTitle = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let displayTitle = trimmedTitle.isEmpty
                                        ? group.outputFilename(indexSuffix: multiGroup ? (index + 1) : nil)
                                        : trimmedTitle
                                    onPlayStream(chosen, displayTitle)
                                },
                                onDownloadSingle: {
                                    guard let chosen = group.selectedVariant else { return }
                                    let filename = group.outputFilename(indexSuffix: multiGroup ? (index + 1) : nil)
                                    onEnqueueSingle(chosen, group.sourceDomain, filename)
                                },
                                onInspectTransfer: onInspectTransfer,
                                onOpenDownloads: onOpenDownloads
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle(
                session.mediaGroups.isEmpty
                    ? L("Media Radar")
                    : L("Media Radar (\(session.mediaGroups.count))")
            )
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await session.enrichPendingCandidatesIfNeeded()
            }
            .toolbar {
                if !session.mediaGroups.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Clear")) {
                            session.clearCandidates()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        dismiss()
                    }
                }

                if selectedGroups.count >= 2 {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Text(L("\(selectedGroups.count) selected · \(defaultLanes)× lanes"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            var batch: [(variant: SniffedVariantOption, domain: String, filename: String)] = []
                            for (idx, grp) in session.mediaGroups.enumerated() where grp.isSelectedForDownload {
                                if let chosen = grp.selectedVariant {
                                    let name = grp.outputFilename(indexSuffix: multiGroup ? (idx + 1) : nil)
                                    batch.append((variant: chosen, domain: grp.sourceDomain, filename: name))
                                }
                            }
                            if !batch.isEmpty {
                                onEnqueueBatch(batch)
                            }
                        } label: {
                            Label(L("Download All (\(selectedGroups.count))"), systemImage: "arrow.down.circle.fill")
                                .symbolRenderingMode(.monochrome)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shieldEscapeHatchSection(
        host: String,
        isBypassed: Bool,
        isAllUnreachable: Bool
    ) -> some View {
        Section {
            if isBypassed {
                HStack(spacing: 10) {
                    Image(systemName: "shield.slash")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(tokens.statusWarning)
                        .font(.subheadline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Shield Paused on \(host)"))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(L("Media Radar remains active on this site."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        performToggleShieldBypass()
                    } label: {
                        Text(L("Resume Shield"))
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(tokens.statusSuccess)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("radar-resume-shield-button")
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("radar-shield-paused-status")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.slash")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(tokens.statusWarning)
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                isAllUnreachable
                                    ? L("Streams Unreachable Behind Shield?")
                                    : L("Anti-Adblock Blocking Stream?")
                            )
                            .font(.subheadline.weight(.medium))

                            Text(L("Anti-adblock players may block stream loading. Pausing Shield reloads only this site while Media Radar stays active."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        performToggleShieldBypass()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "shield.slash")
                                .symbolRenderingMode(.monochrome)
                            Text(L("Try Pausing Shield on \(host)"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tokens.statusWarning)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(tokens.statusWarning)
                    .accessibilityIdentifier("radar-pause-shield-button")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func performToggleShieldBypass() {
        session.toggleShieldBypassForCurrentHost()
        dismiss()
    }
}

private struct DiscoveredMediaCardView: View {
    @Environment(\.dysprosiumTokens) private var tokens

    let group: DiscoveredMediaGroup
    let displayIndex: Int?
    let showBatchCheckbox: Bool
    let trackedJob: TransferJob?
    let onSelectVariant: (String) -> Void
    let onToggleChecked: () -> Void
    let onPlayStream: () -> Void
    let onDownloadSingle: () -> Void
    let onInspectTransfer: (UUID) -> Void
    let onOpenDownloads: () -> Void

    @State private var decodedPoster: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let uiImage = decodedPoster {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.tertiarySystemFill))
                            .overlay {
                                if group.selectedVariant == nil {
                                    Image(systemName: "film.stack")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }
                }
                .task(id: group.thumbnailJPEGData) {
                    guard let data = group.thumbnailJPEGData else {
                        decodedPoster = nil
                        return
                    }
                    let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                        UIImage(data: data)
                    }.value
                    if !Task.isCancelled {
                        decodedPoster = decoded
                    }
                }
                .frame(height: 138)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let selected = group.selectedVariant, selected.isPlayableInNativePlayer {
                    Button(action: onPlayStream) {
                        ZStack {
                            Color.clear
                            Circle()
                                .fill(tokens.accent)
                                .frame(width: 40, height: 40)
                                .shadow(color: .black.opacity(0.24), radius: 6, x: 0, y: 2)
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .symbolRenderingMode(.monochrome)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(tokens.onAccent)
                                        .offset(x: 1)
                                }
                        }
                        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: 138)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Play Clean Stream"))
                    .accessibilityIdentifier("radar-poster-play-button")
                }

                if showBatchCheckbox || !group.isDownloadSupported || group.isShortClipCandidate || group.isUnreachable {
                    HStack(spacing: 6) {
                        if showBatchCheckbox && group.isDownloadSupported {
                            Button(action: onToggleChecked) {
                                Image(systemName: group.isSelectedForDownload ? "checkmark.circle.fill" : "circle")
                                    .symbolRenderingMode(.monochrome)
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(
                                        group.isSelectedForDownload ? AnyShapeStyle(tokens.accent) : AnyShapeStyle(.black.opacity(0.45)),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        if !group.isDownloadSupported {
                            Label(L("DASH · Unsupported"), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.72), in: Capsule())
                                .allowsHitTesting(false)
                        } else if let reason = group.unreachableReason {
                            Label(L("Source Unreachable · \(reason)"), systemImage: "wifi.exclamationmark")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(tokens.statusDanger.opacity(0.88), in: Capsule())
                                .allowsHitTesting(false)
                        } else if group.isShortClipCandidate {
                            Text(L("Short Clip"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                                .allowsHitTesting(false)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let dur = group.durationSeconds, dur > 0 {
                    Text(Self.formatDuration(dur))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            Text(group.isDownloadSupported ? group.outputFilename(indexSuffix: displayIndex) : group.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 8) {
                if group.variants.count > 1 {
                    Menu {
                        Picker(
                            L("Quality"),
                            selection: Binding(
                                get: { group.selectedVariant?.id ?? "" },
                                set: { onSelectVariant($0) }
                            )
                        ) {
                            ForEach(group.variants) { variant in
                                Text(variant.badgeSummary).tag(variant.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(group.selectedVariant?.badgeSummary ?? L("Quality"))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .symbolRenderingMode(.monochrome)
                                .font(.caption2)
                        }
                        .font(.caption.monospacedDigit().weight(.medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                } else if let single = group.selectedVariant {
                    Text(single.badgeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if let selected = group.selectedVariant, selected.isPlayableInNativePlayer {
                        Button(action: onPlayStream) {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .symbolRenderingMode(.monochrome)
                                Text(L("Play"))
                            }
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        }
                        .controlSize(.small)
                        .tint(tokens.accent)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("radar-play-stream-button")
                    }

                    actionCTA
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var actionCTA: some View {
        if let job = trackedJob {
            switch job.lifecycle {
            case .completed:
                Button(action: onOpenDownloads) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.monochrome)
                        Text(L("Open"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.onAccent)
                    .lineLimit(1)
                }
                .controlSize(.small)
                .tint(tokens.statusSuccess)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            case .downloading, .resolving, .muxing, .queued:
                Button {
                    onInspectTransfer(job.id)
                } label: {
                    let pct = Int((job.progressFraction * 100).rounded())
                    Text(job.lifecycle == .muxing ? L("Remuxing…") : (pct > 0 ? L("\(pct)% · Queue") : L("Queued")))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            case .paused, .failed:
                Button {
                    onInspectTransfer(job.id)
                } label: {
                    Text(job.lifecycle == .paused ? L("Paused · Inspect") : L("Failed · Inspect"))
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        } else if !group.isDownloadSupported {
            Text(L("Unsupported"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.14), in: Capsule())
        } else if group.isUnreachable {
            Button(action: onDownloadSingle) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .symbolRenderingMode(.monochrome)
                    Text(L("Try Anyway"))
                }
                .font(.caption.weight(.semibold))
            }
            .controlSize(.small)
            .tint(.secondary)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("radar-download-mp4-button")
        } else {
            Button(action: onDownloadSingle) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .symbolRenderingMode(.monochrome)
                    Text(L("Download"))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(tokens.onAccent)
            }
            .controlSize(.small)
            .tint(tokens.accent)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("radar-download-mp4-button")
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}
