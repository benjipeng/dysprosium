import SwiftUI

/// Native `.insetGrouped` settings, Lanthanide Design Token studio, storage hygiene & runtime diagnostics.
/// Zero custom backdrop shaders—relies 100% on system `Color(.systemGroupedBackground)`.
struct EngineStatusView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var scheduler: TransferScheduler
    @Bindable var browserStore: CleanroomBrowserStore
    @State private var probe: RuntimeProbeSummary?
    @State private var freeDiskSpaceBytes: Int64?
    @State private var downloadedFileCount: Int = 0
    @State private var browserFootprint: BrowserStorageFootprint?
    @State private var isShowingFilterSheet: Bool = false
    @State private var isShowingClearStorageSheet: Bool = false
    @State private var isShowingProfilesSheet: Bool = false
    @State private var isViewVisible: Bool = false
    @State private var saveFolderFlow = SaveFolderFlowState()
    private var contentBlocker = CleanroomContentBlocker.shared
    private var saveFolderManager = CustomSaveFolderManager.shared
    @Bindable private var fingerprintShield = FingerprintShieldEngine.shared
    @Bindable private var languageStore = AppLanguageStore.shared

    var body: some View {
        List {
            Section {
                DysprosiumPaletteSelectorRows(
                    title: L("Accent"),
                    profileContextName: browserStore.isMultiProfileEnabled
                        ? browserStore.activeProfile.localizedDisplayName
                        : nil,
                    onSelect: { preset in
                        browserStore.setActiveProfilePalette(preset)
                    }
                )

                HStack(spacing: 12) {
                    Text(L("Web Dark Mode"))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Picker(L("Web Dark Mode"), selection: $browserStore.webDarkModeBehavior) {
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

                Picker(L("Language"), selection: $languageStore.selection) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.pickerTitle).tag(lang)
                    }
                }
                .accessibilityIdentifier("engine-language-picker")
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("Auto adapts light-only websites when iOS is in Dark Mode; On applies the chosen web theme at all times. In-app language changes take effect immediately."))
            }

            Section {
                Button {
                    isShowingProfilesSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Label(L("Profiles"), systemImage: browserStore.isMultiProfileEnabled ? browserStore.activeProfile.symbolName : "person.2")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 8)
                        Text(
                            browserStore.isMultiProfileEnabled
                                ? L("\(browserStore.activeProfile.localizedDisplayName) (\(browserStore.profiles.count))")
                                : browserStore.activeProfile.localizedDisplayName
                        )
                        .font(.subheadline)
                        .foregroundStyle(browserStore.isMultiProfileEnabled ? tokens.accent : Color.secondary)
                        .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(Color.primary)
                .tint(Color.primary)
                .accessibilityIdentifier("engine-profiles-button")
            }

            Section {
                Picker(L("Search Engine"), selection: $browserStore.searchEngine) {
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

                        Text(L("Use %s or {searchTerms} for the query placeholder."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Picker(L("User-Agent"), selection: $browserStore.userAgentProfile) {
                    ForEach(BrowserUserAgentProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }

                Toggle(L("Fingerprint Shield (0-Frame)"), isOn: $fingerprintShield.isEnabled)

                NavigationLink {
                    FingerprintLabView(browserStore: browserStore)
                } label: {
                    HStack(spacing: 10) {
                        Label(L("Fingerprint Lab"), systemImage: "viewfinder.circle")
                            .symbolRenderingMode(.monochrome)
                        Spacer()
                        Text(fingerprintShield.isEnabled ? L("Shield On") : L("Offline"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(fingerprintShield.isEnabled ? tokens.accent : .secondary)
                    }
                }
            } header: {
                Text(
                    browserStore.isMultiProfileEnabled
                        ? L("Browser Identity · \(browserStore.activeProfile.localizedDisplayName)")
                        : L("Browser Identity & Privacy")
                )
            } footer: {
                Text(L("Configures default search, Safari persona User-Agent, and offline WebKit fingerprint entropy auditing."))
            }

            Section(L("Concurrency")) {
                Stepper(
                    value: $scheduler.maxConcurrentTransfers,
                    in: 1...6
                ) {
                    LabeledContent(L("Simultaneous Transfers"), value: "\(scheduler.maxConcurrentTransfers)")
                        .font(.body.monospacedDigit())
                }

                Stepper(
                    value: $scheduler.defaultLanesPerTransfer,
                    in: 1...16
                ) {
                    LabeledContent(L("Default Range Lanes"), value: "\(scheduler.defaultLanesPerTransfer)×")
                        .font(.body.monospacedDigit())
                }
            }

            Section(L("Content Shield")) {
                LabeledContent(
                    L("Active Filter Lists"),
                    value: "\(contentBlocker.subscriptions.filter(\.isEnabled).count) / \(contentBlocker.subscriptions.count)"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent(
                    L("Compiled WebKit Rules"),
                    value: contentBlocker.isSyncing ? L("Syncing…") : contentBlocker.activeRuleCount.formatted(.number.locale(AppLocalization.currentLocale))
                )
                .font(.subheadline.monospacedDigit())

                Button {
                    isShowingFilterSheet = true
                } label: {
                    Label(L("Manage Filter Subscriptions…"), systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .symbolRenderingMode(.monochrome)
                }
            }
            .font(.subheadline)

            Section(L("Storage")) {
                SaveLocationRow(
                    flow: $saveFolderFlow,
                    accessibilityID: "engine-save-location-menu"
                ) {
                    Task { @MainActor in await refreshStorageDiagnostics() }
                }

                LabeledContent(
                    L("Available Space"),
                    value: freeDiskSpaceBytes.map(DysprosiumFormatters.bytes) ?? "—"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent(
                    L("Downloaded Files"),
                    value: "\(downloadedFileCount)"
                )
                .font(.subheadline.monospacedDigit())

                LabeledContent(
                    browserStore.isMultiProfileEnabled
                        ? L("Browser Cache (\(browserStore.activeProfile.localizedDisplayName))")
                        : L("Browser Cache & Storage")
                ) {
                    if let browserFootprint {
                        let byteText = DysprosiumFormatters.bytes(
                            Int64(min(browserFootprint.totalBytes, UInt64(Int64.max)))
                        )
                        Text(L("\(byteText) · \(browserFootprint.websiteDomainCount) sites"))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                    } else {
                        Text(L("Measuring…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    isShowingClearStorageSheet = true
                } label: {
                    Label(L("Website Data & Storage…"), systemImage: "internaldrive")
                        .symbolRenderingMode(.monochrome)
                }
                .accessibilityIdentifier("engine-website-data-storage-button")
            }
            .font(.subheadline)

            Section(L("Runtime")) {
                LabeledContent(
                    L("Host Container"),
                    value: (probe?.isLiveContainerGuest == true) ? L("LiveContainer Guest") : L("Standalone")
                )
                LabeledContent(
                    L("Background Audio Keep-Alive"),
                    value: (probe?.silentAudioActive == true) ? L("Active") : L("Idle")
                )
                LabeledContent(L("HTTP Range + POSIX pwrite()"), value: L("Active"))
                LabeledContent(L("HLS + AES-128 + MP4 Remux"), value: L("Active"))
                if probe?.cpythonAvailable == true {
                    LabeledContent(L("Embedded Python"), value: probe?.cpythonVersion ?? "3.x")
                }
            }
            .font(.subheadline)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .onAppear {
            isViewVisible = true
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
        .onDisappear {
            isViewVisible = false
        }
        .task {
            probe = await scheduler.runtimeSummary()
            await refreshStorageDiagnostics()
        }
        .sheet(isPresented: $isShowingProfilesSheet) {
            ProfileManagementSheet(browserStore: browserStore)
        }
        .sheet(isPresented: $isShowingFilterSheet) {
            FilterShieldManagementSheet(session: nil, browserStore: browserStore)
        }
        .sheet(
            isPresented: $isShowingClearStorageSheet,
            onDismiss: {
                Task { @MainActor in
                    await refreshStorageDiagnostics()
                }
            }
        ) {
            ClearBrowsingDataSheet(browserStore: browserStore, targetProfileID: browserStore.activeProfileID)
        }
        .onChange(of: browserStore.activeProfileID) { _, _ in
            guard isViewVisible else { return }
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
        .onChange(of: fingerprintShield.isEnabled) { _, _ in
            browserStore.refreshLiveUserAgentsForFingerprintShieldToggle()
        }
        .saveFolderPickerFlow($saveFolderFlow) {
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
        .onChange(of: saveFolderManager.revision) { _, _ in
            Task { @MainActor in
                await refreshStorageDiagnostics()
            }
        }
    }

    @MainActor
    private func refreshStorageDiagnostics() async {
        async let diskSnapshot: (freeBytes: Int64?, fileCount: Int) = Task.detached(priority: .utility) {
            (
                LiveContainerEnvironment.availableDiskSpaceBytes,
                LiveContainerEnvironment.scanDownloadedFiles().count
            )
        }.value
        async let measuredFootprint = browserStore.computeStorageFootprint()

        let (snapshot, footprint) = await (diskSnapshot, measuredFootprint)
        guard !Task.isCancelled else { return }
        freeDiskSpaceBytes = snapshot.freeBytes
        downloadedFileCount = snapshot.fileCount
        browserFootprint = footprint
    }
}
