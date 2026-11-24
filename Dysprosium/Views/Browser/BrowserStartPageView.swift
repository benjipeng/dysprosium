import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pure-utility, zero-slogan Browser Landing Page backed by:
/// 1. `4`/`8` even-column Favorites & Folder hierarchy (`FavoriteFolderMosaicView`).
/// 2. Flat row-virtualized `LazyVStack` + cursor-paginated SQLite3 WAL History (`80` items per window),
///    with predictable relative time windows (`All`, `24h`, `Today`, `Yesterday`, `7 Days`, `30 Days`),
///    Apple's native scrollable `.wheel` `DatePicker` jump-to-date, and unified `ClearBrowsingDataSheet`.
struct BrowserStartPageView: View {
    private enum HistoryTimeScope: String, CaseIterable, Identifiable {
        case all
        case past24Hours
        case today
        case yesterday
        case past7Days
        case past30Days
        case specificDate

        var id: String { rawValue }

        static let barPresets: [HistoryTimeScope] = [
            .all, .past24Hours, .today, .yesterday, .past7Days, .past30Days
        ]

        var label: String {
            switch self {
            case .all: return L("All")
            case .past24Hours: return L("24h")
            case .today: return L("Today")
            case .yesterday: return L("Yesterday")
            case .past7Days: return L("7 Days")
            case .past30Days: return L("30 Days")
            case .specificDate: return L("Date")
            }
        }

