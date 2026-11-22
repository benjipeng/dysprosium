import SwiftUI

/// Pure 3-Tab Root Workspace built against iOS 27.2 SDK (`iphone_duo_27_2` / `iPhone19,4`):
/// 1. `Browser`: Edge-to-edge Cleanroom Ad-Shielded Browser & Live Media Radar
/// 2. `Downloads`: Unified Multi-Lane Active Transfers + In-App File Manager (`42.5% / 57.5%` fold-aware split)
/// 3. `Engine`: Lanthanide Design Token Studio, Filter Subscriptions & Runtime Diagnostics
public struct RootWorkspaceView: View {
    public enum WorkspaceTab: Hashable {
        case browser
        case downloads
        case engine
    }

    @Bindable var scheduler: TransferScheduler
    @Binding var incomingLocalPDFURL: URL?

    @State private var activeTab: WorkspaceTab = .browser
    @State private var browserStore = CleanroomBrowserStore()
    @State private var downloadsSelection: DownloadsSelection?
    @State private var isBrowserImmersiveHidden: Bool = false

    public init(
        scheduler: TransferScheduler,
        incomingLocalPDFURL: Binding<URL?> = .constant(nil)
    ) {
        self.scheduler = scheduler
        self._incomingLocalPDFURL = incomingLocalPDFURL
    }

    public var body: some View {
        TabView(selection: $activeTab) {
            Tab("Browser", systemImage: "safari", value: .browser) {
                NavigationStack {
                    CleanroomBrowserWorkspaceView(
                        browserStore: browserStore,
                        scheduler: scheduler,
                        defaultLanes: scheduler.defaultLanesPerTransfer,
                        onJumpToTransfer: { maybeID in
                            if let maybeID {
                                downloadsSelection = .activeTransfer(maybeID)
                            }
                            activeTab = .downloads
                        },
                        onOpenDownloadsTab: {
                            activeTab = .downloads
                        },
                        onImmersiveHiddenChange: { hidden in
                            withAnimation(.easeInOut(duration: 0.22)) {
                                isBrowserImmersiveHidden = hidden
                            }
                        }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                }
            }

            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                NavigationStack {
                    LibraryVaultView(
                        scheduler: scheduler,
                        selection: $downloadsSelection,
                        selectedLanes: $scheduler.defaultLanesPerTransfer,
                        onOpenWebURLInBrowser: { webURL in
                            browserStore.activeSession.load(urlString: webURL.absoluteString)
                            activeTab = .browser
                        },
                        onOpenLocalPDFInBrowser: { pdfURL, title in
                            browserStore.openLocalPDFTab(fileURL: pdfURL, displayTitle: title)
                            activeTab = .browser
                        }
                    )
                    .navigationTitle("Downloads")
                    .toolbarTitleDisplayMode(.inlineLarge)
                }
            }
            .badge(scheduler.activeTransferCount)

            Tab("Engine", systemImage: "cpu", value: .engine) {
                NavigationStack {
                    EngineStatusView(scheduler: scheduler, browserStore: browserStore)
                        .navigationTitle("Engine & Host")
                        .toolbarTitleDisplayMode(.inlineLarge)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .statusBarHidden(activeTab == .browser && isBrowserImmersiveHidden)
        .animation(.easeInOut(duration: 0.22), value: activeTab == .browser && isBrowserImmersiveHidden)
        .onChange(of: incomingLocalPDFURL) { _, incoming in
            guard let incoming else { return }
            incomingLocalPDFURL = nil
            browserStore.openLocalPDFTab(fileURL: incoming, copyIfExternalSecurityScoped: true)
            activeTab = .browser
        }
        .onAppear {
            if let incoming = incomingLocalPDFURL {
                incomingLocalPDFURL = nil
                browserStore.openLocalPDFTab(fileURL: incoming, copyIfExternalSecurityScoped: true)
                activeTab = .browser
            }
            let targetScheduler = scheduler
            browserStore.onScrubTransferAuthData = { [weak targetScheduler] in
                targetScheduler?.scrubPersistedAuthDataAndOrphanedStaging()
            }
            browserStore.activeTransferIDsProvider = { [weak targetScheduler] in
                Set(
                    (targetScheduler?.jobs ?? [])
                        .filter {
                            $0.lifecycle == .downloading
                                || $0.lifecycle == .queued
                                || $0.lifecycle == .resolving
                                || $0.lifecycle == .muxing
                                || $0.lifecycle == .paused
                        }
                        .map(\.id)
                )
            }
            #if DEBUG
            if let initialTab = ProcessInfo.processInfo.environment["DYSPROSIUM_INITIAL_TAB"] {
                switch initialTab {
                case "transfers", "downloads": activeTab = .downloads
                case "engine": activeTab = .engine
                default: activeTab = .browser
                }
            }
            if let localPDFPath = ProcessInfo.processInfo.environment["DYSPROSIUM_OPEN_LOCAL_PDF"],
               !localPDFPath.isEmpty {
                let pdfURL = URL(fileURLWithPath: localPDFPath)
                if FileManager.default.fileExists(atPath: pdfURL.path) {
                    browserStore.openLocalPDFTab(fileURL: pdfURL, displayTitle: pdfURL.lastPathComponent)
                    activeTab = .browser
                }
            }
            if let browserTarget = ProcessInfo.processInfo.environment["DYSPROSIUM_OPEN_BROWSER_URL"],
               !browserTarget.isEmpty {
                browserStore.activeSession.load(urlString: browserTarget)
                activeTab = .browser
                if ProcessInfo.processInfo.environment["DYSPROSIUM_AUTO_DOWNLOAD_SNIFFED"] == "1" {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(7))
                        let sess = browserStore.activeSession
                        if let grp = sess.mediaGroups.first, let chosen = grp.selectedVariant {
                            let job = scheduler.enqueue(
                                url: chosen.url,
                                pairedAudioURL: chosen.pairedAudioURL,
                                pairedAudioBytes: chosen.pairedAudioBytes,
                                expectedTotalBytes: chosen.exactOrEstimatedBytes,
                                siteDomainOverride: grp.sourceDomain,
                                lanes: scheduler.defaultLanesPerTransfer,
                                headers: chosen.headers,
                                suggestedTitle: grp.outputFilename(),
                                preloadedManifestText: chosen.preloadedManifestText
                            )
                            downloadsSelection = .activeTransfer(job.id)
                        }
                    }
                }
            }
            #endif
        }
    }
}
