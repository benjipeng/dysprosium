import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

/// Merged representation of a saved file in `Downloads/` combining live filesystem attributes
/// with optional `TransferScheduler` provenance metadata.
struct MergedVaultEntry: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let filename: String
    let displayTitle: String
    let subtitle: String
    let sourceDomain: String?
    let byteSize: Int64
    let modifiedAt: Date
    let mediaKind: LiveContainerEnvironment.DownloadedVaultItem.MediaKind
    let supportsVideoThumbnail: Bool
    let supportsNativeAVPlayback: Bool
    let trackedJobID: UUID?
}

/// Selection state shared between the left `Downloads` list and the right `60%` `UISplitArrangement` inspector.
enum DownloadsSelection: Hashable {
    case activeTransfer(UUID)
    case savedFile(String)
    case historyRecord(UUID)
}

@MainActor
private final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()

    private let cache: NSCache<NSString, UIImage>
    private var failedPaths: Set<String> = []
    private var memoryWarningToken: NSObjectProtocol?

    private init() {
        let boundedCache = NSCache<NSString, UIImage>()
        boundedCache.countLimit = 80
        boundedCache.totalCostLimit = 32 * 1024 * 1024
        self.cache = boundedCache

        self.memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeAll()
            }
        }
    }

    isolated deinit {
        if let token = memoryWarningToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func purgeAll() {
        cache.removeAllObjects()
        failedPaths.removeAll()
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.standardizedFileURL.path as NSString)
    }

    func hasFailed(for url: URL) -> Bool {
        failedPaths.contains(url.standardizedFileURL.path)
    }

    func store(_ image: UIImage?, for url: URL) {
        let key = url.standardizedFileURL.path
        if let image {
            let pixelCost: Int
            if let cg = image.cgImage {
                pixelCost = cg.bytesPerRow * cg.height
            } else {
                pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            }
            cache.setObject(image, forKey: key as NSString, cost: max(1, pixelCost))
            failedPaths.remove(key)
        } else {
            failedPaths.insert(key)
        }
    }

    static func loadOrGenerate(for url: URL) async -> UIImage? {
        if let cached = shared.image(for: url) { return cached }
        guard !shared.hasFailed(for: url) else { return nil }

        let generated: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 400)

            for seconds in [1.0, 0.1, 0.0] {
                let t = CMTime(seconds: seconds, preferredTimescale: 600)
                if let (cgImage, _) = try? await generator.image(at: t) {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil
        }.value

        shared.store(generated, for: url)
        return generated
    }
}

private struct ExportableFileItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Unified `Downloads` workspace combining:
/// 1. Live in-flight multi-lane transfers (`Active` section, graduating automatically into `Files` at 100%)
/// 2. Saved local files in `Documents/Downloads/` (`Files` section with `.searchable` + `.searchScopes`)
/// 3. Single-`NavigationStack` fold-aware dual-pane layout (`42.5%` master / `57.5%` context-aware Inspector
///    when flat, splitting cleanly at `verticalHingeRect.midX` across the `40 pt` `.division` hinge when folded).
struct LibraryVaultView: View {
    private enum SortOrder: String, CaseIterable {
        case newest = "Newest"
        case largest = "Largest"
        case alphabetical = "Name"
    }

    private enum KindFilter: String, CaseIterable, Hashable {
        case all = "All"
        case video = "Video"
        case audio = "Audio"
        case other = "Files"
    }

    @Environment(\.dysprosiumTokens) private var tokens
    @Bindable var scheduler: TransferScheduler
    @Binding var selection: DownloadsSelection?
    @Binding var selectedLanes: Int
    let onOpenWebURLInBrowser: (URL) -> Void
    var onOpenLocalPDFInBrowser: ((URL, String) -> Void)? = nil

    @State private var isShowingNewTransferSheet: Bool = false
    @State private var viewportWidth: CGFloat = 0
    @State private var activeVerticalHingeMidX: CGFloat? = nil
    @State private var diskItems: [LiveContainerEnvironment.DownloadedVaultItem] = []
    @State private var freeDiskSpaceBytes: Int64?
    @State private var activeAVEntry: MergedVaultEntry?
    @State private var quickLookURL: URL?
    @State private var searchQuery: String = ""
    @State private var sortOrder: SortOrder = .newest
    @State private var kindFilter: KindFilter = .all
    @State private var renamingEntry: MergedVaultEntry?
    @State private var renameText: String = ""
    @State private var compactInspectorSelection: DownloadsSelection?
    @State private var exportingFileItem: ExportableFileItem?
    @State private var isConfirmingClearHistory: Bool = false
    @State private var clearHistoryOnlyOffDevice: Bool = false
    @State private var isShowingSaveFolderPicker: Bool = false
    @State private var resetMoveOffer: (sourceDir: URL, count: Int)?
    private var saveFolderManager = CustomSaveFolderManager.shared

    private static let appleCDNRangeMP4 = URL(
        string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/v2/main.mp4"
    )!
    private static let appleCDNHLSStream = URL(
        string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
    )!

    private var incompleteJobs: [TransferJob] {
        scheduler.jobs.filter { $0.lifecycle != .completed }
    }

