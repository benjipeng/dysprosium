import SwiftUI

/// Native `.insetGrouped` settings, Lanthanide Design Token studio, storage hygiene & runtime diagnostics.
/// Zero custom backdrop shaders—relies 100% on system `Color(.systemGroupedBackground)`.
struct EngineStatusView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var scheduler: TransferScheduler
    @Bindable var browserStore: CleanroomBrowserStore
    @State private var probe: RuntimeProbeSummary?
    @State private var freeDiskSpaceBytes: Int64?
    @State private var backupExcluded: Bool = true
    @State private var downloadedFileCount: Int = 0
    @State private var browserFootprint: BrowserStorageFootprint?
    @State private var isShowingFilterSheet: Bool = false
    @State private var isShowingClearStorageSheet: Bool = false
    @State private var isShowingSaveFolderPicker: Bool = false
    @State private var resetMoveOffer: (sourceDir: URL, count: Int)?
    private var contentBlocker = CleanroomContentBlocker.shared
    private var saveFolderManager = CustomSaveFolderManager.shared
    @Bindable private var fingerprintShield = FingerprintShieldEngine.shared

    var body: some View {
        List {
            Section {
                DysprosiumPaletteSelectorRows()

                HStack(spacing: 12) {
                    Text("Web Dark Mode")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Picker("Web Dark Mode", selection: $browserStore.webDarkModeBehavior) {
                        ForEach(DarkReaderEngine.WebDarkModeBehavior.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 196)
                    .accessibilityIdentifier("engine-web-dark-mode-picker")
                }

                WebDarkThemeSwatchRow(
                    selectedPreset: $browserStore.webDarkThemePreset,
                    modeBehavior: $browserStore.webDarkModeBehavior
                )
            } header: {
                Text("Appearance")
            } footer: {
                Text("Auto adapts light-only websites when iOS is in Dark Mode; On applies the chosen web theme at all times.")
            }

            Section {
                Picker("Search Engine", selection: $browserStore.searchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .accessibilityIdentifier("engine-search-engine-picker")

                if browserStore.searchEngine == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("https://example.com/search?q=%s", text: $browserStore.customSearchTemplate)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .font(.subheadline.monospaced())
                            .accessibilityIdentifier("engine-custom-search-template-field")

                        Text("Use %s or {searchTerms} for the query placeholder.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Picker("User-Agent", selection: $browserStore.userAgentProfile) {
                    ForEach(BrowserUserAgentProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }

                Toggle("Fingerprint Shield (0-Frame)", isOn: $fingerprintShield.isEnabled)

                NavigationLink {
                    FingerprintLabView(browserStore: browserStore)
                } label: {
                    HStack(spacing: 10) {
                        Label("Fingerprint Lab", systemImage: "viewfinder.circle")
                            .symbolRenderingMode(.monochrome)
                        Spacer()
                        Text(fingerprintShield.isEnabled ? "Shield On" : "Offline")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(fingerprintShield.isEnabled ? tokens.accent : .secondary)
                    }
                }
            } header: {
                Text("Browser Identity & Privacy")
            } footer: {
                Text("Configures default search, Safari persona User-Agent, and offline WebKit fingerprint entropy auditing.")
            }

            Section("Concurrency") {
                Stepper(
                    value: $scheduler.maxConcurrentTransfers,
                    in: 1...6
                ) {
                    LabeledContent("Simultaneous Transfers", value: "\(scheduler.maxConcurrentTransfers)")
                        .font(.body.monospacedDigit())
                }

                Stepper(
                    value: $scheduler.defaultLanesPerTransfer,
                    in: 1...16
                ) {
                    LabeledContent("Default Range Lanes", value: "\(scheduler.defaultLanesPerTransfer)×")
                        .font(.body.monospacedDigit())
                }
            }

            Section("Content Shield") {
                LabeledContent(
                    "Active Filter Lists",
                    value: "\(contentBlocker.subscriptions.filter(\.isEnabled).count) / \(contentBlocker.subscriptions.count)"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent(
                    "Compiled WebKit Rules",
                    value: contentBlocker.isSyncing ? "Syncing…" : contentBlocker.activeRuleCount.formatted()
                )
                .font(.subheadline.monospacedDigit())

                Button {
                    isShowingFilterSheet = true
                } label: {
                    Label("Manage Filter Subscriptions…", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .symbolRenderingMode(.monochrome)
                }
            }
            .font(.subheadline)

            Section("Storage & Sandbox") {
                LabeledContent("Persistence Scope", value: LiveContainerEnvironment.storageTopologyDescription)
                    .font(.subheadline)
                    .foregroundStyle(LiveContainerEnvironment.hostSharedAppGroupURL != nil ? tokens.statusSuccess : .primary)

                Menu {
                    switch saveFolderManager.status {
                    case .defaultInternal:
                        Button {
                            isShowingSaveFolderPicker = true
                        } label: {
                            Label("Choose Custom Save Folder…", systemImage: "folder.badge.plus")
                        }
                    case .customActive:
                        Button {
                            isShowingSaveFolderPicker = true
                        } label: {
                            Label("Change Save Folder…", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            SaveFolderFilesLauncher.openActiveDownloadsFolder()
                        } label: {
                            Label("Show in iOS Files", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) {
                            let offer = saveFolderManager.resetToDefaultFolder()
                            if let src = offer.offerMoveFrom, offer.movableFileCount > 0 {
                                resetMoveOffer = (src, offer.movableFileCount)
                            }
                            Task { @MainActor in await refreshStorageDiagnostics() }
                        } label: {
                            Label("Reset to Default Storage", systemImage: "arrow.uturn.backward")
                        }
                    case .needsHostGrant(let folderName, _, _):
                        Button {
                            isShowingSaveFolderPicker = true
                        } label: {
                            Label("Grant Access to \"\(folderName)\"…", systemImage: "folder.badge.person.crop")
                        }
                        Divider()
                        Button(role: .destructive) {
                            _ = saveFolderManager.resetToDefaultFolder()
                            Task { @MainActor in await refreshStorageDiagnostics() }
                        } label: {
                            Label("Reset to Default Storage", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("Save Location")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Group {
                            switch saveFolderManager.status {
                            case .defaultInternal:
                                Text(LiveContainerEnvironment.displayDownloadsPath)
                                    .foregroundStyle(.secondary)
                            case .customActive(_, _, let breadcrumb):
                                Text(breadcrumb)
                                    .foregroundStyle(tokens.accent)
                            case .needsHostGrant(let folderName, _, _):
                                Label("Link \"\(folderName)\"", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(tokens.statusWarning)
                            }
                        }
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("engine-save-location-menu")

                LabeledContent(
                    "iCloud Backup",
                    value: saveFolderManager.status.isCustomActive ? "Managed by Folder" : (backupExcluded ? "Excluded" : "Included")
                )
                .foregroundStyle(saveFolderManager.status.isCustomActive ? .secondary : (backupExcluded ? tokens.statusSuccess : .secondary))

                LabeledContent(
                    "Available Space",
                    value: freeDiskSpaceBytes.map(DysprosiumFormatters.bytes) ?? "—"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent(
                    "Downloaded Files",
                    value: "\(downloadedFileCount)"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent("Browser Cache & Storage") {
                    if let browserFootprint {
                        let byteText = DysprosiumFormatters.bytes(
                            Int64(min(browserFootprint.totalBytes, UInt64(Int64.max)))
                        )
                        let siteWord = browserFootprint.websiteDomainCount == 1 ? "site" : "sites"
                        Text("\(byteText) · \(browserFootprint.websiteDomainCount) \(siteWord)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                    } else {
                        Text("Measuring…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    isShowingClearStorageSheet = true
                } label: {
                    Label("Website Data & Storage…", systemImage: "internaldrive")
                        .symbolRenderingMode(.monochrome)
                }
                .accessibilityIdentifier("engine-website-data-storage-button")
            }
            .font(.subheadline)

            Section("Runtime") {
                LabeledContent(
                    "Host Container",
                    value: (probe?.isLiveContainerGuest == true) ? "LiveContainer Guest" : "Standalone"
                )
                LabeledContent(
                    "Background Audio Keep-Alive",
                    value: (probe?.silentAudioActive == true) ? "Active" : "Idle"
                )
                LabeledContent("HTTP Range + POSIX pwrite()", value: "Active")
                LabeledContent("HLS + AES-128 + MP4 Remux", value: "Active")
                if probe?.cpythonAvailable == true {
                    LabeledContent("Embedded Python", value: probe?.cpythonVersion ?? "3.x")
                }
            }
            .font(.subheadline)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .task {
            probe = await scheduler.runtimeSummary()
            await refreshStorageDiagnostics()
        }
        .sheet(isPresented: $isShowingFilterSheet) {
            FilterShieldManagementSheet(session: nil)
        }
        .sheet(
            isPresented: $isShowingClearStorageSheet,
            onDismiss: {
                Task { @MainActor in
                    await refreshStorageDiagnostics()
                }
            }
        ) {
            ClearBrowsingDataSheet(browserStore: browserStore)
        }
        .saveFolderPickerFlow(isPresented: $isShowingSaveFolderPicker) {
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
        .onChange(of: saveFolderManager.revision) { _, _ in
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
        .confirmationDialog(
            "Move \(resetMoveOffer?.count ?? 0) Downloads Back to Default?",
            isPresented: Binding(
                get: { resetMoveOffer != nil },
                set: { if !$0 { resetMoveOffer = nil; saveFolderManager.dismissPendingMoveOffer() } }
            ),
            titleVisibility: .visible
        ) {
            if let offer = resetMoveOffer {
                Button("Move \(offer.count) \(offer.count == 1 ? "File" : "Files")") {
                    let src = offer.sourceDir
                    resetMoveOffer = nil
                    Task { @MainActor in
                        _ = await saveFolderManager.moveExistingFiles(from: src)
                        await refreshStorageDiagnostics()
                    }
                }
                Button("Leave in Previous Folder", role: .cancel) {
                    resetMoveOffer = nil
                    saveFolderManager.dismissPendingMoveOffer()
                }
            }
        } message: {
            Text("Files left in the previous folder remain safe in iOS Files.")
        }
    }

    @MainActor
    private func refreshStorageDiagnostics() async {
        async let diskSnapshot: (excluded: Bool, freeBytes: Int64?, fileCount: Int) = Task.detached(priority: .utility) {
            (
                LiveContainerEnvironment.isBackupExclusionActive,
                LiveContainerEnvironment.availableDiskSpaceBytes,
                LiveContainerEnvironment.scanDownloadedFiles().count
            )
        }.value
        async let measuredFootprint = browserStore.computeStorageFootprint()

        let (snapshot, footprint) = await (diskSnapshot, measuredFootprint)
        guard !Task.isCancelled else { return }
        backupExcluded = snapshot.excluded
        freeDiskSpaceBytes = snapshot.freeBytes
        downloadedFileCount = snapshot.fileCount
        browserFootprint = footprint
    }
}
