import SwiftUI

@main
struct DysprosiumApp: App {
    private static let isRunningUnitTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                // Keep the XCTest host process lightweight so unit tests never contend
                // with background rule compilation, live WebViews, or startup temp-file sweeps.
                Color.clear
            } else {
                DysprosiumAppRootScene()
            }
        }
    }
}

private struct DysprosiumAppRootScene: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var scheduler = TransferScheduler()
    @State private var themeStore = DysprosiumThemeStore.shared
    @State private var incomingLocalPDFURL: URL?

    var body: some View {
        RootWorkspaceView(scheduler: scheduler, incomingLocalPDFURL: $incomingLocalPDFURL)
            .tint(themeStore.tokens.accent)
            .environment(\.dysprosiumTokens, themeStore.tokens)
            .onOpenURL { incomingURL in
                if incomingURL.isFileURL && incomingURL.pathExtension.lowercased() == "pdf" {
                    incomingLocalPDFURL = incomingURL
                } else {
                    _ = scheduler.handleIncomingURL(incomingURL)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    CustomSaveFolderManager.shared.resolveInBackgroundIfNeeded()
                }
            }
            .task {
                // Resolve persisted Custom Save Folder bookmark off-main to avoid cold FileProvider/iCloud stalls.
                CustomSaveFolderManager.shared.resolveInBackgroundIfNeeded()
                // Pre-warm compiled WebKit content-blocker bytecode and native-dark site lookup
                // during Start Page idle time so the very first navigation starts DNS/TLS immediately.
                CleanroomContentBlocker.shared.prewarmInBackground()
                DarkReaderEngine.shared.warmDarkSitesInBackgroundIfNeeded()
                Task.detached(priority: .utility) {
                    PDFTabDocument.purgeOrphanedTemporaryPreviewFiles()
                }

                #if DEBUG
                if let rawURL = ProcessInfo.processInfo.environment["DYSPROSIUM_ENQUEUE_URL"],
                   let targetURL = URL(string: rawURL) {
                    _ = scheduler.enqueue(url: targetURL, lanes: 16)
                }
                if ProcessInfo.processInfo.environment["DYSPROSIUM_REAL_CDN_TEST"] == "1" {
                    _ = scheduler.enqueue(
                        url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/v2/main.mp4")!,
                        lanes: 16,
                        suggestedTitle: "Apple-CDN-BipBop-fMP4.mp4"
                    )
                    _ = scheduler.enqueue(
                        url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/v2/prog_index.m3u8")!,
                        lanes: 8,
                        suggestedTitle: "Apple-CDN-BipBop-HLS.ts"
                    )
                }
                #endif
            }
    }
}