        func resolvedBounds(now: Date = Date(), customDay: Date) -> (start: Date?, end: Date?) {
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: now)
            switch self {
            case .all:
                return (nil, nil)
            case .past24Hours:
                return (now.addingTimeInterval(-86_400), nil)
            case .today:
                return (todayStart, nil)
            case .yesterday:
                let yStart = cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart.addingTimeInterval(-86_400)
                return (yStart, todayStart)
            case .past7Days:
                let start = cal.date(byAdding: .day, value: -6, to: todayStart) ?? now.addingTimeInterval(-7 * 86_400)
                return (start, nil)
            case .past30Days:
                let start = cal.date(byAdding: .day, value: -29, to: todayStart) ?? now.addingTimeInterval(-30 * 86_400)
                return (start, nil)
            case .specificDate:
                let dayStart = cal.startOfDay(for: customDay)
                let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                return (dayStart, nextDay)
            }
        }
    }

    private enum HistoryVirtualRow: Identifiable {
        case dayHeader(BrowserHistoryDaySummary, topSpacing: CGFloat)
        case singleEntry(BrowserHistoryEntry)
        case pairEntries(BrowserHistoryEntry, BrowserHistoryEntry?)
        case loadMoreSentinel

        var id: String {
            switch self {
            case .dayHeader(let summary, _):
                return "hdr-\(summary.dayYMD)"
            case .singleEntry(let entry):
                return "one-\(entry.id)"
            case .pairEntries(let left, let right):
                return "pair-\(left.id)-\(right?.id ?? "nil")"
            case .loadMoreSentinel:
                return "history-load-more"
            }
        }
    }

    private enum FavoriteGridTile: Identifiable {
        case folder(BrowserFavoriteFolder)
        case bookmark(BrowserBookmark)

        var id: String {
            switch self {
            case .folder(let folder): return "folder-\(folder.id)"
            case .bookmark(let bookmark): return "bm-\(bookmark.id)"
            }
        }
    }

    private struct ExportedBookmarksItem: Identifiable {
        let id = UUID()
        let fileURL: URL
    }

    nonisolated private static let historyPageSize = 80

    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var browserStore: CleanroomBrowserStore
    let topContentMargin: CGFloat
    let onSelectURL: (String) -> Void
    var onDismissContainer: (() -> Void)? = nil

    @State private var canvasWidth: CGFloat = 669
    @State private var viewportMetrics: DuoViewportMetrics? = nil
    @State private var activeFolderID: String? = nil

    // Folder & Bookmark modals
    @State private var editorTarget: FavoriteEditorTarget? = nil
    @State private var isCreatingFolderAlert: Bool = false
    @State private var newFolderName: String = ""
    @State private var pendingBookmarkIDForNewFolder: String? = nil

    @State private var renamingFolder: BrowserFavoriteFolder? = nil
    @State private var renameFolderText: String = ""
    @State private var exportedBookmarksItem: ExportedBookmarksItem? = nil
    @State private var isImportingBookmarks: Bool = false
    @State private var importResultMessage: String = ""
    @State private var isShowingImportResultAlert: Bool = false

    // Paginated SQLite History view state
    @State private var historyQuery: String = ""
    @State private var debouncedQuery: String = ""
    @State private var timeScope: HistoryTimeScope = .all
    @State private var pickedDate: Date = Date()
    @State private var isShowingDateWheelPopover: Bool = false
    @State private var isShowingClearDataSheet: Bool = false

    @State private var daySummaries: [BrowserHistoryDaySummary] = []
    @State private var loadedEntries: [BrowserHistoryEntry] = []
    @State private var hasMoreHistoryPages: Bool = false
    @State private var isLoadingMoreHistory: Bool = false
    @State private var virtualRows: [HistoryVirtualRow] = []
    @State private var earliestHistoryDate: Date = Date().addingTimeInterval(-365 * 86_400)
    @State private var historyReloadGeneration: Int = 0

    private var session: CleanroomWebKitSession {
        browserStore.activeSession
    }

    private var isWideCanvas: Bool {
        canvasWidth >= 620
    }

    private var horizontalPadding: CGFloat {
        isWideCanvas ? 22 : 16
    }

    private var bisectingVerticalHinge: CGRect? {
        guard let metrics = viewportMetrics,
              let hinge = metrics.verticalHingeRect,
              hinge.minX > 40,
              hinge.maxX < metrics.size.width - 40 else {
            return nil
        }
        return hinge
    }

    private var favoriteColumnCount: Int {
        isWideCanvas ? 8 : 4
    }

    private var favoriteColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 62), spacing: isWideCanvas ? 12 : 10, alignment: .top),
            count: favoriteColumnCount
        )
    }

    private var activeFolder: BrowserFavoriteFolder? {
        browserStore.folder(for: activeFolderID)
    }

    private var visibleBookmarks: [BrowserBookmark] {
        if let folder = activeFolder {
            return browserStore.bookmarks(inFolder: folder.id)
        }
        return browserStore.bookmarks(inFolder: nil)
    }

    private var matchingTotalCount: Int {
        daySummaries.reduce(0) { $0 + $1.count }
    }

    private var initialClearPresetForCurrentScope: BrowsingClearTimePreset {
        switch timeScope {
        case .past24Hours: return .last24Hours
        case .today: return .today
        case .past7Days: return .last7Days
        case .all, .past30Days, .yesterday, .specificDate: return .lastHour
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if session.isPrivate {
                    privateModeBanner
                        .padding(.bottom, 16)
                }

                favoritesSection
                    .padding(.bottom, 18)

                if !session.isPrivate && browserStore.totalHistoryCount > 0 {
                    historyControlsHeader
                        .padding(.bottom, 6)

                    if virtualRows.isEmpty {
                        VStack(spacing: 6) {
                            Text(L("No visits in this time range."))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            if timeScope != .all || !historyQuery.isEmpty {
                                Button(L("Show All History")) {
                                    timeScope = .all
                                    historyQuery = ""
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 26)
                    } else {
                        ForEach(virtualRows) { row in
                            renderVirtualHistoryRow(row)
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: bisectingVerticalHinge != nil ? .infinity : 1040)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            GeometryReader { proxy in
                let metrics = DuoViewportMetrics(proxy: proxy)
                Color(.systemGroupedBackground)
                    .ignoresSafeArea(.all)
                    .onAppear {
                        applyViewportMetrics(metrics)
                    }
                    .onChange(of: metrics) { _, updated in
                        applyViewportMetrics(updated)
                    }
            }
        }
        .contentMargins(.top, topContentMargin, for: .scrollContent)
        .contentMargins(.top, topContentMargin, for: .scrollIndicators)
        .onAppear {
            reloadHistoryFirstPage()
        }
        .onChange(of: "\(browserStore.activeProfileID)-\(browserStore.historyRevision)") { _, _ in
            reloadHistoryFirstPage()
        }
        .onChange(of: browserStore.activeProfileID) { _, _ in
            activeFolderID = nil
        }
        .onChange(of: timeScope) { _, _ in
            reloadHistoryFirstPage()
        }
        .onChange(of: pickedDate) { _, _ in
            if timeScope == .specificDate {
                reloadHistoryFirstPage()
            }
        }
        .task(id: historyQuery) {
            if historyQuery.isEmpty {
                if debouncedQuery != "" {
                    debouncedQuery = ""
                    reloadHistoryFirstPage()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            if debouncedQuery != historyQuery {
                debouncedQuery = historyQuery
                reloadHistoryFirstPage()
            }
        }
        .onChange(of: browserStore.favoriteFolders) { _, folders in
            if let activeFolderID, !folders.contains(where: { $0.id == activeFolderID }) {
                self.activeFolderID = nil
            }
        }
        .sheet(item: $editorTarget) { target in
            FavoriteEditorSheet(
                browserStore: browserStore,
                target: target
            )
        }
        .sheet(isPresented: $isShowingClearDataSheet) {
            ClearBrowsingDataSheet(
                browserStore: browserStore,
                initialPreset: initialClearPresetForCurrentScope,
                targetProfileID: browserStore.activeProfileID
            )
        }
        .sheet(isPresented: $isShowingDateWheelPopover) {
            historyDateWheelPickerSheet
        }
        .alert(L("New Folder"), isPresented: $isCreatingFolderAlert) {
            TextField(L("Folder Name"), text: $newFolderName)
            Button(L("Create")) {
                if let created = browserStore.createFolder(title: newFolderName),
                   let moveID = pendingBookmarkIDForNewFolder {
                    browserStore.moveBookmark(id: moveID, toFolderID: created.id)
                }
                newFolderName = ""
                pendingBookmarkIDForNewFolder = nil
            }
            Button(L("Cancel"), role: .cancel) {
                newFolderName = ""
                pendingBookmarkIDForNewFolder = nil
            }
        }
        .alert(
            L("Rename Folder"),
            isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )
        ) {
            TextField(L("Folder Name"), text: $renameFolderText)
            Button(L("Save")) {
                if let folder = renamingFolder {
                    browserStore.renameFolder(id: folder.id, title: renameFolderText)
                }
                renamingFolder = nil
                renameFolderText = ""
            }
            Button(L("Cancel"), role: .cancel) {
                renamingFolder = nil
                renameFolderText = ""
            }
        }
        .sheet(item: $exportedBookmarksItem) { item in
            BookmarksActivityShareSheet(activityItems: [item.fileURL])
        }
        .fileImporter(
            isPresented: $isImportingBookmarks,
            allowedContentTypes: [.html, .json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleBookmarksImportResult(result)
        }
        .alert(L("Bookmarks Import"), isPresented: $isShowingImportResultAlert) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(importResultMessage)
        }
    }

    private func applyViewportMetrics(_ metrics: DuoViewportMetrics) {
        let wasWide = canvasWidth >= 620
        canvasWidth = metrics.size.width
        viewportMetrics = metrics
        let nowWide = canvasWidth >= 620
        if wasWide != nowWide {
            rebuildVirtualRows()
        }
    }

    // MARK: - Native Scrollable Wheel `DatePicker` Sheet for Exact Day Jump

    private var historyDateWheelPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(L("Roll to inspect browsing history on a specific date"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                DatePicker(
                    L("History Date"),
                    selection: $pickedDate,
                    in: earliestHistoryDate...Date(),
                    displayedComponents: [.date]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, AppLocalization.currentLocale)
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("Jump to Date"))
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let store = browserStore.historyStore
                let pid = browserStore.activeProfileID
                let earliest = await Task.detached(priority: .userInitiated) {
                    store.earliestVisitDate(profileID: pid).map { Calendar.current.startOfDay(for: $0) }
                }.value
                if let earliest, !Task.isCancelled {
                    earliestHistoryDate = earliest
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if timeScope == .specificDate {
                        Button(L("Reset")) {
                            timeScope = .all
                            isShowingDateWheelPopover = false
                        }
                    } else {
                        Button(L("Cancel")) {
                            isShowingDateWheelPopover = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Show Day")) {
                        timeScope = .specificDate
                        reloadHistoryFirstPage()
                        isShowingDateWheelPopover = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(320), .medium])
    }

    // MARK: - Windowed SQLite Query & Flat Row Builder

    private func reloadHistoryFirstPage() {
        historyReloadGeneration &+= 1
        let gen = historyReloadGeneration
        let store = browserStore.historyStore
        let pid = browserStore.activeProfileID
        let q = debouncedQuery
        let bounds = timeScope.resolvedBounds(customDay: pickedDate)
        let pageSize = Self.historyPageSize

        Task.detached(priority: .userInitiated) {
            let summaries = store.queryDaySummaries(
                searchQuery: q,
                startDate: bounds.start,
                endDate: bounds.end,
                maxDays: 90,
                profileID: pid
            )
            let page = store.queryEntriesPage(
                searchQuery: q,
                startDate: bounds.start,
                endDate: bounds.end,
                limit: pageSize + 1,
                offset: 0,
                profileID: pid
            )
            await MainActor.run {
                guard historyReloadGeneration == gen else { return }
                daySummaries = summaries
                if page.count > pageSize {
                    loadedEntries = Array(page.prefix(pageSize))
                    hasMoreHistoryPages = true
                } else {
                    loadedEntries = page
                    hasMoreHistoryPages = false
                }
                isLoadingMoreHistory = false
                rebuildVirtualRows()
            }
        }
    }

    private func loadNextHistoryPageIfNeeded() {
        guard hasMoreHistoryPages, !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        let currentOffset = loadedEntries.count
        let store = browserStore.historyStore
        let pid = browserStore.activeProfileID
        let q = debouncedQuery
        let activeScope = timeScope
        let activePicked = pickedDate
        let bounds = activeScope.resolvedBounds(customDay: activePicked)

        Task.detached(priority: .userInitiated) {
            let nextSlice = store.queryEntriesPage(
                searchQuery: q,
                startDate: bounds.start,
                endDate: bounds.end,
                limit: Self.historyPageSize + 1,
                offset: currentOffset,
                profileID: pid
            )
            await MainActor.run {
                guard self.browserStore.activeProfileID == pid, self.debouncedQuery == q, self.timeScope == activeScope else {
                    self.isLoadingMoreHistory = false
                    return
                }
                if nextSlice.count > Self.historyPageSize {
                    self.loadedEntries.append(contentsOf: nextSlice.prefix(Self.historyPageSize))
                    self.hasMoreHistoryPages = true
                } else {
                    self.loadedEntries.append(contentsOf: nextSlice)
                    self.hasMoreHistoryPages = false
                }
                self.isLoadingMoreHistory = false
                self.rebuildVirtualRows()
            }
        }
    }

    private func rebuildVirtualRows() {
        guard !loadedEntries.isEmpty else {
            virtualRows = []
            return
        }
        let summaryByYMD = Dictionary(uniqueKeysWithValues: daySummaries.map { ($0.dayYMD, $0) })
        var groupedYMDs: [Int64] = []
        var groupedEntries: [Int64: [BrowserHistoryEntry]] = [:]

        for entry in loadedEntries {
            let ymd = BrowserSQLiteStore.calendarDayYMD(for: entry.visitedAt)
            if groupedEntries[ymd] == nil {
                groupedYMDs.append(ymd)
                groupedEntries[ymd] = [entry]
            } else {
                groupedEntries[ymd]?.append(entry)
            }
        }

        let twoColumn = isWideCanvas
        var rows: [HistoryVirtualRow] = []
        rows.reserveCapacity(loadedEntries.count)

        for (dayIdx, ymd) in groupedYMDs.enumerated() {
            guard let items = groupedEntries[ymd], !items.isEmpty else { continue }
            let summary = summaryByYMD[ymd] ?? BrowserHistoryDaySummary(
                dayYMD: ymd,
                dayStart: BrowserSQLiteStore.date(fromDayYMD: ymd),
                displayTitle: L("Earlier"),
                chipTitle: L("Earlier"),
                count: items.count
            )
            rows.append(.dayHeader(summary, topSpacing: dayIdx == 0 ? 4 : 12))

            if twoColumn {
                var idx = 0
                while idx < items.count {
                    let left = items[idx]
                    let right = (idx + 1 < items.count) ? items[idx + 1] : nil
                    rows.append(.pairEntries(left, right))
                    idx += 2
                }
            } else {
                for item in items {
                    rows.append(.singleEntry(item))
                }
            }
        }

        if hasMoreHistoryPages {
            rows.append(.loadMoreSentinel)
        }
        virtualRows = rows
    }

    @ViewBuilder
    private func renderVirtualHistoryRow(_ row: HistoryVirtualRow) -> some View {
        switch row {
        case .dayHeader(let summary, let topSpacing):
            HStack(spacing: 6) {
                Text(summary.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("· \(summary.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .padding(.horizontal, 2)
            .padding(.top, topSpacing)

        case .singleEntry(let entry):
            historyEntryCard(entry)

        case .pairEntries(let left, let right):
            if let metrics = viewportMetrics, bisectingVerticalHinge != nil {
                let cols = metrics.splitColumnWidths(horizontalPadding: horizontalPadding)
                HStack(spacing: metrics.splitColumnSpacing) {
                    historyEntryCard(left)
                        .frame(width: cols.leading)
                    if let right {
                        historyEntryCard(right)
                            .frame(width: cols.trailing)
                    } else {
                        Color.clear
                            .frame(width: cols.trailing)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    historyEntryCard(left)
                        .frame(maxWidth: .infinity)
                    if let right {
                        historyEntryCard(right)
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }

        case .loadMoreSentinel:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L("Loading older history…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .onAppear {
                loadNextHistoryPageIfNeeded()
            }
        }
    }

    // MARK: - Private Mode Notice

    private var privateModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .symbolRenderingMode(.monochrome)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tokens.privateAccent)
                .frame(width: 28, height: 28)
                .background(tokens.privateAccent.opacity(0.14), in: Circle())

            Text(L("Private Browsing — History, cookies, and site data are not saved in this tab."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Responsive `4` / `8` Even-Column Favorites & Folders Matrix

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            favoritesHeader

            let currentFolders = activeFolder == nil ? browserStore.favoriteFolders : []
            let items = visibleBookmarks

            if currentFolders.isEmpty && items.isEmpty {
                if let metrics = viewportMetrics, bisectingVerticalHinge != nil {
                    let cols = metrics.splitColumnWidths(horizontalPadding: horizontalPadding)
                    HStack(alignment: .top, spacing: metrics.splitColumnSpacing) {
                        emptyFavoritesPlaceholder
                            .frame(width: cols.leading, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                } else {
                    emptyFavoritesPlaceholder
                }
            } else if let metrics = viewportMetrics, bisectingVerticalHinge != nil {
                let allTiles: [FavoriteGridTile] = currentFolders.map { .folder($0) } + items.map { .bookmark($0) }
                let cols = metrics.splitColumnWidths(horizontalPadding: horizontalPadding)
                let rowCount = (allTiles.count + 7) / 8
                let leftGridCols = Array(repeating: GridItem(.flexible(minimum: 52), spacing: 10, alignment: .top), count: 4)
                let rightGridCols = Array(repeating: GridItem(.flexible(minimum: 52), spacing: 10, alignment: .top), count: 4)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(0..<rowCount, id: \.self) { rowIdx in
                        let rowStart = rowIdx * 8
                        let rowEnd = min(allTiles.count, rowStart + 8)
                        let mid = min(rowEnd, rowStart + 4)
                        let leftSlice = Array(allTiles[rowStart..<mid])
                        let rightSlice = mid < rowEnd ? Array(allTiles[mid..<rowEnd]) : []

                        HStack(alignment: .top, spacing: metrics.splitColumnSpacing) {
                            LazyVGrid(columns: leftGridCols, spacing: 16) {
                                ForEach(leftSlice) { tile in
                                    renderFavoriteGridTile(tile)
                                }
                            }
                            .frame(width: cols.leading, alignment: .topLeading)

                            LazyVGrid(columns: rightGridCols, spacing: 16) {
                                ForEach(rightSlice) { tile in
                                    renderFavoriteGridTile(tile)
                                }
                            }
                            .frame(width: cols.trailing, alignment: .topLeading)
                        }
                    }
                }
                .animation(.snappy(duration: 0.24), value: activeFolderID)
            } else {
                LazyVGrid(columns: favoriteColumns, spacing: 16) {
                    ForEach(currentFolders) { folder in
                        favoriteFolderTile(folder)
                    }
                    ForEach(items) { bm in
                        favoriteBookmarkTile(bm)
                    }
                }
                .animation(.snappy(duration: 0.24), value: activeFolderID)
            }
        }
    }

    @ViewBuilder
    private func renderFavoriteGridTile(_ tile: FavoriteGridTile) -> some View {
        switch tile {
        case .folder(let folder):
            favoriteFolderTile(folder)
        case .bookmark(let bm):
            favoriteBookmarkTile(bm)
        }
    }

    private var favoritesHeader: some View {
        HStack(spacing: 8) {
            if let folder = activeFolder {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        activeFolderID = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                        Text(L("Favorites"))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(tokens.accent)
                }
                .buttonStyle(.plain)

                Text("/")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Text(folder.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    editorTarget = .create(defaultFolderID: folder.id)
                } label: {
                    Label(L("Add"), systemImage: "plus")
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.accent)
                .accessibilityLabel(L("Add Favorite to \(folder.title)"))

                Menu {
                    let folderItems = browserStore.bookmarks(inFolder: folder.id)
                    if !folderItems.isEmpty {
                        Button {
                            openAllBookmarks(folderItems, isPrivate: false)
                        } label: {
                            Label(L("Open All in Tabs (\(folderItems.count))"), systemImage: "plus.square.on.square")
                        }
                    }
                    Button {
                        renameFolderText = folder.title
                        renamingFolder = folder
                    } label: {
                        Label(L("Rename Folder…"), systemImage: "pencil")
                    }
                    Divider()
                    Button {
                        let id = folder.id
                        activeFolderID = nil
                        browserStore.deleteFolder(id: id, keepBookmarks: true)
                    } label: {
                        Label(L("Ungroup Folder (Keep Sites)"), systemImage: "folder.badge.minus")
                    }
                    Button(role: .destructive) {
                        let id = folder.id
                        activeFolderID = nil
                        browserStore.deleteFolder(id: id, keepBookmarks: false)
                    } label: {
                        Label(L("Delete Folder & Contents"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                }
                .accessibilityLabel(L("Folder Options"))
            } else {
                Text(L("Favorites"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if browserStore.isMultiProfileEnabled && !session.isPrivate {
                    let activeProfile = browserStore.activeProfile
                    Menu {
                        ProfileSwitcherMenuContent(browserStore: browserStore)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: activeProfile.symbolName)
                                .symbolRenderingMode(.monochrome)
                                .font(.caption2.weight(.semibold))
                            Text(activeProfile.localizedDisplayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                            Image(systemName: "chevron.down")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundStyle(tokens.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Favorites Profile: \(activeProfile.localizedDisplayName)"))
                    .accessibilityHint(L("Switch profile"))
                    .accessibilityIdentifier("startpage-profile-switcher")
                }

                Spacer(minLength: 4)

                Button {
                    pendingBookmarkIDForNewFolder = nil
                    newFolderName = ""
                    isCreatingFolderAlert = true
                } label: {
                    if !isWideCanvas && browserStore.isMultiProfileEnabled {
                        Label(L("New Folder"), systemImage: "folder.badge.plus")
                            .symbolRenderingMode(.monochrome)
                            .labelStyle(.iconOnly)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .symbolRenderingMode(.monochrome)
                            Text(L("New Folder"))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("New Folder"))

                Button {
                    editorTarget = .create(defaultFolderID: nil)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .symbolRenderingMode(.monochrome)
                        Text(L("Add"))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tokens.accentSubtleFill, in: Capsule())
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        exportBookmarks(asHTML: true)
                    } label: {
                        Label(L("Export Bookmarks (HTML)…"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(browserStore.bookmarks.isEmpty && browserStore.favoriteFolders.isEmpty)

                    Button {
                        exportBookmarks(asHTML: false)
                    } label: {
                        Label(L("Export Bookmarks (JSON)…"), systemImage: "curlybraces")
                    }
                    .disabled(browserStore.bookmarks.isEmpty && browserStore.favoriteFolders.isEmpty)

                    Divider()

                    Button {
                        isImportingBookmarks = true
                    } label: {
                        Label(L("Import Bookmarks…"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                }
                .accessibilityLabel(L("Bookmarks Options"))
                .accessibilityIdentifier("favorites-options-menu")
            }
        }
    }

    private var emptyFavoritesPlaceholder: some View {
        HStack(spacing: 12) {
            Image(systemName: activeFolder == nil ? "star.square.on.square" : "folder")
                .symbolRenderingMode(.monochrome)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(activeFolder == nil ? L("No favorites saved yet.") : L("This folder is empty."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button(L("Add Site")) {
                editorTarget = .create(defaultFolderID: activeFolderID)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func favoriteFolderTile(_ folder: BrowserFavoriteFolder) -> some View {
        let items = browserStore.bookmarks(inFolder: folder.id)
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                activeFolderID = folder.id
            }
        } label: {
            VStack(spacing: 6) {
                FavoriteFolderMosaicView(previewBookmarks: Array(items.prefix(4)), size: 54)

                Text(folder.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("\(folder.title) folder, \(items.count) sites"))
        .contextMenu {
            if !items.isEmpty {
                Button {
                    openAllBookmarks(items, isPrivate: false)
                } label: {
                    Label(L("Open All in Tabs (\(items.count))"), systemImage: "plus.square.on.square")
                }
                Button {
                    openAllBookmarks(items, isPrivate: true)
                } label: {
                    Label(L("Open All in Private Tabs"), systemImage: "hand.raised")
                }
                Divider()
            }
            Button {
                editorTarget = .create(defaultFolderID: folder.id)
            } label: {
                Label(L("Add Site to Folder…"), systemImage: "plus")
            }
            Button {
                renameFolderText = folder.title
                renamingFolder = folder
            } label: {
                Label(L("Rename Folder…"), systemImage: "pencil")
            }
            Divider()
            Button {
                browserStore.deleteFolder(id: folder.id, keepBookmarks: true)
            } label: {
                Label(L("Ungroup Folder (Keep Sites)"), systemImage: "folder.badge.minus")
            }
            Button(role: .destructive) {
                browserStore.deleteFolder(id: folder.id, keepBookmarks: false)
            } label: {
                Label(L("Delete Folder & Contents"), systemImage: "trash")
            }
        }
    }

    private func favoriteBookmarkTile(_ bm: BrowserBookmark) -> some View {
        Button {
            onSelectURL(bm.urlString)
        } label: {
            VStack(spacing: 6) {
                SiteIconView(urlString: bm.urlString, title: bm.title, size: 54)

                Text(bm.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(bm.title), \(bm.displayHost)")
        .contextMenu {
            Button {
                browserStore.openNewTab(urlString: bm.urlString, isPrivate: false, activate: true)
                onDismissContainer?()
            } label: {
                Label(L("Open in New Tab"), systemImage: "plus.square")
            }
            Button {
                browserStore.openNewTab(urlString: bm.urlString, isPrivate: false, activate: false)
            } label: {
                Label(L("Open in Background Tab"), systemImage: "plus.square.on.square")
            }
            Button {
                browserStore.openNewTab(urlString: bm.urlString, isPrivate: true, activate: true)
                onDismissContainer?()
            } label: {
                Label(L("Open in Private Tab"), systemImage: "hand.raised")
            }

            Divider()

            Menu {
                Button {
                    browserStore.moveBookmark(id: bm.id, toFolderID: nil)
                } label: {
                    Label(L("Favorites (Root)"), systemImage: bm.folderID == nil ? "checkmark" : "star")
                }
                ForEach(browserStore.favoriteFolders) { folder in
                    Button {
                        browserStore.moveBookmark(id: bm.id, toFolderID: folder.id)
                    } label: {
                        Label(folder.title, systemImage: bm.folderID == folder.id ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button {
                    pendingBookmarkIDForNewFolder = bm.id
                    newFolderName = ""
                    isCreatingFolderAlert = true
                } label: {
                    Label(L("New Folder with Site…"), systemImage: "folder.badge.plus")
                }
            } label: {
                Label(L("Move to Folder"), systemImage: "folder")
            }

            Button {
                editorTarget = .edit(bm)
            } label: {
                Label(L("Edit…"), systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                browserStore.removeBookmark(id: bm.id)
            } label: {
                Label(L("Remove Favorite"), systemImage: "trash")
            }
        }
    }

    private func openAllBookmarks(_ items: [BrowserBookmark], isPrivate: Bool) {
        for (idx, bm) in items.enumerated() {
            browserStore.openNewTab(urlString: bm.urlString, isPrivate: isPrivate, activate: idx == 0)
        }
        onDismissContainer?()
    }

    private func exportBookmarks(asHTML: Bool) {
        let data = asHTML
            ? browserStore.exportBookmarksNetscapeHTML()
            : browserStore.exportBookmarksJSON()
        let filename = asHTML ? "Dysprosium-Bookmarks.html" : "Dysprosium-Bookmarks.json"
        Task { @MainActor in
            let fileURL: URL? = await Task.detached(priority: .userInitiated) {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dys-tmp-bookmarks-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(filename)
                do {
                    try data.write(to: dest, options: .atomic)
                    return dest
                } catch {
                    return nil
                }
            }.value
            if let fileURL {
                exportedBookmarksItem = ExportedBookmarksItem(fileURL: fileURL)
            }
        }
    }

    private func handleBookmarksImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                let loadedData: Data? = await Task.detached(priority: .userInitiated) {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStart { url.stopAccessingSecurityScopedResource() }
                    }
                    return try? Data(contentsOf: url)
                }.value
                if let loadedData {
                    let importedCount = browserStore.importBookmarks(from: loadedData)
                    if importedCount > 0 {
                        importResultMessage = L("Imported \(importedCount) bookmarks.")
                    } else {
                        importResultMessage = L("No new bookmarks found in this file.")
                    }
                } else {
                    importResultMessage = L("Could not read the selected bookmarks file.")
                }
                isShowingImportResultAlert = true
            }
        case .failure(let error):
            importResultMessage = error.localizedDescription
            isShowingImportResultAlert = true
        }
    }

    // MARK: - Predictable History Time Scope + Native Wheel Date Picker + Unified Clear Button

    private var historyControlsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L("History"))
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("\(matchingTotalCount)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())

                Spacer()

                Button {
                    isShowingClearDataSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .symbolRenderingMode(.monochrome)
                        Text(L("Clear…"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-clear-button")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .symbolRenderingMode(.monochrome)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(L("Filter history by title or site…"), text: $historyQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("history-filter-field")

                if !historyQuery.isEmpty {
                    Button {
                        historyQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear History Filter"))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            // Predictable Relative Time Windows (`All / 24h / Today / Yesterday / 7 Days / 30 Days`) + Native Wheel Date Picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(HistoryTimeScope.barPresets) { preset in
                        let active = (timeScope == preset)
                        Button {
                            timeScope = preset
                        } label: {
                            Text(preset.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(active ? tokens.onAccent : .primary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    active ? AnyShapeStyle(tokens.accent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    let isCustomDateActive = (timeScope == .specificDate)
                    Button {
                        isShowingDateWheelPopover = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar")
                                .symbolRenderingMode(.monochrome)
                                .font(.caption2.weight(.semibold))
                            Text(
                                isCustomDateActive
                                    ? pickedDate.formatted(.dateTime.month(.abbreviated).day().locale(AppLocalization.currentLocale))
                                    : L("Date…")
                            )
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(isCustomDateActive ? tokens.onAccent : .primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            isCustomDateActive ? AnyShapeStyle(tokens.accent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Pick Specific History Date"))
                }
            }
        }
    }

    private func historyEntryCard(_ item: BrowserHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                onSelectURL(item.urlString)
            } label: {
                HStack(spacing: 10) {
                    SiteIconView(urlString: item.urlString, title: item.title, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(item.displayHost)
                                .lineLimit(1)
                            Text("·")
                            Text(item.visitedAt.formatted(.dateTime.hour().minute().locale(AppLocalization.currentLocale)))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                browserStore.removeHistoryEntry(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Remove \(item.title) from history"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .contextMenu {
            Button {
                browserStore.openNewTab(urlString: item.urlString, isPrivate: false, activate: true)
                onDismissContainer?()
            } label: {
                Label(L("Open in New Tab"), systemImage: "plus.square")
            }
            Button {
                browserStore.openNewTab(urlString: item.urlString, isPrivate: false, activate: false)
            } label: {
                Label(L("Open in Background Tab"), systemImage: "plus.square.on.square")
            }
            Button {
                browserStore.openNewTab(urlString: item.urlString, isPrivate: true, activate: true)
                onDismissContainer?()
            } label: {
                Label(L("Open in Private Tab"), systemImage: "hand.raised")
            }
            Divider()
            Button {
                editorTarget = .prefilled(title: item.title, urlString: item.urlString, defaultFolderID: activeFolderID)
            } label: {
                Label(L("Add to Favorites…"), systemImage: "star")
            }
            Button {
                UIPasteboard.general.string = item.urlString
            } label: {
                Label(L("Copy Link"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                browserStore.removeHistoryEntry(id: item.id)
            } label: {
                Label(L("Delete from History"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Reusable Add / Edit Favorite Sheet with Folder Selection & Inline Creation

enum FavoriteEditorTarget: Identifiable {
    case create(defaultFolderID: String?)
    case prefilled(title: String, urlString: String, defaultFolderID: String?)
    case edit(BrowserBookmark)

    var id: String {
        switch self {
        case .create(let folderID): return "create-\(folderID ?? "root")"
        case .prefilled(_, let url, _): return "prefilled-\(url)"
        case .edit(let bm): return "edit-\(bm.id)"
        }
    }
}

struct FavoriteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var browserStore: CleanroomBrowserStore
    let target: FavoriteEditorTarget

    @State private var titleInput: String = ""
    @State private var urlInput: String = ""
    @State private var selectedFolderID: String? = nil
    @State private var inlineNewFolderName: String = ""
    @State private var isCreatingInlineFolder: Bool = false

    private var isEditingExisting: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Site Details")) {
                    TextField(L("Title"), text: $titleInput)
                    TextField("https://example.com", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(L("Location")) {
                    Picker(L("Folder"), selection: $selectedFolderID) {
                        Label(L("Favorites (Root)"), systemImage: "star")
                            .tag(Optional<String>.none)
                        ForEach(browserStore.favoriteFolders) { folder in
                            Label(folder.title, systemImage: "folder")
                                .tag(Optional<String>.some(folder.id))
                        }
                    }

                    if isCreatingInlineFolder {
                        HStack {
                            TextField(L("New Folder Name"), text: $inlineNewFolderName)
                            Button(L("Create")) {
                                if let folder = browserStore.createFolder(title: inlineNewFolderName) {
                                    selectedFolderID = folder.id
                                    inlineNewFolderName = ""
                                    isCreatingInlineFolder = false
                                }
                            }
                            .disabled(inlineNewFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        Button {
                            isCreatingInlineFolder = true
                        } label: {
                            Label(L("New Folder…"), systemImage: "folder.badge.plus")
                        }
                    }
                }

                if case .edit(let bm) = target {
                    Section {
                        Button(role: .destructive) {
                            browserStore.removeBookmark(id: bm.id)
                            dismiss()
                        } label: {
                            Label(L("Remove Favorite"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditingExisting ? L("Edit Favorite") : L("Add Favorite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        commitSave()
                        dismiss()
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                switch target {
                case .create(let folderID):
                    titleInput = ""
                    urlInput = ""
                    selectedFolderID = folderID
                case .prefilled(let title, let urlString, let folderID):
                    titleInput = title
                    urlInput = urlString
                    selectedFolderID = folderID
                case .edit(let bm):
                    titleInput = bm.title
                    urlInput = bm.urlString
                    selectedFolderID = bm.folderID
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commitSave() {
        var finalFolderID = selectedFolderID
        let pendingFolder = inlineNewFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCreatingInlineFolder && !pendingFolder.isEmpty,
           let created = browserStore.createFolder(title: pendingFolder) {
            finalFolderID = created.id
        }

        switch target {
        case .create, .prefilled:
            browserStore.addBookmark(title: titleInput, urlString: urlInput, folderID: finalFolderID)
        case .edit(let bm):
            browserStore.updateBookmark(id: bm.id, title: titleInput, urlString: urlInput, folderID: finalFolderID)
        }
    }
}

private struct BookmarksActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
