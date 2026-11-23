import SwiftUI
import WebKit

enum BrowsingClearTimePreset: String, CaseIterable, Identifiable {
    case lastHour
    case last24Hours
    case today
    case last7Days
    case allTime
    case customWheel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: return "Last Hour"
        case .last24Hours: return "Last 24 Hours"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .allTime: return "All Time"
        case .customWheel: return "Custom Time…"
        }
    }

    func resolvedCutoff(now: Date = Date(), customDate: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .lastHour:
            return now.addingTimeInterval(-3_600)
        case .last24Hours:
            return now.addingTimeInterval(-86_400)
        case .today:
            return cal.startOfDay(for: now)
        case .last7Days:
            let todayStart = cal.startOfDay(for: now)
            return cal.date(byAdding: .day, value: -6, to: todayStart) ?? now.addingTimeInterval(-7 * 86_400)
        case .allTime:
            return .distantPast
        case .customWheel:
            return min(customDate, now)
        }
    }
}

private func formatStorageBytes(_ bytes: UInt64) -> String {
    DysprosiumFormatters.bytes(Int64(min(bytes, UInt64(Int64.max))))
}

/// Zero-Ghost-Storage & Website Data Control Center with live disk footprint inspection,
/// per-site Website Data Manager navigation, explicit Timeframe selection (including Apple's native
/// `.wheel` `DatePicker`), independent History / Cache / Cookies+Sessions / Tabs scopes,
/// and mandatory destructive confirmation with honest reclaimed-byte feedback.
struct ClearBrowsingDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var browserStore: CleanroomBrowserStore
    let targetProfileID: String?

    @State private var selectedPreset: BrowsingClearTimePreset
    @State private var customCutoffDate: Date = Date().addingTimeInterval(-3_600 * 6)
    @State private var includeHistory: Bool = true
    @State private var includeCache: Bool = true
    @State private var includeCookiesAndSessions: Bool = false
    @State private var closeStandardTabs: Bool = false
    @State private var isConfirmingClear: Bool = false
    @State private var isExecutingClear: Bool = false
    @State private var matchingHistoryCount: Int = 0
    @State private var footprint: BrowserStorageFootprint?
    @State private var isLoadingFootprint: Bool = true
    @State private var lastClearReport: BrowsingClearReport?

    init(
        browserStore: CleanroomBrowserStore,
        initialPreset: BrowsingClearTimePreset = .lastHour,
        targetProfileID: String? = nil
    ) {
        self.browserStore = browserStore
        self.targetProfileID = targetProfileID
        _selectedPreset = State(initialValue: initialPreset)
    }

    private var resolvedProfileID: String {
        targetProfileID ?? browserStore.activeProfileID
    }

    private var resolvedProfile: BrowserProfile {
        browserStore.profile(for: resolvedProfileID) ?? browserStore.activeProfile
    }

    private var targetTokens: DysprosiumTokens {
        resolvedProfile.tokens
    }

    private var activeCutoffDate: Date {
        selectedPreset.resolvedCutoff(customDate: customCutoffDate)
    }

    private var standardTabCount: Int {
        browserStore.tabs(forProfileID: resolvedProfileID).count
    }

    private var hasAnyScopeSelected: Bool {
        includeHistory || includeCache || includeCookiesAndSessions || closeStandardTabs
    }

    private var confirmationSummaryText: String {
        var parts: [String] = []
        if includeHistory {
            parts.append("History (\(matchingHistoryCount))")
        }
        if includeCache {
            parts.append("Cache")
        }
        if includeCookiesAndSessions {
            parts.append("Cookies & Logins")
        }
        if closeStandardTabs {
            parts.append("\(standardTabCount) \(standardTabCount == 1 ? "Tab" : "Tabs")")
        }
        return parts.joined(separator: ", ")
    }

    private func reclaimedHeadline(for report: BrowsingClearReport) -> String {
        let remainingTemp = footprint?.stagingTempBytes ?? 0
        let ghostSuffix = remainingTemp == 0
            ? "0 ghost files remaining"
            : "\(formatStorageBytes(remainingTemp)) temp remaining"
        if report.bytesReclaimed > 0 {
            return "Freed \(formatStorageBytes(report.bytesReclaimed)) · \(ghostSuffix)"
        }
        return "Cleared cleanly · \(ghostSuffix)"
    }

    private func reclaimedDetailSummary(for report: BrowsingClearReport) -> String? {
        var details: [String] = []
        if report.historyEntriesRemoved > 0 {
            details.append("\(report.historyEntriesRemoved) history")
        }
        if report.websiteRecordsRemoved > 0 {
            details.append("\(report.websiteRecordsRemoved) site \(report.websiteRecordsRemoved == 1 ? "record" : "records")")
        }
        if report.cookiesRemoved > 0 {
            details.append("\(report.cookiesRemoved) \(report.cookiesRemoved == 1 ? "cookie" : "cookies")")
        }
        if report.closedTabCount > 0 {
            details.append("\(report.closedTabCount) \(report.closedTabCount == 1 ? "tab" : "tabs") closed")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                if browserStore.isMultiProfileEnabled {
                    let profileTokens = resolvedProfile.tokens
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: resolvedProfile.symbolName)
                                .symbolRenderingMode(.monochrome)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(profileTokens.accent)
                                .frame(width: 28, height: 28)
                                .background(profileTokens.accentSubtleFill, in: Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Profile: \(resolvedProfile.name)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Downloads Vault and other profiles remain untouched.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 1. Live Storage Footprint & Per-Site Website Data Manager
                Section {
                    if let report = lastClearReport {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.monochrome)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(tokens.statusSuccess)
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(reclaimedHeadline(for: report))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.primary)

                                if let detail = reclaimedDetailSummary(for: report) {
                                    Text(detail)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("clear-data-reclaimed-banner")
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total Reclaimable Storage")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("SQLite, WebKit caches, favicons & staging")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if let footprint {
                            Text(formatStorageBytes(footprint.totalBytes))
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(targetTokens.accent)
                                .accessibilityIdentifier("clear-data-total-footprint")
                        } else if isLoadingFootprint {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("—")
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    footprintBreakdownRow(
                        title: "History Database (SQLite)",
                        bytes: footprint?.historySQLiteBytes
                    )
                    footprintBreakdownRow(
                        title: "WebKit Cache & Storage",
                        bytes: footprint?.webKitCacheBytes
                    )
                    footprintBreakdownRow(
                        title: "Favicon Cache",
                        bytes: footprint?.faviconCacheBytes
                    )
                    footprintBreakdownRow(
                        title: "Staging & Temp Files",
                        bytes: footprint?.stagingTempBytes
                    )

                    NavigationLink {
                        WebsiteDataManagerView(
                            browserStore: browserStore,
                            targetProfileID: resolvedProfileID
                        ) {
                            await reloadFootprint()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Label("Manage Website Data", systemImage: "globe")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.primary)

                            Spacer(minLength: 8)

                            if let count = footprint?.websiteDomainCount {
                                Text("\(count) \(count == 1 ? "site" : "sites")")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            } else {
                                Text("—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("clear-data-manage-website-data-link")
                } header: {
                    Text("Storage Footprint")
                } footer: {
                    Text("Measured live from local disk. Inspect or remove cookies, storage, and caches per site.")
                }

                // 2. Timeframe
                Section {
                    Picker("Time Range", selection: $selectedPreset) {
                        ForEach(BrowsingClearTimePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if selectedPreset == .customWheel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Clear Everything Since")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            DatePicker(
                                "Clear Since",
                                selection: $customCutoffDate,
                                in: ...Date(),
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Timeframe")
                } footer: {
                    if selectedPreset == .allTime {
                        Text("Applies across your entire local browsing history and website storage.")
                    } else {
                        Text("Only records and cached data created after \(activeCutoffDate.formatted(date: .abbreviated, time: .shortened)) will be removed.")
                    }
                }

                // 3. Scopes
                Section {
                    Toggle(isOn: $includeHistory) {
                        clearScopeRowLabel(
                            icon: "clock.arrow.circlepath",
                            title: "Browsing History",
                            badge: "\(matchingHistoryCount)",
                            subtitle: "Deletes SQLite history rows and runs VACUUM + WAL truncation to reclaim disk pages.",
                            isDestructiveWarning: false
                        )
                    }

                    Toggle(isOn: $includeCache) {
                        clearScopeRowLabel(
                            icon: "internaldrive",
                            title: "Cached Images & Files",
                            badge: nil,
                            subtitle: "Clears WebKit disk, memory & Fetch cache, favicons, and orphaned staging/temp files without signing you out.",
                            isDestructiveWarning: false
                        )
                    }

                    Toggle(isOn: $includeCookiesAndSessions) {
                        clearScopeRowLabel(
                            icon: "key.slash",
                            title: "Cookies & Login Sessions",
                            badge: nil,
                            subtitle: "Clears cookies, HttpOnly tokens, LocalStorage, SessionStorage, IndexedDB, Service Workers, and persisted transfer auth cookies — signs you out of websites.",
                            isDestructiveWarning: includeCookiesAndSessions
                        )
                    }

                    Toggle(isOn: $closeStandardTabs) {
                        clearScopeRowLabel(
                            icon: "xmark.square",
                            title: "Close Open Tabs (\(standardTabCount))",
                            badge: nil,
                            subtitle: browserStore.isMultiProfileEnabled
                                ? "Closes all open tabs in \(resolvedProfile.name), clears its recently closed tabs, and resets back/forward history."
                                : "Closes all standard tabs, clears recently closed tabs, and resets back/forward history.",
                            isDestructiveWarning: false
                        )
                    }
                } header: {
                    Text("What Gets Cleared")
                } footer: {
                    Text("Favorites, folders, and downloaded files in your Vault are never touched.")
                }

                // 4. Destructive Execution
                Section {
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        HStack {
                            Spacer()
                            if isExecutingClear {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isExecutingClear ? "Clearing Storage…" : "Clear Selected Data…")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!hasAnyScopeSelected || isExecutingClear)
                    .accessibilityIdentifier("clear-data-execute-button")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
            .navigationTitle("Clear Browsing Data")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await reloadFootprint()
            }
            .task(id: activeCutoffDate) {
                await reloadMatchingHistoryCount()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(
                            lastClearReport != nil ? "Done" : "Cancel",
                            systemImage: lastClearReport != nil ? "checkmark" : "xmark"
                        )
                    }
                }
            }
            .confirmationDialog(
                browserStore.isMultiProfileEnabled
                    ? "Clear \(confirmationSummaryText) in \(resolvedProfile.name)?"
                    : "Clear \(confirmationSummaryText)?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear Now (\(selectedPreset.title))", role: .destructive) {
                    isExecutingClear = true
                    let cutoff = activeCutoffDate
                    let opts = CleanroomBrowserStore.BrowsingClearOptions(
                        includeHistory: includeHistory,
                        includeCache: includeCache,
                        includeCookiesAndSessions: includeCookiesAndSessions,
                        closeStandardTabs: closeStandardTabs
                    )
                    Task { @MainActor in
                        let report = await browserStore.performClearBrowsingData(
                            since: cutoff,
                            options: opts,
                            profileID: resolvedProfileID
                        )
                        await reloadFootprint()
                        await reloadMatchingHistoryCount()
                        withAnimation(.snappy(duration: 0.22)) {
                            lastClearReport = report
                            isExecutingClear = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if includeCookiesAndSessions {
                    Text("This cannot be undone and will sign you out of active website sessions.")
                } else {
                    Text("This action cannot be undone. Active website login sessions will be preserved.")
                }
            }
        }
        .presentationDetents([.large])
    }

    @MainActor
    private func reloadFootprint() async {
        isLoadingFootprint = true
        let measured = await browserStore.computeStorageFootprint(profileID: resolvedProfileID)
        if !Task.isCancelled {
            footprint = measured
            isLoadingFootprint = false
        }
    }

    @MainActor
    private func reloadMatchingHistoryCount() async {
        let store = browserStore.historyStore
        let cutoff = activeCutoffDate
        let pid = resolvedProfileID
        let count = await Task.detached(priority: .userInitiated) {
            store.countEntries(since: cutoff, profileID: pid)
        }.value
        if !Task.isCancelled {
            matchingHistoryCount = count
        }
    }

    private func footprintBreakdownRow(title: String, bytes: UInt64?) -> some View {
        LabeledContent(title) {
            Text(bytes.map(formatStorageBytes) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(bytes == 0 ? .secondary : .primary)
        }
        .font(.subheadline)
    }

    private func clearScopeRowLabel(
        icon: String,
        title: String,
        badge: String?,
        subtitle: String,
        isDestructiveWarning: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDestructiveWarning ? targetTokens.statusDanger : targetTokens.accent)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let badge {
                        Text(badge)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isDestructiveWarning ? tokens.statusDanger : .secondary)
            }
        }
    }
}

// MARK: - Per-Site Website Data Manager (Cookies, Storage, Cache, Service Workers)

struct WebsiteDataManagerView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var browserStore: CleanroomBrowserStore
    var targetProfileID: String? = nil
    var onDidMutate: (@MainActor () async -> Void)? = nil

    private var resolvedProfileID: String {
        targetProfileID ?? browserStore.activeProfileID
    }

    private var resolvedProfile: BrowserProfile {
        browserStore.profile(for: resolvedProfileID) ?? browserStore.activeProfile
    }

    private var targetTokens: DysprosiumTokens {
        resolvedProfile.tokens
    }

    @State private var domains: [WebsiteDataDomainSummary] = []
    @State private var isLoading: Bool = true
    @State private var isRemovingAll: Bool = false
    @State private var searchQuery: String = ""
    @State private var isConfirmingRemoveAll: Bool = false

    private static let nonWorkerStorageTypes: Set<String> = [
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeFileSystem,
        WKWebsiteDataTypeMediaKeys,
        WKWebsiteDataTypeHashSalt
    ]

    private var filteredDomains: [WebsiteDataDomainSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return domains }
        return domains.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if isLoading && domains.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning website data…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else if domains.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Website Data",
                        systemImage: "checkmark.shield",
                        description: Text("No sites currently hold cookies, web storage, caches, or service workers.")
                    )
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    if filteredDomains.isEmpty {
                        ContentUnavailableView.search(text: searchQuery)
                    } else {
                        ForEach(filteredDomains) { domain in
                            websiteDomainRow(domain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeSingleDomain(domain)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(tokens.statusDanger)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeSingleDomain(domain)
                                    } label: {
                                        Label("Remove Site Data", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Websites (\(filteredDomains.count))")
                        Spacer()
                        if !searchQuery.isEmpty {
                            Text("of \(domains.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.monospacedDigit())
                } footer: {
                    Text("Swipe left on any site to purge its WebKit records, HttpOnly cookies, cached favicon, and live tab storage.")
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingRemoveAll = true
                    } label: {
                        HStack {
                            Spacer()
                            if isRemovingAll {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isRemovingAll ? "Removing All Website Data…" : "Remove All Website Data…")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isRemovingAll)
                    .accessibilityIdentifier("website-data-remove-all-button")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .searchable(text: $searchQuery, prompt: "Filter websites…")
        .navigationTitle(
            browserStore.isMultiProfileEnabled
                ? "Website Data · \(resolvedProfile.name)"
                : "Website Data"
        )
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDomains()
        }
        .refreshable {
            await loadDomains()
        }
        .confirmationDialog(
            browserStore.isMultiProfileEnabled
                ? "Remove All Website Data in \(resolvedProfile.name)?"
                : "Remove All Website Data?",
            isPresented: $isConfirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All (\(domains.count) \(domains.count == 1 ? "Site" : "Sites"))", role: .destructive) {
                removeAllDomains()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                browserStore.isMultiProfileEnabled
                    ? "Deletes all site cookies, HttpOnly login sessions, LocalStorage, caches, and service workers in \(resolvedProfile.name). Other profiles are untouched."
                    : "Deletes all site cookies, HttpOnly login sessions, LocalStorage, caches, and service workers. This cannot be undone."
            )
        }
    }

    @ViewBuilder
    private func websiteDomainRow(_ domain: WebsiteDataDomainSummary) -> some View {
        let hasWorkers = domain.dataTypes.contains(WKWebsiteDataTypeServiceWorkerRegistrations)
        let hasStorage = !domain.dataTypes.isDisjoint(with: Self.nonWorkerStorageTypes)
            || (domain.hasStorage && !hasWorkers)

        VStack(alignment: .leading, spacing: 6) {
            Text(domain.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if domain.hasCookies || hasStorage || domain.hasCache || hasWorkers {
                HStack(spacing: 5) {
                    if domain.hasCookies {
                        categoryTag("Cookies", foreground: targetTokens.accent, background: targetTokens.accentSubtleFill)
                    }
                    if hasStorage {
                        categoryTag("Storage", foreground: .primary, background: Color(.tertiarySystemFill))
                    }
                    if domain.hasCache {
                        categoryTag("Cache", foreground: .secondary, background: Color(.tertiarySystemFill))
                    }
                    if hasWorkers {
                        categoryTag("Workers", foreground: tokens.privateAccent, background: tokens.privateSubtleFill)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func categoryTag(_ title: String, foreground: Color, background: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    @MainActor
    private func loadDomains() async {
        isLoading = true
        let fetched = await browserStore.fetchWebsiteDataDomains(profileID: resolvedProfileID)
        if !Task.isCancelled {
            domains = fetched
            isLoading = false
        }
    }

    private func removeSingleDomain(_ domain: WebsiteDataDomainSummary) {
        let targetName = domain.displayName
        withAnimation(.snappy(duration: 0.2)) {
            domains.removeAll { $0.id == domain.id }
        }
        Task { @MainActor in
            await browserStore.removeWebsiteData(forDisplayNames: [targetName], profileID: resolvedProfileID)
            let updated = await browserStore.fetchWebsiteDataDomains(profileID: resolvedProfileID)
            withAnimation(.snappy(duration: 0.2)) {
                domains = updated
            }
            await onDidMutate?()
        }
    }

    private func removeAllDomains() {
        let names = Set(domains.map(\.displayName))
        guard !names.isEmpty else { return }
        isRemovingAll = true
        Task { @MainActor in
            await browserStore.removeWebsiteData(forDisplayNames: names, profileID: resolvedProfileID)
            let updated = await browserStore.fetchWebsiteDataDomains(profileID: resolvedProfileID)
            withAnimation(.snappy(duration: 0.22)) {
                domains = updated
                isRemovingAll = false
            }
            await onDidMutate?()
        }
    }
}