    private var allMergedEntries: [MergedVaultEntry] {
        let completedJobs = scheduler.completedJobs
        var matchedJobIDs = Set<UUID>()
        var entries: [MergedVaultEntry] = []

        for item in diskItems {
            let matchingJob = completedJobs.first { job in
                if let rel = job.destinationRelativePath, rel == item.filename {
                    return true
                }
                if let jobURL = scheduler.vaultFileURL(for: job),
                   jobURL.standardizedFileURL.path == item.fileURL.standardizedFileURL.path {
                    return true
                }
                return false
            }

            if let job = matchingJob {
                matchedJobIDs.insert(job.id)
                let size = item.byteSize > 0 ? item.byteSize : job.downloadedBytes
                entries.append(
                    MergedVaultEntry(
                        id: item.id,
                        fileURL: item.fileURL,
                        filename: item.filename,
                        displayTitle: item.filename,
                        subtitle: "\(DysprosiumFormatters.bytes(size)) · \(job.siteDomain)",
                        sourceDomain: job.siteDomain,
                        byteSize: size,
                        modifiedAt: item.modifiedAt,
                        mediaKind: item.mediaKind,
                        supportsVideoThumbnail: item.supportsVideoThumbnail,
                        supportsNativeAVPlayback: item.supportsNativeAVPlayback,
                        trackedJobID: job.id
                    )
                )
            } else {
                let ext = item.fileURL.pathExtension.uppercased()
                let kindLabel = ext.isEmpty ? item.mediaKind.rawValue : ext
                entries.append(
                    MergedVaultEntry(
                        id: item.id,
                        fileURL: item.fileURL,
                        filename: item.filename,
                        displayTitle: item.filename,
                        subtitle: "\(DysprosiumFormatters.bytes(item.byteSize)) · \(kindLabel)",
                        sourceDomain: nil,
                        byteSize: item.byteSize,
                        modifiedAt: item.modifiedAt,
                        mediaKind: item.mediaKind,
                        supportsVideoThumbnail: item.supportsVideoThumbnail,
                        supportsNativeAVPlayback: item.supportsNativeAVPlayback,
                        trackedJobID: nil
                    )
                )
            }
        }

        for job in completedJobs where !matchedJobIDs.contains(job.id) {
            guard let fileURL = scheduler.vaultFileURL(for: job) else { continue }
            let filename = fileURL.lastPathComponent
            let kind = LiveContainerEnvironment.DownloadedVaultItem.MediaKind.infer(from: filename)
            let ext = (filename as NSString).pathExtension.lowercased()
            entries.append(
                MergedVaultEntry(
                    id: fileURL.standardizedFileURL.path,
                    fileURL: fileURL,
                    filename: filename,
                    displayTitle: job.title,
                    subtitle: "\(DysprosiumFormatters.bytes(job.downloadedBytes)) · \(job.siteDomain)",
                    sourceDomain: job.siteDomain,
                    byteSize: job.downloadedBytes,
                    modifiedAt: job.updatedAt,
                    mediaKind: kind,
                    supportsVideoThumbnail: ["mp4", "m4v", "mov"].contains(ext),
                    supportsNativeAVPlayback: ["mp4", "m4v", "mov", "ts", "m4a", "mp3", "wav", "aac"].contains(ext),
                    trackedJobID: job.id
                )
            )
        }

        return entries
    }

