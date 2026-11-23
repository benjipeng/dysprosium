import SwiftUI
import UIKit

/// Modular, 100% air-gapped FingerprintJS v4 + CreepJS-style integrity lab.
/// Designed with native iOS 27.2 `.insetGrouped` typography, calibrated Lanthanide tokens,
/// zero `.glassEffect()` on scrolling content, and full `84 pt` vertical-bar toolbar ownership.
struct FingerprintLabView: View {
    enum SignalFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case highRisk = "High Risk"
        case changed = "Changed"

        var id: String { rawValue }
    }

    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var browserStore: CleanroomBrowserStore
    @Bindable private var fingerprintShield = FingerprintShieldEngine.shared
    @State private var engine = FingerprintAuditEngine()
    @State private var selectedMode: FingerprintAuditMode = .standard
    @State private var signalFilter: SignalFilter = .all
    @State private var searchText: String = ""
    @State private var expandedSignalIDs: Set<String> = []
    @State private var showIntegrityChecks: Bool = false
    @State private var copiedVisitorID: Bool = false
    @State private var copiedJSON: Bool = false
    @State private var measuredViewport: CGSize = .zero

    private var activeSnapshot: FingerprintAuditSnapshot? {
        engine.currentSnapshot
    }

    private var changedIDs: Set<String> {
        guard let current = activeSnapshot, let base = engine.baselineSnapshot else { return [] }
        return current.changedSignalIDs(comparedTo: base)
    }

    private var baselineMap: [String: FingerprintSignalItem] {
        guard let base = engine.baselineSnapshot else { return [:] }
        return Dictionary(uniqueKeysWithValues: base.signals.map { ($0.id, $0) })
    }

    private var availableFilters: [SignalFilter] {
        engine.baselineSnapshot == nil ? [.all, .highRisk] : SignalFilter.allCases
    }

    var body: some View {
        List {
            modeAndIdentitySection

            if let snapshot = activeSnapshot, let baseline = engine.baselineSnapshot {
                baselineComparisonSection(current: snapshot, baseline: baseline)
            }

            shieldControlSection

            if let snapshot = activeSnapshot {
                integritySection(snapshot: snapshot)
                signalFilterSection(snapshot: snapshot)
                signalCategorySections(snapshot: snapshot)
            } else if let err = engine.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(tokens.statusDanger)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            guard newSize.width > 100 && newSize.height > 100 else { return }
            measuredViewport = newSize
            if engine.currentSnapshot == nil && !engine.isRunning {
                Task { await runSelectedAudit() }
            }
        }
        .onChange(of: browserStore.activeProfileID) { _, _ in
            Task { await runSelectedAudit() }
        }
        .onChange(of: fingerprintShield.isEnabled) { _, _ in
            browserStore.refreshLiveUserAgentsForFingerprintShieldToggle()
        }
        .navigationTitle("Fingerprint Lab")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter signals…")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await runSelectedAudit() }
                } label: {
                    Label("Re-run Audit", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isRunning)

                Button {
                    if engine.baselineSnapshot != nil,
                       engine.baselineSnapshot?.id == activeSnapshot?.id {
                        engine.clearBaseline()
                        if signalFilter == .changed { signalFilter = .all }
                    } else {
                        engine.pinCurrentAsBaseline()
                    }
                } label: {
                    Label(
                        engine.baselineSnapshot == nil ? "Pin Baseline" : "Update Baseline",
                        systemImage: engine.baselineSnapshot == nil ? "pin" : "pin.fill"
                    )
                }
                .disabled(activeSnapshot == nil)

                Button {
                    guard let json = activeSnapshot?.rawJSONReport else { return }
                    UIPasteboard.general.string = json
                    copiedJSON = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedJSON = false
                    }
                } label: {
                    Label(copiedJSON ? "Copied JSON" : "Copy JSON", systemImage: copiedJSON ? "checkmark" : "doc.on.doc")
                }
                .disabled(activeSnapshot == nil)
            }
        }
        .task {
            // Fallback in case onGeometryChange has not yet delivered a non-zero size.
            try? await Task.sleep(for: .milliseconds(60))
            if engine.currentSnapshot == nil && !engine.isRunning {
                await runSelectedAudit()
            }
        }
        .onChange(of: selectedMode) { _, _ in
            Task { await runSelectedAudit() }
        }
        .onChange(of: fingerprintShield.isEnabled) { _, _ in
            Task { await runSelectedAudit() }
        }
        .onChange(of: fingerprintShield.maskFoldableScreen) { _, _ in
            Task { await runSelectedAudit() }
        }
    }

    // MARK: - Hero Specimen & Mode Controls

    @ViewBuilder
    private var modeAndIdentitySection: some View {
        Section {
            Picker("Audit Posture", selection: $selectedMode) {
                ForEach(FingerprintAuditMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

            if engine.isRunning && activeSnapshot == nil {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Running Air-Gapped Audit…")
                            .font(.subheadline.weight(.medium))
                        Text("Evaluating FingerprintJS v4 & prototype integrity locally")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } else if let snapshot = activeSnapshot {
                identitySpecimenRow(snapshot: snapshot)
            }
        } header: {
            Text(
                selectedMode == .standard && browserStore.isMultiProfileEnabled
                    ? "Session Specimen · \(browserStore.activeProfile.name)"
                    : "Session Specimen"
            )
        } footer: {
            Text("Runs 100% locally inside a CSP-locked WKWebView with zero network requests. Switch modes or fold/unfold displays, then tap Re-run to compare.")
        }
    }

    @ViewBuilder
    private func identitySpecimenRow(snapshot: FingerprintAuditSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: snapshot.mode.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(modeTint(snapshot.mode))
                    Text("VISITOR ID · FPJS v\(snapshot.fpjsVersion)")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if engine.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("\(snapshot.totalDurationMs) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text(snapshot.formattedVisitorID)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)

                Spacer(minLength: 4)

                Button {
                    UIPasteboard.general.string = snapshot.visitorId
                    copiedVisitorID = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copiedVisitorID = false
                    }
                } label: {
                    Image(systemName: copiedVisitorID ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copiedVisitorID ? tokens.statusSuccess : tokens.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                        .background(
                            (copiedVisitorID ? tokens.statusSuccessFill : tokens.accentSubtleFill),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Visitor ID")
            }

            // Three calibrated semantic pills — zero clutter, high legibility in Light & Dark
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusPills(snapshot: snapshot)
                }
                VStack(alignment: .leading, spacing: 6) {
                    statusPills(snapshot: snapshot)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusPills(snapshot: FingerprintAuditSnapshot) -> some View {
        let liesClean = snapshot.lieCount == 0
        pillBadge(
            text: liesClean ? "0 Lies · Native" : "\(snapshot.lieCount) Lies",
            systemImage: liesClean ? "checkmark.seal.fill" : "exclamationmark.shield.fill",
            foreground: liesClean ? tokens.statusSuccess : tokens.statusDanger,
            background: liesClean ? tokens.statusSuccessFill : tokens.statusDangerFill
        )

        let highCount = snapshot.highRiskSignals.count
        pillBadge(
            text: "\(highCount) High Entropy",
            systemImage: highCount > 0 ? "eye.trianglebadge.exclamationmark" : "checkmark.circle.fill",
            foreground: highCount > 0 ? tokens.statusWarning : tokens.statusSuccess,
            background: highCount > 0 ? tokens.statusWarningFill : tokens.statusSuccessFill
        )

        pillBadge(
            text: "\(Int(snapshot.viewportSize.width))×\(Int(snapshot.viewportSize.height)) @\(Int(snapshot.devicePixelRatio))x",
            systemImage: "aspectratio",
            foreground: .secondary,
            background: Color(.tertiarySystemFill)
        )
    }

    private func pillBadge(text: String, systemImage: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .symbolRenderingMode(.monochrome)
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
    }

    // MARK: - 0-Frame Fingerprint Shield Controls

    @ViewBuilder
    private var shieldControlSection: some View {
        Section {
            Toggle("0-Frame Fingerprint Shield", isOn: $fingerprintShield.isEnabled)
                .font(.subheadline)

            Toggle("Mask Foldable Screen Class", isOn: $fingerprintShield.maskFoldableScreen)
                .font(.subheadline)
                .disabled(!fingerprintShield.isEnabled && selectedMode != .privateEphemeral)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        browserStore.isMultiProfileEnabled
                            ? "Active Persona · \(browserStore.activeProfile.name)"
                            : "Active Persona & Seed"
                    )
                    .font(.subheadline)
                    let activeProfile = browserStore.activeProfile
                    let persona = FingerprintShieldEngine.persona(
                        forSeed: activeProfile.fingerprintSeed,
                        profile: browserStore.userAgentProfile
                    )
                    Text("\(activeProfile.shortSeedSpecimen) · \(persona.shortLabel)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    _ = browserStore.rotateFingerprintSeed(forProfileID: browserStore.activeProfileID)
                    Task { await runSelectedAudit() }
                } label: {
                    Label("Rotate Seed", systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.caption.weight(.semibold))
                        .symbolRenderingMode(.monochrome)
                }
                .buttonStyle(.bordered)
                .tint(tokens.accent)
                .controlSize(.small)
                .disabled(engine.isRunning)
            }
        } header: {
            Text("Seeded Farbling Engine")
        } footer: {
            Text("Injects deterministic per-site Canvas, WebAudio, WebGL, DOMRect, and about:blank iframe shielding at document-start with zero native prototype leaks.")
        }
    }

    // MARK: - Baseline Diff Banner

    @ViewBuilder
    private func baselineComparisonSection(
        current: FingerprintAuditSnapshot,
        baseline: FingerprintAuditSnapshot
    ) -> some View {
        let identicalID = current.visitorId == baseline.visitorId
        let changedCount = changedIDs.count

        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: identicalID ? "link.circle.fill" : "sparkles")
                    .font(.title3)
                    .foregroundStyle(identicalID ? tokens.statusWarning : tokens.statusSuccess)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(identicalID ? "Same Visitor ID as Baseline" : "Visitor ID Rotated vs Baseline")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(identicalID ? tokens.statusWarning : tokens.statusSuccess)

                    Text("Baseline: \(baseline.mode.title) (\(Int(baseline.viewportSize.width))×\(Int(baseline.viewportSize.height))) · \(changedCount) signal\(changedCount == 1 ? "" : "s") changed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Button("Clear") {
                    engine.clearBaseline()
                    if signalFilter == .changed { signalFilter = .all }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Baseline Diff")
        }
    }

    // MARK: - CreepJS-Style Prototype & Worker Integrity

    @ViewBuilder
    private func integritySection(snapshot: FingerprintAuditSnapshot) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showIntegrityChecks) {
                ForEach(snapshot.lieChecks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.subheadline)
                            .foregroundStyle(check.passed ? tokens.statusSuccess : tokens.statusDanger)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.subheadline.weight(.medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: snapshot.lieCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(snapshot.lieCount == 0 ? tokens.statusSuccess : tokens.statusDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Integrity & Lie Detection")
                            .font(.subheadline.weight(.semibold))
                        Text("\(snapshot.lieChecks.filter(\.passed).count)/\(snapshot.lieChecks.count) native checks clean · Zero JS spoofing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Filter Bar & Signal Breakdown

    @ViewBuilder
    private func signalFilterSection(snapshot: FingerprintAuditSnapshot) -> some View {
        Section {
            Picker("Signal Filter", selection: $signalFilter) {
                ForEach(availableFilters) { filter in
                    switch filter {
                    case .all:
                        Text("All (\(snapshot.signals.count))").tag(filter)
                    case .highRisk:
                        Text("High Risk (\(snapshot.highRiskSignals.count))").tag(filter)
                    case .changed:
                        Text("Changed (\(changedIDs.count))").tag(filter)
                    }
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        } header: {
            Text("Collected Signals")
        }
    }

    @ViewBuilder
    private func signalCategorySections(snapshot: FingerprintAuditSnapshot) -> some View {
        let filtered = filteredSignals(in: snapshot)
        if filtered.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Matching Signals",
                    systemImage: "magnifyingglass",
                    description: Text(signalFilter == .changed ? "All signals match the pinned baseline identically." : "Try clearing your filter or search query.")
                )
            }
        } else {
            ForEach(FingerprintSignalCategory.allCases) { category in
                let rows = filtered.filter { $0.category == category }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { item in
                            signalRow(item: item)
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.systemImage)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func signalRow(item: FingerprintSignalItem) -> some View {
        let isExpanded = expandedSignalIDs.contains(item.id)
        let isChanged = changedIDs.contains(item.id)
        let baselineItem = baselineMap[item.id]

        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isExpanded {
                    expandedSignalIDs.remove(item.id)
                } else {
                    expandedSignalIDs.insert(item.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 6)

                    if isChanged {
                        Text("Δ")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(tokens.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tokens.accentSubtleFill, in: Capsule())
                    }

                    if item.entropyRisk != .low {
                        Text(item.entropyRisk.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(riskColor(item.entropyRisk))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(riskFill(item.entropyRisk), in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                Text(item.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? 4 : 1)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = item.riskReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(riskColor(item.entropyRisk))
                        }

                        if isChanged, let old = baselineItem {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("BASELINE → CURRENT")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(old.summary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .strikethrough()
                                Text(item.summary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(tokens.accent)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Text(item.rawDetail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                            )
                    }
                    .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func filteredSignals(in snapshot: FingerprintAuditSnapshot) -> [FingerprintSignalItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.signals.filter { item in
            switch signalFilter {
            case .all:
                break
            case .highRisk:
                guard item.entropyRisk == .high else { return false }
            case .changed:
                guard changedIDs.contains(item.id) else { return false }
            }
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(query)
                || item.id.lowercased().contains(query)
                || item.summary.lowercased().contains(query)
                || item.rawDetail.lowercased().contains(query)
        }
    }

    private func modeTint(_ mode: FingerprintAuditMode) -> Color {
        switch mode {
        case .standard: return tokens.accent
        case .privateEphemeral: return tokens.privateAccent
        case .shieldPaused: return tokens.statusWarning
        }
    }

    private func riskColor(_ risk: FingerprintEntropyRisk) -> Color {
        switch risk {
        case .high: return tokens.statusWarning
        case .medium: return tokens.accent
        case .low: return .secondary
        }
    }

    private func riskFill(_ risk: FingerprintEntropyRisk) -> Color {
        switch risk {
        case .high: return tokens.statusWarningFill
        case .medium: return tokens.accentSubtleFill
        case .low: return Color(.tertiarySystemFill)
        }
    }

    private func runSelectedAudit() async {
        let resolvedSize: CGSize
        if measuredViewport.width > 100 && measuredViewport.height > 100 {
            resolvedSize = measuredViewport
        } else if let sceneSize = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .effectiveGeometry.coordinateSpace.bounds.size,
                  sceneSize.width > 100 && sceneSize.height > 100 {
            resolvedSize = sceneSize
        } else {
            resolvedSize = CGSize(width: 393, height: 852)
        }
        let scopedSeed: String? = (selectedMode == .standard && fingerprintShield.isEnabled)
            ? browserStore.activeProfile.fingerprintSeed
            : nil
        await engine.runAudit(
            mode: selectedMode,
            viewportSize: resolvedSize,
            userAgentProfile: browserStore.userAgentProfile,
            customSeed: scopedSeed
        )
    }
}