    private var filteredAndSortedEntries: [MergedVaultEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = allMergedEntries.filter { entry in
            let matchesKind: Bool = switch kindFilter {
            case .all: true
            case .video: entry.mediaKind == .video
            case .audio: entry.mediaKind == .audio
            case .other: entry.mediaKind != .video && entry.mediaKind != .audio
            }
            guard matchesKind else { return false }
            guard !q.isEmpty else { return true }
            return entry.displayTitle.lowercased().contains(q)
                || entry.filename.lowercased().contains(q)
                || entry.subtitle.lowercased().contains(q)
        }

        switch sortOrder {
        case .newest:
            return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .largest:
            return filtered.sorted { $0.byteSize > $1.byteSize }
        case .alphabetical:
            return filtered.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }

    private var totalDownloadedBytes: Int64 {
        allMergedEntries.reduce(0) { $0 + max(0, $1.byteSize) }
    }

    /// Completed SQLite transfer records whose local file has been moved out or deleted to free space.
    private var allOffDeviceHistoryJobs: [TransferJob] {
        let onDeviceJobIDs = Set(allMergedEntries.compactMap(\.trackedJobID))
        return scheduler.completedJobs
            .filter { !onDeviceJobIDs.contains($0.id) }
            .sorted { ($0.effectiveCompletedAt ?? $0.updatedAt) > ($1.effectiveCompletedAt ?? $1.updatedAt) }
    }

    private var visibleOffDeviceHistoryJobs: [TransferJob] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allOffDeviceHistoryJobs }
        return allOffDeviceHistoryJobs.filter { job in
            job.title.lowercased().contains(q)
                || job.siteDomain.lowercased().contains(q)
                || job.compactInsightSummary.lowercased().contains(q)
        }
    }

    /// Resolves the active inspector target: if a previously selected transfer just hit 100%,
    /// smoothly promotes the inspector to its newly saved file entry without losing selection!
    private var resolvedInspectorSelection: DownloadsSelection? {
        let entries = filteredAndSortedEntries
        let history = visibleOffDeviceHistoryJobs
        if let selection {
            switch selection {
            case .activeTransfer(let jobID):
                if incompleteJobs.contains(where: { $0.id == jobID }) {
                    return .activeTransfer(jobID)
                }
                if let promoted = entries.first(where: { $0.trackedJobID == jobID }) {
                    return .savedFile(promoted.id)
                }
                if history.contains(where: { $0.id == jobID }) {
                    return .historyRecord(jobID)
                }
            case .savedFile(let fileID):
                if entries.contains(where: { $0.id == fileID }) {
                    return .savedFile(fileID)
                }
            case .historyRecord(let jobID):
                if history.contains(where: { $0.id == jobID }) {
                    return .historyRecord(jobID)
                }
            }
        }
        if let firstActive = incompleteJobs.first {
            return .activeTransfer(firstActive.id)
        }
        if let firstFile = entries.first {
            return .savedFile(firstFile.id)
        }
        if let firstHistory = history.first {
            return .historyRecord(firstHistory.id)
        }
        return nil
    }

    var body: some View {
        let entries = allMergedEntries
        let visibleEntries = filteredAndSortedEntries
        let activeSelection = resolvedInspectorSelection
        let isRenamingBinding = Binding<Bool>(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )

        let isSplitExpanded = viewportWidth >= 720
        let centerHalfGutter: CGFloat = activeVerticalHingeMidX != nil ? 24 : 10
        let leftColumnWidth: CGFloat = {
            if let midX = activeVerticalHingeMidX {
                return midX
            }
            return floor(viewportWidth * 0.425)
        }()

        Group {
            if isSplitExpanded {
                HStack(spacing: 0) {
                    downloadsMasterList(
                        allCount: entries.count,
                        visibleEntries: visibleEntries,
                        activeSelection: activeSelection,
                        isSplitExpanded: true
                    )
                    .contentMargins(.trailing, centerHalfGutter, for: .scrollContent)
                    .frame(width: leftColumnWidth)

                    Group {
                        if let activeSelection {
                            inspectorDestination(for: activeSelection, visibleEntries: visibleEntries, isEmbedded: true)
                                .contentMargins(.leading, centerHalfGutter, for: .scrollContent)
                        } else {
                            ContentUnavailableView(
                                "No Selection",
                                systemImage: "arrow.down.circle",
                                description: Text("Select an active transfer to inspect 16× byte-range slices, or select a downloaded file to preview metadata.")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                downloadsMasterList(
                    allCount: entries.count,
                    visibleEntries: visibleEntries,
                    activeSelection: activeSelection,
                    isSplitExpanded: false
                )
            }
        }
        .background {
            GeometryReader { proxy in
                let metrics = DuoViewportMetrics(proxy: proxy)
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                    .onAppear {
                        viewportWidth = proxy.size.width
                        activeVerticalHingeMidX = metrics.verticalHingeRect?.midX
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        viewportWidth = w
                    }
                    .onChange(of: metrics.verticalHingeRect) { _, rect in
                        activeVerticalHingeMidX = rect?.midX
                    }
            }
        }
        .searchable(text: $searchQuery, prompt: "Search downloads…")
        .searchScopes($kindFilter) {
            ForEach(KindFilter.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isShowingNewTransferSheet = true
                } label: {
                    Label("New Download", systemImage: "plus")
                        .symbolRenderingMode(.monochrome)
                }
                .tint(tokens.glassIconPrimary)
                .accessibilityIdentifier("downloads-new-transfer-button")
            }

            trailingVaultToolbar(activeSelection: activeSelection, visibleEntries: visibleEntries)
        }
        .navigationDestination(for: DownloadsSelection.self) { target in
            inspectorDestination(for: target, visibleEntries: visibleEntries, isEmbedded: false)
                .navigationTitle("Inspector")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            refreshDiskInventory()
        }
        .onChange(of: scheduler.completedJobCount) { _, _ in
            refreshDiskInventory()
        }
        .onChange(of: saveFolderManager.revision) { _, _ in
            refreshDiskInventory()
        }
        .saveFolderPickerFlow(isPresented: $isShowingSaveFolderPicker) {
            refreshDiskInventory()
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
                        refreshDiskInventory()
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
        .sheet(isPresented: $isShowingNewTransferSheet) {
            NewTransferSheet(selectedLanes: $selectedLanes) { url, lanes in
                if MediaURLClassifier.isDirectSingleAssetURL(url) {
                    let created = scheduler.enqueue(url: url, lanes: lanes)
                    selection = .activeTransfer(created.id)
                } else {
                    onOpenWebURLInBrowser(url)
                }
            }
        }
        .fullScreenCover(item: $activeAVEntry) { entry in
            NativeAVPlayerContainer(fileURL: entry.fileURL)
                .ignoresSafeArea()
        }
        .quickLookPreview($quickLookURL)
        .sheet(item: $exportingFileItem) { item in
            DocumentExportPicker(url: item.url) {
                exportingFileItem = nil
            }
            .ignoresSafeArea()
        }
        .sheet(
            isPresented: Binding(
                get: { compactInspectorSelection != nil },
                set: { if !$0 { compactInspectorSelection = nil } }
            )
        ) {
            if let target = compactInspectorSelection {
                NavigationStack {
                    inspectorDestination(for: target, visibleEntries: visibleEntries, isEmbedded: false)
                        .navigationTitle("Inspector")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    compactInspectorSelection = nil
                                }
                            }
                        }
                }
            }
        }
        .confirmationDialog(
            clearHistoryOnlyOffDevice ? "Clear Off-Device History?" : "Clear Transfer History?",
            isPresented: $isConfirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button(
                clearHistoryOnlyOffDevice ? "Clear Off-Device History" : "Clear All Transfer History",
                role: .destructive
            ) {
                scheduler.clearDownloadHistory(onlyOffDevice: clearHistoryOnlyOffDevice)
                if case .historyRecord = selection {
                    selection = nil
                }
                if case .historyRecord = compactInspectorSelection {
                    compactInspectorSelection = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears saved transfer metrics and history records. Downloaded files on device will not be deleted.")
        }
        .alert("Rename File", isPresented: isRenamingBinding) {
            TextField("Filename", text: $renameText)
            Button("Save") {
                if let target = renamingEntry {
                    _ = try? scheduler.renameVaultFile(
                        jobID: target.trackedJobID,
                        currentFileURL: target.fileURL,
                        newBaseOrFullName: renameText
                    )
                    renamingEntry = nil
                    refreshDiskInventory()
                }
            }
            Button("Cancel", role: .cancel) {
                renamingEntry = nil
            }
        }
    }

    // MARK: - Left Master List (`Active Transfers` + `Saved Files` + `Storage`)

    private func downloadsMasterList(
        allCount: Int,
        visibleEntries: [MergedVaultEntry],
        activeSelection: DownloadsSelection?,
        isSplitExpanded: Bool
    ) -> some View {
        let activeJobs = incompleteJobs

        return List {
            // 0. Multi-Instance LiveContainer Host Grant Prompt (LC 2 -> LC 1 shared folder link)
            if case .needsHostGrant(let folderName, _, _) = saveFolderManager.status {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.person.crop")
                                .symbolRenderingMode(.monochrome)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(tokens.statusWarning)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link \"\(folderName)\" for \(CustomSaveFolderManager.currentHostDisplayName())")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Text("iOS requires a one-time folder confirmation per LiveContainer instance so all multi-open apps share one library.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                isShowingSaveFolderPicker = true
                            } label: {
                                Text("Grant Access…")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(tokens.accent)
                            .accessibilityIdentifier("downloads-grant-folder-button")

                            Button("Use Default") {
                                _ = saveFolderManager.resetToDefaultFolder()
                                refreshDiskInventory()
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // 1. Live In-Flight / Paused Transfers (Automatically disappears when queue is idle!)
            if !activeJobs.isEmpty {
                Section {
                    ForEach(Array(activeJobs.enumerated()), id: \.element.id) { idx, job in
                        let isSelected = isSplitExpanded && (activeSelection == .activeTransfer(job.id))
                        let isNextSelected = isSplitExpanded
                            && (idx + 1 < activeJobs.count)
                            && (activeSelection == .activeTransfer(activeJobs[idx + 1].id))
                        Group {
                            if isSplitExpanded {
                                TransferCardView(job: job, isSelected: isSelected) {
                                    togglePauseResume(job)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = .activeTransfer(job.id)
                                }
                            } else {
                                NavigationLink(value: DownloadsSelection.activeTransfer(job.id)) {
                                    TransferCardView(job: job, isSelected: false) {
                                        togglePauseResume(job)
                                    }
                                }
                            }
                        }
                        .listRowBackground(
                            isSelected
                                ? tokens.accentSubtleFill
                                : Color(.secondarySystemGroupedBackground)
                        )
                        .listRowSeparator((isSelected || isNextSelected) ? .hidden : .automatic, edges: .bottom)
                        .listRowSeparator(.hidden, edges: .top)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                scheduler.remove(id: job.id, deleteVaultFile: false)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .tint(tokens.statusDanger)
                            .accessibilityLabel("Cancel Download")
                        }
                    }
                } header: {
                    HStack {
                        Text("Active (\(activeJobs.count))")
                        Spacer()
                        if scheduler.activeTransferCount > 0 {
                            Text(DysprosiumFormatters.speed(scheduler.aggregateSpeedBytesPerSec))
                                .foregroundStyle(tokens.accent)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }

            // 2. Completed Local Files in `Documents/Downloads/`
            let historyJobs = visibleOffDeviceHistoryJobs
            if allCount == 0 && activeJobs.isEmpty && allOffDeviceHistoryJobs.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Downloads Yet",
                        systemImage: "arrow.down.circle",
                        description: Text("Capture videos in Browser or tap '+' to start a multi-lane download.")
                    )
                    .padding(.vertical, 8)
                }
            } else if allCount > 0 {
                Section {
                    if visibleEntries.isEmpty {
                        ContentUnavailableView.search(text: searchQuery)
                    } else {
                        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { idx, entry in
                            let isSelected = isSplitExpanded && (activeSelection == .savedFile(entry.id))
                            let isNextSelected = isSplitExpanded
                                && (idx + 1 < visibleEntries.count)
                                && (activeSelection == .savedFile(visibleEntries[idx + 1].id))
                            VaultFileRowView(
                                entry: entry,
                                isSelected: isSelected,
                                showInlineShare: !isSplitExpanded,
                                onPrimaryTap: {
                                    if isSplitExpanded {
                                        selection = .savedFile(entry.id)
                                    } else {
                                        openEntry(entry)
                                    }
                                },
                                onQuickPlayTap: {
                                    openEntry(entry)
                                }
                            )
                            .listRowBackground(
                                isSelected
                                    ? tokens.accentSubtleFill
                                    : Color(.secondarySystemGroupedBackground)
                            )
                            .listRowSeparator((isSelected || isNextSelected) ? .hidden : .automatic, edges: .bottom)
                            .listRowSeparator(.hidden, edges: .top)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    beginRename(entry)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .tint(tokens.accent)
                                .accessibilityLabel("Rename")
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .tint(tokens.statusDanger)
                                .accessibilityLabel("Delete")
                            }
                            .contextMenu {
                                Button {
                                    openEntry(entry)
                                } label: {
                                    Label(
                                        entry.supportsNativeAVPlayback ? "Play" : "Preview",
                                        systemImage: entry.supportsNativeAVPlayback ? "play" : "eye"
                                    )
                                }

                                Button {
                                    if isSplitExpanded {
                                        selection = .savedFile(entry.id)
                                    } else {
                                        compactInspectorSelection = .savedFile(entry.id)
                                    }
                                } label: {
                                    Label("Inspect Insights", systemImage: "chart.xyaxis.line")
                                }

                                Button {
                                    beginRename(entry)
                                } label: {
                                    Label("Rename…", systemImage: "pencil")
                                }

                                Button {
                                    exportingFileItem = ExportableFileItem(url: entry.fileURL)
                                } label: {
                                    Label("Export to Files…", systemImage: "folder.badge.plus")
                                }

                                ShareLink(item: entry.fileURL) {
                                    Label("Share…", systemImage: "square.and.arrow.up")
                                }

                                Divider()

                                if entry.trackedJobID != nil {
                                    Button {
                                        removeLocalFileKeepingHistory(entry)
                                    } label: {
                                        Label("Remove Local Copy (Keep History)", systemImage: "externaldrive.badge.minus")
                                    }
                                }

                                Button(role: .destructive) {
                                    deleteEntry(entry)
                                } label: {
                                    Label("Delete File & Record", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(kindFilter == .all ? "Files (\(visibleEntries.count))" : "\(kindFilter.rawValue) (\(visibleEntries.count))")
                        Spacer()
                        Text(sortOrder.rawValue)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                }
            }

            // 3. Completed Transfer History (Moved / Exported / Removed from Device)
            if !historyJobs.isEmpty {
                Section {
                    ForEach(Array(historyJobs.enumerated()), id: \.element.id) { idx, job in
                        let isSelected = isSplitExpanded && (activeSelection == .historyRecord(job.id))
                        let isNextSelected = isSplitExpanded
                            && (idx + 1 < historyJobs.count)
                            && (activeSelection == .historyRecord(historyJobs[idx + 1].id))
                        TransferHistoryRowView(job: job, isSelected: isSelected) {
                            if isSplitExpanded {
                                selection = .historyRecord(job.id)
                            } else {
                                compactInspectorSelection = .historyRecord(job.id)
                            }
                        }
                        .listRowBackground(
                            isSelected
                                ? tokens.accentSubtleFill
                                : Color(.secondarySystemGroupedBackground)
                        )
                        .listRowSeparator((isSelected || isNextSelected) ? .hidden : .automatic, edges: .bottom)
                        .listRowSeparator(.hidden, edges: .top)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                scheduler.remove(id: job.id, deleteVaultFile: false)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .tint(tokens.statusDanger)
                            .accessibilityLabel("Remove from History")
                        }
                        .contextMenu {
                            Button {
                                let created = scheduler.redownload(from: job)
                                selection = .activeTransfer(created.id)
                            } label: {
                                Label("Download Again", systemImage: "arrow.clockwise")
                            }

                            Button {
                                UIPasteboard.general.string = job.sourceURL.absoluteString
                            } label: {
                                Label("Copy Source URL", systemImage: "doc.on.doc")
                            }

                            Divider()

                            Button(role: .destructive) {
                                scheduler.remove(id: job.id, deleteVaultFile: false)
                            } label: {
                                Label("Remove from History", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("History · Off Device (\(historyJobs.count))")
                        Spacer()
                        Button("Clear") {
                            clearHistoryOnlyOffDevice = true
                            isConfirmingClearHistory = true
                        }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                    }
                    .font(.caption.monospacedDigit())
                }
            }

            // 4. Native Storage Summary & Export Handoff
            Section {
                LabeledContent("Downloaded") {
                    Text("\(DysprosiumFormatters.bytes(totalDownloadedBytes)) · \(allCount) files")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                }

                if let free = freeDiskSpaceBytes {
                    LabeledContent("Available on Device") {
                        Text(DysprosiumFormatters.bytes(free))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if scheduler.completedJobCount > 0 {
                    LabeledContent("Transfer Records") {
                        Text("\(scheduler.completedJobCount) logged")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    isShowingSaveFolderPicker = true
                } label: {
                    Label(
                        saveFolderManager.status.isCustomActive ? "Change Save Folder…" : "Choose Save Folder…",
                        systemImage: "folder.badge.plus"
                    )
                    .symbolRenderingMode(.monochrome)
                }
                .accessibilityIdentifier("downloads-choose-save-folder-button")

                if saveFolderManager.status.isCustomActive || !LiveContainerEnvironment.displayDownloadsPath.hasPrefix("Shared Vault") {
                    Button {
                        SaveFolderFilesLauncher.openActiveDownloadsFolder()
                    } label: {
                        Label("Open in iOS Files", systemImage: "folder")
                            .symbolRenderingMode(.monochrome)
                    }
                    .accessibilityIdentifier("downloads-open-in-files-button")
                }

                if saveFolderManager.status.isCustomActive {
                    Button(role: .destructive) {
                        let offer = saveFolderManager.resetToDefaultFolder()
                        if let src = offer.offerMoveFrom, offer.movableFileCount > 0 {
                            resetMoveOffer = (src, offer.movableFileCount)
                        }
                        refreshDiskInventory()
                    } label: {
                        Label("Reset to Default Storage", systemImage: "arrow.uturn.backward")
                            .symbolRenderingMode(.monochrome)
                    }
                }

                ShareLink(item: LiveContainerEnvironment.downloadsDirectory) {
                    Label("Export Downloads Folder…", systemImage: "square.and.arrow.up")
                        .symbolRenderingMode(.monochrome)
                }

                if scheduler.completedJobCount > 0 {
                    Button(role: .destructive) {
                        clearHistoryOnlyOffDevice = false
                        isConfirmingClearHistory = true
                    } label: {
                        Label("Clear Transfer History…", systemImage: "clock.arrow.circlepath")
                            .symbolRenderingMode(.monochrome)
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text(
                    saveFolderManager.status.isCustomActive
                        ? LiveContainerEnvironment.displayDownloadsPath
                        : "\(LiveContainerEnvironment.displayDownloadsPath) · Excluded from iCloud Backup"
                )
                .font(.caption2.monospaced())
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .refreshable {
            refreshDiskInventory()
        }
    }

    // MARK: - Context-Aware Right-Pane Inspector (`Active Slices` vs `Saved File`)

    @ViewBuilder
    private func inspectorDestination(
        for target: DownloadsSelection,
        visibleEntries: [MergedVaultEntry],
        isEmbedded: Bool
    ) -> some View {
        switch target {
        case .activeTransfer(let jobID):
            if let job = scheduler.jobs.first(where: { $0.id == jobID }) {
                TransferInspectorView(
                    job: job,
                    vaultFileURL: scheduler.vaultFileURL(for: job),
                    isEmbeddedInSplit: isEmbedded
                )
            } else {
                ContentUnavailableView("Transfer Completed", systemImage: "checkmark.circle")
            }
        case .savedFile(let fileID):
            if let entry = visibleEntries.first(where: { $0.id == fileID }) ?? allMergedEntries.first(where: { $0.id == fileID }) {
                let trackedJob = entry.trackedJobID.flatMap { scheduler.job(for: $0) }
                VaultFileInspectorView(
                    entry: entry,
                    trackedJob: trackedJob,
                    isEmbeddedInSplit: isEmbedded,
                    onOpen: { openEntry(entry) },
                    onRename: { beginRename(entry) },
                    onOpenInFiles: { SaveFolderFilesLauncher.openActiveDownloadsFolder() },
                    onRemoveLocalKeepingHistory: trackedJob != nil ? {
                        removeLocalFileKeepingHistory(entry)
                    } : nil
                )
            } else {
                ContentUnavailableView("File Not Found", systemImage: "doc.questionmark")
            }
        case .historyRecord(let jobID):
            if let job = scheduler.job(for: jobID) {
                TransferHistoryInspectorView(
                    job: job,
                    onRedownload: {
                        let created = scheduler.redownload(from: job)
                        selection = .activeTransfer(created.id)
                        compactInspectorSelection = nil
                    },
                    onRemoveHistory: {
                        scheduler.remove(id: job.id, deleteVaultFile: false)
                        if selection == .historyRecord(job.id) {
                            selection = nil
                        }
                        compactInspectorSelection = nil
                    }
                )
            } else {
                ContentUnavailableView("History Cleared", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ToolbarContentBuilder
    private func trailingVaultToolbar(
        activeSelection: DownloadsSelection?,
        visibleEntries: [MergedVaultEntry]
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }

                Divider()

                Picker("Category", selection: $kindFilter) {
                    ForEach(KindFilter.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }

                #if DEBUG
                Divider()

                Button {
                    let job = scheduler.enqueue(
                        url: Self.appleCDNRangeMP4,
                        lanes: 16,
                        suggestedTitle: "Apple-CDN-BipBop-fMP4.mp4"
                    )
                    selection = .activeTransfer(job.id)
                } label: {
                    Label("Test 16× HTTP Range MP4", systemImage: "network")
                }

                Button {
                    let job = scheduler.enqueue(
                        url: Self.appleCDNHLSStream,
                        lanes: 8,
                        suggestedTitle: "Apple-CDN-BipBop-HLS.mp4"
                    )
                    selection = .activeTransfer(job.id)
                } label: {
                    Label("Test 8× HLS → MP4 Remux", systemImage: "film.stack")
                }

                Button {
                    Task {
                        if let benchURL = try? await LoopbackRangeServer.shared.ensureRunning(sizeBytes: 24 * 1024 * 1024) {
                            let job = scheduler.enqueue(url: benchURL, lanes: 16)
                            selection = .activeTransfer(job.id)
                        }
                    }
                } label: {
                    Label("Local 16× Work-Stealing Benchmark", systemImage: "bolt.horizontal")
                }
                #endif
            } label: {
                Label("Sort & Filter", systemImage: "arrow.up.arrow.down")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(tokens.glassIconPrimary)
            .accessibilityIdentifier("toolbar-benchmark-button")

            Button {
                refreshDiskInventory()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .symbolRenderingMode(.monochrome)
            }
            .tint(tokens.glassIconPrimary)
        }
    }

    private func togglePauseResume(_ job: TransferJob) {
        if job.lifecycle.isActive || job.lifecycle == .queued {
            scheduler.pause(id: job.id)
        } else {
            scheduler.resume(id: job.id)
        }
    }

    private func openEntry(_ entry: MergedVaultEntry) {
        if entry.fileURL.pathExtension.lowercased() == "pdf",
           let onOpenLocalPDFInBrowser {
            onOpenLocalPDFInBrowser(entry.fileURL, entry.displayTitle)
        } else if entry.supportsNativeAVPlayback {
            activeAVEntry = entry
        } else {
            quickLookURL = entry.fileURL
        }
    }

    private func beginRename(_ entry: MergedVaultEntry) {
        renameText = (entry.filename as NSString).deletingPathExtension
        renamingEntry = entry
    }

    private func refreshDiskInventory() {
        Task.detached(priority: .userInitiated) {
            let scanned = LiveContainerEnvironment.scanDownloadedFiles()
            let freeBytes = LiveContainerEnvironment.availableDiskSpaceBytes
            await MainActor.run {
                diskItems = scanned
                freeDiskSpaceBytes = freeBytes
            }
        }
    }

    private func deleteEntry(_ entry: MergedVaultEntry) {
        if let jobID = entry.trackedJobID {
            scheduler.remove(id: jobID, deleteVaultFile: true)
        }
        try? FileManager.default.removeItem(at: entry.fileURL)
        refreshDiskInventory()
    }

    private func removeLocalFileKeepingHistory(_ entry: MergedVaultEntry) {
        scheduler.removeLocalFileKeepingHistory(jobID: entry.trackedJobID, fileURL: entry.fileURL)
        if let jobID = entry.trackedJobID {
            selection = .historyRecord(jobID)
            if compactInspectorSelection == .savedFile(entry.id) {
                compactInspectorSelection = .historyRecord(jobID)
            }
        }
        refreshDiskInventory()
    }
}

// MARK: - Saved File Row

private struct VaultFileRowView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let entry: MergedVaultEntry
    let isSelected: Bool
    let showInlineShare: Bool
    let onPrimaryTap: () -> Void
    let onQuickPlayTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailBadge
                .onTapGesture(perform: onQuickPlayTap)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(entry.subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading]
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onPrimaryTap)

            if showInlineShare {
                ShareLink(item: entry.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline)
                        .foregroundStyle(tokens.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share \(entry.displayTitle)")
            }
        }
        .padding(.vertical, 2)
        .task(id: entry.fileURL) {
            guard entry.supportsVideoThumbnail else { return }
            thumbnail = await VideoThumbnailCache.loadOrGenerate(for: entry.fileURL)
        }
    }

    @ViewBuilder
    private var thumbnailBadge: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tokens.accentSubtleFill)
                .frame(width: 58, height: 38)
                .overlay {
                    Image(systemName: entry.mediaKind.systemImage)
                        .symbolRenderingMode(.monochrome)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tokens.accent)
                }
        }
    }
}

// MARK: - Saved File Detail Inspector (`60%` Right Pane in `UISplitArrangement`)

private struct VaultFileInspectorView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let entry: MergedVaultEntry
    let trackedJob: TransferJob?
    let isEmbeddedInSplit: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onOpenInFiles: () -> Void
    let onRemoveLocalKeepingHistory: (() -> Void)?

    @State private var poster: UIImage?
    @State private var resolutionText: String?
    @State private var durationText: String?
    @State private var exportingFileItem: ExportableFileItem?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        Color.clear
                            .frame(height: poster != nil ? 196 : 148)
                            .overlay {
                                if let poster {
                                    Image(uiImage: poster)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    tokens.accentSubtleFill
                                        .overlay {
                                            Image(systemName: entry.mediaKind.systemImage)
                                                .symbolRenderingMode(.monochrome)
                                                .font(.largeTitle)
                                                .foregroundStyle(tokens.accent)
                                        }
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button(action: onOpen) {
                            Label(
                                entry.supportsNativeAVPlayback ? "Play" : "Preview",
                                systemImage: entry.supportsNativeAVPlayback ? "play.fill" : "eye.fill"
                            )
                            .symbolRenderingMode(.monochrome)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tokens.onAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(tokens.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(entry.displayTitle)
                        .font(.headline)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Inspector")
            }

            if let trackedJob {
                TransferInsightsSection(job: trackedJob, isOnDevice: true)
            }

            Section("Metadata") {
                LabeledContent("Size", value: DysprosiumFormatters.bytes(entry.byteSize))
                    .font(.subheadline.monospacedDigit())

                LabeledContent("Format", value: entry.fileURL.pathExtension.uppercased().isEmpty ? entry.mediaKind.rawValue : entry.fileURL.pathExtension.uppercased())
                    .font(.subheadline)

                if let resolutionText {
                    LabeledContent("Dimensions", value: resolutionText)
                        .font(.subheadline.monospacedDigit())
                }

                if let durationText {
                    LabeledContent("Duration", value: durationText)
                        .font(.subheadline.monospacedDigit())
                }

                if let domain = entry.sourceDomain {
                    LabeledContent("Source", value: domain)
                        .font(.subheadline)
                }

                LabeledContent("Modified") {
                    Text(entry.modifiedAt, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                Button {
                    exportingFileItem = ExportableFileItem(url: entry.fileURL)
                } label: {
                    Label("Export to Files…", systemImage: "folder.badge.plus")
                        .symbolRenderingMode(.monochrome)
                }
                .accessibilityIdentifier("vault-inspector-export-to-files-button")

                ShareLink(item: entry.fileURL) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .symbolRenderingMode(.monochrome)
                }

                Button(action: onRename) {
                    Label("Rename File…", systemImage: "pencil")
                        .symbolRenderingMode(.monochrome)
                }

                if !LiveContainerEnvironment.displayDownloadsPath.hasPrefix("Shared Vault") {
                    Button(action: onOpenInFiles) {
                        Label("Show in iOS Files", systemImage: "folder")
                            .symbolRenderingMode(.monochrome)
                    }
                }

                if let onRemoveLocalKeepingHistory {
                    Button(role: .destructive, action: onRemoveLocalKeepingHistory) {
                        Label("Remove Local Copy (Keep History)", systemImage: "externaldrive.badge.minus")
                            .symbolRenderingMode(.monochrome)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
        .task(id: entry.fileURL) {
            await loadFileInspectionMetadata()
        }
        .sheet(item: $exportingFileItem) { item in
            DocumentExportPicker(url: item.url) {
                exportingFileItem = nil
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private func loadFileInspectionMetadata() async {
        poster = entry.supportsVideoThumbnail ? await VideoThumbnailCache.loadOrGenerate(for: entry.fileURL) : nil
        resolutionText = nil
        durationText = nil

        guard entry.supportsNativeAVPlayback else { return }
        let url = entry.fileURL
        let summary: (String?, String?) = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            var res: String?
            var durStr: String?

            if let dur = try? await asset.load(.duration), dur.seconds.isFinite, dur.seconds > 0 {
                let total = Int(dur.seconds.rounded())
                let hrs = total / 3600
                let mins = (total % 3600) / 60
                let secs = total % 60
                durStr = hrs > 0
                    ? String(format: "%d:%02d:%02d", hrs, mins, secs)
                    : String(format: "%02d:%02d", mins, secs)
            }

            if let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = natural.applying(transform)
                let w = Int(abs(transformed.width).rounded())
                let h = Int(abs(transformed.height).rounded())
                if w > 0, h > 0 {
                    res = "\(w) × \(h)"
                }
            }
            return (res, durStr)
        }.value

        resolutionText = summary.0
        durationText = summary.1
    }
}

// MARK: - Swiss Editorial Transfer Insights Section (Shared by On-Device & History Inspectors)

private struct TransferInsightsSection: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let job: TransferJob
    let isOnDevice: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 0) {
                    metricCell(
                        label: "AVG SPEED",
                        value: job.effectiveAverageSpeedBytesPerSec.map(DysprosiumFormatters.speed) ?? "—",
                        tint: tokens.accent,
                        leadingInset: 0
                    )
                    Divider()
                        .frame(height: 28)
                    metricCell(
                        label: "PEAK",
                        value: job.effectivePeakSpeedBytesPerSec.map(DysprosiumFormatters.speed) ?? "—",
                        tint: .primary,
                        leadingInset: 10
                    )
                    Divider()
                        .frame(height: 28)
                    metricCell(
                        label: "ELAPSED",
                        value: DysprosiumFormatters.duration(job.effectiveDurationSeconds),
                        tint: .primary,
                        leadingInset: 10
                    )
                }
                .padding(.vertical, 2)

                if job.throughputSamples.count >= 2 {
                    ThroughputSparklineView(samples: job.throughputSamples)
                        .frame(height: 44)
                }
            }
            .padding(.vertical, 2)

            LabeledContent("Parallelism", value: job.segmentTopologySummary)
                .font(.subheadline.monospacedDigit())

            if let completed = job.effectiveCompletedAt {
                LabeledContent("Completed") {
                    Text(completed, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Local File") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnDevice ? tokens.statusSuccess : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(isOnDevice ? "On Device" : "Off Device · Moved or Removed")
                        .font(.subheadline)
                        .foregroundStyle(isOnDevice ? .primary : .secondary)
                }
            }
        } header: {
            HStack {
                Text("Transfer Insights")
                Spacer()
                Text(job.kind.rawValue)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func metricCell(label: String, value: String, tint: Color, leadingInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leadingInset)
        .padding(.trailing, 8)
    }
}

// MARK: - Off-Device Transfer History Row & Inspector

private struct TransferHistoryRowView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let job: TransferJob
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 40, height: 32)
                    .overlay {
                        Image(systemName: "tray.and.arrow.up")
                            .symbolRenderingMode(.monochrome)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(job.compactInsightSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TransferHistoryInspectorView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    let job: TransferJob
    let onRedownload: () -> Void
    let onRemoveHistory: () -> Void

    @State private var copiedURL: Bool = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 42, height: 42)
                            .overlay {
                                Image(systemName: "tray.and.arrow.up")
                                    .symbolRenderingMode(.monochrome)
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title)
                                .font(.headline)
                                .textSelection(.enabled)
                            Text("\(DysprosiumFormatters.bytes(job.totalBytes ?? job.downloadedBytes)) · \(job.siteDomain)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Transfer Record")
            }

            TransferInsightsSection(job: job, isOnDevice: false)

            Section("Source") {
                Text(job.sourceURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    UIPasteboard.general.string = job.sourceURL.absoluteString
                    copiedURL = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedURL = false
                    }
                } label: {
                    Label(copiedURL ? "Copied Source URL" : "Copy Source URL", systemImage: copiedURL ? "checkmark" : "doc.on.doc")
                        .symbolRenderingMode(.monochrome)
                }
            }

            Section("Actions") {
                Button(action: onRedownload) {
                    Label("Download Again", systemImage: "arrow.clockwise")
                        .symbolRenderingMode(.monochrome)
                }

                Button(role: .destructive, action: onRemoveHistory) {
                    Label("Remove from History", systemImage: "trash")
                        .symbolRenderingMode(.monochrome)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(DysprosiumTokens.Space.sectionSpacing)
    }
}

// MARK: - 100% Native Apple `AVPlayerViewController` (PiP, AirPlay, Playback Speed & Scrubbing)

private struct NativeAVPlayerContainer: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        let player = AVPlayer(url: fileURL)
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

// MARK: - Native Document Export Picker (Shared Vault → iCloud Drive / On My iPhone)

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
