import AVFoundation
import AVKit
import SwiftUI
import UIKit
import WebKit

/// Immersive Browser workspace built strictly on native iOS 27.2 SDK primitives:
/// - `NativeWebKitHostController` (`UIViewControllerRepresentable`) feeds `additionalSafeAreaInsets.top`
///   into WebKit's native `contentInsetAdjustmentBehavior = .automatic` engine—zero manual scroll-offset hacks—
///   and passively observes `WKWebView.scrollView.contentOffset` + `panGestureRecognizer` to drive continuous
///   Safari-style finger-tracked chrome compaction (`0.0 ... 1.0`).
/// - Single-plane persistent Liquid Glass top chrome (`GeometryReader` + `.ignoresSafeArea(.container, edges: .top)`)
///   resolves posture coordinates through `BrowserTopChromeLayout.resolve(...)` and continuously interpolates one
///   persistent capsule (`36 pt` omnibox ↔ `24 pt` top-edge centered domain pill) with zero view teardown and zero top blur scrim.
/// - `OmniboxAddressField` (`UIViewRepresentable` wrapping `UITextField`) guarantees UIKit's native
///   `clearButtonMode = .whileEditing` (`⊗`) and select-all-on-focus across all iPhone Duo postures.
struct CleanroomBrowserWorkspaceView: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Environment(\.duoVerticalBarEdge) private var duoVerticalBarEdge
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var browserStore: CleanroomBrowserStore
    @Bindable var scheduler: TransferScheduler
    let defaultLanes: Int
    let onJumpToTransfer: (UUID?) -> Void
    let onOpenDownloadsTab: () -> Void
    var onImmersiveHiddenChange: (Bool) -> Void = { _ in }

    @State private var addressInput: String = ""
    @State private var isAddressEditing: Bool = false
    @State private var chromeCollapse = BrowserChromeCollapseModel()
    @State private var measuredTopOverlayHeight: CGFloat = 74
    @State private var isShowingRadarPopover: Bool = false
    @State private var activeStreamPreview: CleanroomStreamPreviewItem?
    @State private var isShowingShieldSheet: Bool = false
    @State private var isShowingTabsSheet: Bool = false
    @State private var isShowingClearDataSheet: Bool = false
    @State private var isShowingBookmarksHistorySheet: Bool = false
    @State private var isShowingProfilesSheet: Bool = false
    @State private var isShowingNewProfileSheet: Bool = false
    @State private var favoriteEditorTarget: FavoriteEditorTarget? = nil

    @State private var omniboxFocusTrigger: Int = 0
    @State private var omniboxDismissTrigger: Int = 0
    @State private var omniboxSuggestions: [OmniboxDropdownItem] = []
    @State private var activeToastBanner: BrowserToastBanner? = nil
    @State private var toastDismissTask: Task<Void, Never>? = nil
    @State private var activeSharePayload: BrowserSharePayload? = nil
    @State private var jsPromptInput: String = ""
    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @State private var isShowingGrantFolderPicker: Bool = false
    @State private var pendingSavePDFAfterGrant: Bool = false

    private var contentBlocker = CleanroomContentBlocker.shared

    private var session: CleanroomWebKitSession {
        browserStore.activeSession
    }

    private var isStartPageVisible: Bool {
        session.currentURLString.isEmpty && !session.isLoading && session.activePDF == nil
    }

    private var hasActivePageOrLoad: Bool {
        !session.currentURLString.isEmpty || session.isLoading || session.activePDF != nil
    }

    private var activeScopeTabCount: Int {
        browserStore.tabs.filter { $0.isPrivate == session.isPrivate && $0.profileID == session.profileID }.count
    }

    private var omniboxSuggestionTaskKey: String {
        isAddressEditing ? addressInput : ""
    }

    private var canSwipeSwitchTabs: Bool {
        !isAddressEditing && activeScopeTabCount > 1
    }

    private static let horizontalTrailingCapsuleWidth: CGFloat = 116

    var body: some View {
        let isVerticalRailActive = (duoVerticalBarEdge != .none)
        let showClipboardBanner = browserStore.hasClipboardWebURL && (isStartPageVisible || isAddressEditing)
        let allowScrollCollapse = !isStartPageVisible
            && !isAddressEditing
            && session.lastLoadError == nil
            && !showClipboardBanner
            && session.lastBlockedPopupURL == nil
            && activeToastBanner == nil

        GeometryReader { proxy in
            let metrics = DuoViewportMetrics(proxy: proxy)
            let topChromeLayout = BrowserTopChromeLayout.resolve(
                metrics: metrics,
                verticalBarEdge: duoVerticalBarEdge,
                windowTopSafeAreaInset: Self.currentWindowTopSafeAreaInset()
            )
            let chromeMaxWidth = topChromeLayout.maxWidth
            let expandedTopBandHeight = topChromeLayout.top + 36 + 6 + (showClipboardBanner ? 42 : 0)

            ZStack(alignment: .topLeading) {
                // Z = 0: Full-bleed surface matching the active PDF mode, live webpage, or Start Page canvas
                Group {
                    if session.activePDF != nil {
                        Color(uiColor: browserStore.pdfAppearanceMode.canvasUIColor)
                    } else if isStartPageVisible {
                        Color(.systemGroupedBackground)
                    } else if let sampled = session.pageCanvasColor {
                        Color(uiColor: sampled)
                    } else {
                        Color(.systemBackground)
                    }
                }
                .ignoresSafeArea(.all)

                // Z = 0: Single edge-to-edge native scroll host (`NativePDFHost` or `NativeWebKitHost`).
                // Mutually exclusive mounting guarantees `UITabBarController`'s `.tabBarMinimizeBehavior(.onScrollDown)`
                // always binds to the active `UIScrollView` with zero competing sibling controller and zero bottom seam.
                if let activePDF = session.activePDF, !activePDF.isLocked {
                    let pdfLayoutConfig = PDFDuoLayoutConfiguration.resolve(
                        viewportSize: metrics.size,
                        verticalHingeRect: metrics.verticalHingeRect,
                        preference: browserStore.pdfDisplayLayoutMode,
                        pageCount: activePDF.pageCount
                    )
                    NativePDFHost(
                        pdfDoc: activePDF,
                        appearanceMode: browserStore.pdfAppearanceMode,
                        layoutConfig: pdfLayoutConfig,
                        desiredTopOverlayHeight: measuredTopOverlayHeight,
                        collapseModel: chromeCollapse,
                        allowScrollCollapse: allowScrollCollapse && !activePDF.isSearchVisible,
                        onOpenExternalLink: { linkURL in
                            dismissOmniboxFocus()
                            addressInput = linkURL.absoluteString
                            session.openURLFromPDF(linkURL)
                        }
                    )
                    .ignoresSafeArea(edges: [.top, .bottom])
                    .accessibilityIdentifier("native-pdf-viewport")
                } else {
                    NativeWebKitHost(
                        webView: isStartPageVisible ? session.liveWebViewIfLoaded : session.webView,
                        desiredTopOverlayHeight: measuredTopOverlayHeight,
                        collapseModel: chromeCollapse,
                        allowScrollCollapse: allowScrollCollapse && session.activePDF == nil,
                        isScrollViewActive: !isStartPageVisible && session.activePDF == nil
                    )
                    .ignoresSafeArea(edges: [.top, .bottom])
                    .opacity((isStartPageVisible || session.activePDF != nil) ? 0 : 1)
                    .allowsHitTesting(!isStartPageVisible && session.activePDF == nil)
                }

                // Z = 0.5: Safe-area-respecting native `PDFKit` chrome overlay (unlock card, floating search bar,
                // floating Liquid Glass bottom reader pill docked above the bottom tab bar, and Navigator sheet).
                if let activePDF = session.activePDF {
                    NativePDFChromeOverlay(
                        pdfDoc: activePDF,
                        metrics: metrics,
                        topChromeLayout: topChromeLayout,
                        desiredTopOverlayHeight: measuredTopOverlayHeight,
                        collapseModel: chromeCollapse,
                        allowScrollCollapse: allowScrollCollapse,
                        appearanceMode: $browserStore.pdfAppearanceMode,
                        displayLayoutMode: $browserStore.pdfDisplayLayoutMode,
                        onSaveToVault: {
                            saveActivePDFToVault()
                        },
                        onRevealInVault: {
                            onOpenDownloadsTab()
                        },
                        onShareOriginalPDF: {
                            activeSharePayload = BrowserSharePayload(items: [activePDF.localFileURL])
                        }
                    )
                }

                if isStartPageVisible {
                    BrowserStartPageView(
                        browserStore: browserStore,
                        topContentMargin: measuredTopOverlayHeight,
                        onSelectURL: { targetURL in
                            dismissOmniboxFocus()
                            addressInput = targetURL
                            session.load(urlString: targetURL)
                        }
                    )
                } else if let loadError = session.lastLoadError, !session.isLoading {
                    ContentUnavailableView {
                        Label(
                            loadError.isTLSFailure ? L("Secure Connection Failed") : L("Page Failed to Load"),
                            systemImage: loadError.isTLSFailure ? "lock.trianglebadge.exclamationmark" : "wifi.exclamationmark"
                        )
                    } description: {
                        Text(loadError.localizedDescription)
                    } actions: {
                        Button(L("Try Again")) {
                            session.retryLastFailedLoad()
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.top, measuredTopOverlayHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                }

                // Z = 1: Single persistent Liquid Glass top chrome overlay.
                // Isolated in `BrowserFloatingTopChromeOverlay` so continuous 120 Hz scroll progress
                // never invalidates `CleanroomBrowserWorkspaceView.body`, WebKitHost, or sheets.
                BrowserFloatingTopChromeOverlay(
                    collapseModel: chromeCollapse,
                    allowScrollCollapse: allowScrollCollapse,
                    viewportWidth: proxy.size.width,
                    layout: topChromeLayout,
                    isVerticalRailActive: isVerticalRailActive,
                    hasBackButton: !isVerticalRailActive && session.canGoBack,
                    trailingClusterWidth: Self.horizontalTrailingCapsuleWidth,
                    compactDomainTitle: session.displayHost,
                    isPrivate: session.isPrivate,
                    isInsecureHTTP: !session.isSecureConnection && session.currentURL?.scheme?.lowercased() == "http",
                    profileSymbolName: (browserStore.isMultiProfileEnabled && !session.isPrivate)
                        ? browserStore.activeProfile.symbolName
                        : nil,
                    profileAccent: tokens.accent,
                    privateAccent: tokens.privateAccent,
                    warningTint: tokens.statusWarning,
                    glassIconPrimary: tokens.glassIconPrimary,
                    progressAccent: session.isPrivate ? tokens.privateAccent : tokens.accent,
                    session: session,
                    canSwipeSwitchTabs: canSwipeSwitchTabs,
                    onSwipeTabDelta: { delta in
                        withAnimation(.snappy(duration: 0.2)) {
                            browserStore.switchToAdjacentTab(delta: delta)
                        }
                    },
                    onExpandFromPill: {
                        chromeCollapse.setExternalProgress(0, animated: true)
                    },
                    omniboxExpandedContent: {
                        omniboxExpandedInnerContent
                    },
                    backButtonContent: {
                        horizontalBackButton
                    },
                    trailingCapsuleContent: {
                        compactHorizontalTrailingCapsule
                    }
                )

                // Transient banners & omnibox autocomplete anchored cleanly below the expanded top bar height.
                VStack(spacing: 6) {
                    if showClipboardBanner {
                        clipboardSuggestionBanner
                            .frame(maxWidth: chromeMaxWidth ?? .infinity)
                    }

                    if isAddressEditing, !omniboxSuggestions.isEmpty {
                        omniboxAutocompleteDropdown
                            .frame(maxWidth: chromeMaxWidth ?? .infinity)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }

                    if let blockedURL = session.lastBlockedPopupURL {
                        popupBlockedBanner(for: blockedURL)
                            .frame(maxWidth: chromeMaxWidth ?? .infinity)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let toast = activeToastBanner {
                        toastBannerView(toast)
                            .frame(maxWidth: chromeMaxWidth ?? .infinity)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, topChromeLayout.top + 36 + 6)
                .padding(.leading, topChromeLayout.leading)
                .padding(.trailing, topChromeLayout.trailing)
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.snappy(duration: 0.2), value: omniboxSuggestions.count)
                .animation(.snappy(duration: 0.2), value: session.lastBlockedPopupURL != nil)
                .animation(.snappy(duration: 0.2), value: activeToastBanner?.id)
            }
            .onAppear {
                if abs(measuredTopOverlayHeight - expandedTopBandHeight) > 0.5 {
                    measuredTopOverlayHeight = expandedTopBandHeight
                }
            }
            .onChange(of: expandedTopBandHeight) { _, newHeight in
                if abs(measuredTopOverlayHeight - newHeight) > 0.5 {
                    measuredTopOverlayHeight = newHeight
                }
            }
        }
        // INVARIANT: Keep `.ignoresSafeArea(.container, edges: .top)` so iPhone Duo Inner Portrait (`safeAreaInsets.top == 82`)
        // places the floating top chrome INSIDE the 82 pt top band beside the corner clock/Wi-Fi ring (`occlusion(525, 0, 144×82)`).
        // Non-Duo devices clear their status bar via `BrowserTopChromeLayout.resolve(windowTopSafeAreaInset:)`.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            keyboardShortcutsLayer
        }
        .background {
            ZStack {
                Color.clear
                    .alert(
                        session.displayHost,
                        isPresented: Binding(
                            get: { session.activeJSDialog != nil },
                            set: { isPresented in
                                if !isPresented, let pending = session.activeJSDialog {
                                    switch pending.kind {
                                    case .alert:
                                        pending.resolveAlert()
                                    case .confirm:
                                        pending.resolveConfirm(false)
                                    case .prompt:
                                        pending.resolvePrompt(nil)
                                    }
                                }
                            }
                        ),
                        presenting: session.activeJSDialog
                    ) { dialog in
                        switch dialog.kind {
                        case .alert:
                            Button(L("OK")) {
                                dialog.resolveAlert()
                            }
                        case .confirm:
                            Button(L("Cancel"), role: .cancel) {
                                dialog.resolveConfirm(false)
                            }
                            Button(L("OK")) {
                                dialog.resolveConfirm(true)
                            }
                        case .prompt:
                            TextField(L("Response"), text: $jsPromptInput)
                            Button(L("Cancel"), role: .cancel) {
                                dialog.resolvePrompt(nil)
                            }
                            Button(L("OK")) {
                                dialog.resolvePrompt(jsPromptInput)
                            }
                        }
                    } message: { dialog in
                        Text(dialog.message)
                    }

                Color.clear
                    .alert(
                        authAlertTitle(for: session.activeAuthChallenge),
                        isPresented: Binding(
                            get: { session.activeAuthChallenge != nil },
                            set: { isPresented in
                                if !isPresented, let pending = session.activeAuthChallenge {
                                    pending.cancel()
                                }
                            }
                        ),
                        presenting: session.activeAuthChallenge
                    ) { challenge in
                        switch challenge.kind {
                        case .httpCredentials:
                            TextField(L("Username"), text: $authUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField(L("Password"), text: $authPassword)
                            Button(L("Cancel"), role: .cancel) {
                                challenge.cancel()
                                authUsername = ""
                                authPassword = ""
                            }
                            Button(L("Sign In")) {
                                challenge.resolveCredentials(username: authUsername, password: authPassword)
                                authUsername = ""
                                authPassword = ""
                            }
                        case .lanSelfSignedTrust:
                            Button(L("Cancel"), role: .cancel) {
                                challenge.resolveTrust(proceed: false)
                            }
                            Button(L("Continue Anyway"), role: .destructive) {
                                challenge.resolveTrust(proceed: true)
                            }
                        }
                    } message: { challenge in
                        switch challenge.kind {
                        case .httpCredentials(let realm):
                            if let realm, !realm.isEmpty {
                                Text(L("Authentication required for \(challenge.host) (\(realm))."))
                            } else {
                                Text(L("Enter credentials for \(challenge.host)."))
                            }
                        case .lanSelfSignedTrust(let reason):
                            Text(L("This local network server (\(challenge.host)) presented an untrusted or self-signed certificate. \(reason)"))
                        }
                    }
            }
            .allowsHitTesting(false)
        }
        .toolbarVisibility(isVerticalRailActive ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if isVerticalRailActive {
                if session.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(session.backHistoryItems) { item in
                                Button {
                                    session.navigateBackForward(offset: item.id)
                                } label: {
                                    Label(
                                        item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title,
                                        systemImage: "clock"
                                    )
                                }
                            }
                        } label: {
                            Label(L("Back"), systemImage: "chevron.left")
                                .symbolRenderingMode(.monochrome)
                        } primaryAction: {
                            session.navigateBack()
                        }
                        .tint(tokens.glassIconPrimary)
                        .accessibilityIdentifier("browser-back-button")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isShowingRadarPopover.toggle()
                    } label: {
                        let radarCount = session.discoveredMediaBadgeCount
                        if radarCount == 0 {
                            Label(L("Media Radar"), systemImage: "dot.radiowaves.left.and.right")
                                .symbolRenderingMode(.monochrome)
                                .symbolEffect(.variableColor.iterative, isActive: session.isProbingMedia || session.activeProbeCount > 0)
                        } else {
                            Label {
                                Text(L("Media Radar (\(radarCount))"))
                            } icon: {
                                Image(uiImage: makeBadgedRadarToolbarImage(count: radarCount, compact: false))
                            }
                        }
                    }
                    .tint(tokens.glassIconPrimary)
                    .accessibilityIdentifier("browser-radar-button")

                    Button {
                        session.capturePreviewSnapshot()
                        isShowingTabsSheet = true
                    } label: {
                        Label(
                            session.isPrivate
                                ? L("Private Tabs (\(activeScopeTabCount))")
                                : L("Tabs (\(activeScopeTabCount))"),
                            systemImage: tabsToolbarSymbol
                        )
                        .symbolRenderingMode(.monochrome)
                    }
                    .tint(
                        session.isPrivate
                            ? tokens.privateAccent
                            : (browserStore.isMultiProfileEnabled ? tokens.accent : tokens.glassIconPrimary)
                    )
                    .accessibilityIdentifier("browser-tabs-button")
                }

                ToolbarItemGroup(placement: .secondaryAction) {
                    browserOverflowMenuSections
                }
            }
        }
        .onAppear {
            chromeCollapse.onImmersiveHiddenChange = onImmersiveHiddenChange
            syncAddressBarFromSession()
            syncDialogInputsForActiveSession()
            wireAllSessionCallbacks()
            browserStore.checkClipboardForNewURL()
            #if DEBUG
            if ProcessInfo.processInfo.environment["DYSPROSIUM_SHOW_SHIELD_SHEET"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    isShowingShieldSheet = true
                }
            }
            #endif
        }
        .onChange(of: allowScrollCollapse) { _, allowed in
            if !allowed, chromeCollapse.progress > 0 {
                chromeCollapse.setExternalProgress(0, animated: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                browserStore.checkClipboardForNewURL()
            }
        }
        .onChange(of: browserStore.activeTabID) { _, _ in
            isAddressEditing = false
            chromeCollapse.setExternalProgress(0, animated: false)
            omniboxSuggestions = []
            addressInput = session.omniboxDisplayText
            syncDialogInputsForActiveSession()
            wireAllSessionCallbacks()
        }
        .onChange(of: browserStore.tabs.map(\.id)) { _, _ in
            wireAllSessionCallbacks()
        }
        .onChange(of: session.activeJSDialog?.id) { _, _ in
            syncJSDialogPromptInput()
        }
        .onChange(of: session.activeAuthChallenge?.id) { _, _ in
            authUsername = ""
            authPassword = ""
        }
        .onChange(of: session.currentURLString) { _, _ in
            if chromeCollapse.progress > 0 {
                chromeCollapse.setExternalProgress(0, animated: true)
            }
            if !isAddressEditing {
                addressInput = session.omniboxDisplayText
            }
        }
        .onChange(of: session.activePDF?.id) { _, _ in
            if chromeCollapse.progress > 0 {
                chromeCollapse.setExternalProgress(0, animated: true)
            }
            if !isAddressEditing {
                addressInput = session.omniboxDisplayText
            }
        }
        .onChange(of: isAddressEditing) { _, editing in
            if editing {
                if chromeCollapse.progress > 0 {
                    chromeCollapse.setExternalProgress(0, animated: true)
                }
                if session.activePDF?.isLocalFileSource == true {
                    addressInput = ""
                }
            } else {
                omniboxSuggestions = []
                addressInput = session.omniboxDisplayText
            }
        }
        .task(id: omniboxSuggestionTaskKey) {
            let query = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAddressEditing, !query.isEmpty else {
                omniboxSuggestions = []
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, isAddressEditing else { return }
            let fetched = await browserStore.omniboxSuggestions(for: query, limit: 5)
            guard !Task.isCancelled, isAddressEditing else { return }
            omniboxSuggestions = fetched.map {
                OmniboxDropdownItem(
                    id: $0.id,
                    title: $0.title,
                    urlString: $0.urlString,
                    isFavorite: $0.isFavorite
                )
            }
        }
        .onChange(of: session.mediaGroups.count) { _, newCount in
            #if DEBUG
            if newCount > 0, ProcessInfo.processInfo.environment["DYSPROSIUM_BROWSER_INITIAL_PANE"] == "radar" {
                isShowingRadarPopover = true
            }
            #endif
        }
        .sheet(isPresented: $isShowingRadarPopover) {
            mediaRadarPopoverContent
        }
        .fullScreenCover(item: $activeStreamPreview) { item in
            CleanroomStreamPlayerContainer(item: item)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingShieldSheet) {
            FilterShieldManagementSheet(session: session, browserStore: browserStore)
        }
        .sheet(isPresented: $isShowingTabsSheet) {
            BrowserTabsSheet(browserStore: browserStore)
        }
        .sheet(isPresented: $isShowingProfilesSheet) {
            ProfileManagementSheet(browserStore: browserStore)
        }
        .sheet(isPresented: $isShowingNewProfileSheet) {
            ProfileCreationSheet(browserStore: browserStore)
        }
        .sheet(isPresented: $isShowingClearDataSheet) {
            ClearBrowsingDataSheet(browserStore: browserStore, targetProfileID: browserStore.activeProfileID)
        }
        .sheet(isPresented: $isShowingBookmarksHistorySheet) {
            NavigationStack {
                BrowserStartPageView(
                    browserStore: browserStore,
                    topContentMargin: 0,
                    onSelectURL: { targetURL in
                        isShowingBookmarksHistorySheet = false
                        dismissOmniboxFocus()
                        addressInput = targetURL
                        session.load(urlString: targetURL)
                    },
                    onDismissContainer: {
                        isShowingBookmarksHistorySheet = false
                    }
                )
                .navigationTitle(L("Bookmarks & History"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Done")) {
                            isShowingBookmarksHistorySheet = false
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $favoriteEditorTarget) { target in
            FavoriteEditorSheet(
                browserStore: browserStore,
                target: target
            )
        }
        .sheet(item: $activeSharePayload) { payload in
            BrowserActivityView(activityItems: payload.items)
        }
        .saveFolderPickerFlow(isPresented: $isShowingGrantFolderPicker) {
            if pendingSavePDFAfterGrant, CustomSaveFolderManager.shared.status.isCustomActive {
                pendingSavePDFAfterGrant = false
                performSaveActivePDFToVault()
            } else {
                pendingSavePDFAfterGrant = false
            }
        }
    }

    private static func currentWindowTopSafeAreaInset() -> CGFloat {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive || windowScene.activationState == .foregroundInactive else {
                continue
            }
            if let keyWindow = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first {
                return keyWindow.safeAreaInsets.top
            }
        }
        return 0
    }

    private func syncAddressBarFromSession() {
        if !isAddressEditing {
            addressInput = session.omniboxDisplayText
        }
    }

    // MARK: - Compact 36 pt Horizontal Trailing Capsule (`[((•)) · [1] · ⋯]`)

    private var compactHorizontalTrailingCapsule: some View {
        HStack(spacing: 0) {
            Button {
                isShowingRadarPopover.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(tokens.glassIconPrimary)
                        .symbolEffect(.variableColor.iterative, isActive: session.isProbingMedia || session.activeProbeCount > 0)
                        .frame(width: 28, height: 28)

                    let radarCount = session.discoveredMediaBadgeCount
                    if radarCount > 0 {
                        Text(radarCount > 99 ? "99+" : "\(radarCount)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(tokens.onAccent)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(tokens.accent, in: Capsule())
                            .offset(x: 2, y: 2)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                session.discoveredMediaBadgeCount == 0
                    ? L("Media Radar")
                    : L("Media Radar (\(session.discoveredMediaBadgeCount))")
            )
            .accessibilityIdentifier("browser-radar-button")

            Button {
                session.capturePreviewSnapshot()
                isShowingTabsSheet = true
            } label: {
                Image(systemName: tabsToolbarSymbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(
                        session.isPrivate
                            ? tokens.privateAccent
                            : (browserStore.isMultiProfileEnabled ? tokens.accent : tokens.glassIconPrimary)
                    )
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                session.isPrivate
                    ? L("Private Tabs (\(activeScopeTabCount))")
                    : L("Tabs (\(activeScopeTabCount))")
            )
            .accessibilityIdentifier("browser-tabs-button")

            Menu {
                browserOverflowMenuSections
            } label: {
                Image(systemName: "ellipsis")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(tokens.glassIconPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("More"))
            .accessibilityIdentifier("browser-more-button")
        }
        .padding(.horizontal, 4)
        .frame(width: Self.horizontalTrailingCapsuleWidth, height: 36)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var horizontalBackButton: some View {
        Menu {
            ForEach(session.backHistoryItems) { item in
                Button {
                    session.navigateBackForward(offset: item.id)
                } label: {
                    Label(
                        item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title,
                        systemImage: "clock"
                    )
                }
            }
        } label: {
            Image(systemName: "chevron.left")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tokens.glassIconPrimary)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        } primaryAction: {
            session.navigateBack()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Back"))
        .accessibilityIdentifier("browser-back-button")
    }

    @ViewBuilder
    private var browserOverflowMenuSections: some View {
        Section {
            if session.activePDF == nil && session.backHistoryItems.count > 1 {
                Menu {
                    Button {
                        session.navigateBack()
                    } label: {
                        Label(L("Go Back"), systemImage: "chevron.left")
                    }
                    Divider()
                    ForEach(session.backHistoryItems) { item in
                        Button {
                            session.navigateBackForward(offset: item.id)
                        } label: {
                            Label(
                                item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title,
                                systemImage: "clock"
                            )
                        }
                    }
                } label: {
                    Label(L("Back"), systemImage: "chevron.left")
                }
            } else {
                Button {
                    session.navigateBack()
                } label: {
                    Label(L("Back"), systemImage: "chevron.left")
                }
                .disabled(!session.canGoBack)
            }

            if session.activePDF == nil && session.forwardHistoryItems.count > 1 {
                Menu {
                    Button {
                        session.navigateForward()
                    } label: {
                        Label(L("Go Forward"), systemImage: "chevron.right")
                    }
                    Divider()
                    ForEach(session.forwardHistoryItems) { item in
                        Button {
                            session.navigateBackForward(offset: item.id)
                        } label: {
                            Label(
                                item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title,
                                systemImage: "clock"
                            )
                        }
                    }
                } label: {
                    Label(L("Forward"), systemImage: "chevron.right")
                }
            } else {
                Button {
                    session.navigateForward()
                } label: {
                    Label(L("Forward"), systemImage: "chevron.right")
                }
                .disabled(!session.canGoForward)
            }

            if !session.currentURLString.isEmpty {
                Button {
                    session.reloadCurrentContent()
                } label: {
                    Label(
                        session.activePDF != nil ? L("Reload PDF") : L("Reload Webpage"),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
        }

        if !session.currentURLString.isEmpty {
            Section {
                Button {
                    if let activePDF = session.activePDF {
                        withAnimation(.snappy(duration: 0.2)) {
                            activePDF.isSearchVisible = true
                        }
                    } else {
                        session.presentFindInPage()
                    }
                } label: {
                    Label(
                        session.activePDF != nil ? L("Find in PDF") : L("Find on Page"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }

                if let activePDF = session.activePDF {
                    Button {
                        if activePDF.isSavedInVault {
                            onOpenDownloadsTab()
                        } else {
                            saveActivePDFToVault()
                        }
                    } label: {
                        Label(
                            activePDF.isSavedInVault
                                ? L("View Saved PDF in Downloads")
                                : L("Save PDF to Downloads (\(activePDF.formattedFileSize))"),
                            systemImage: activePDF.isSavedInVault ? "checkmark.circle.fill" : "arrow.down.to.line"
                        )
                    }

                    Button {
                        activeSharePayload = BrowserSharePayload(items: [activePDF.localFileURL])
                    } label: {
                        Label(L("Share Original PDF…"), systemImage: "square.and.arrow.up")
                    }
                } else {
                    if let shareURL = session.currentURL {
                        Button {
                            activeSharePayload = BrowserSharePayload(items: [shareURL])
                        } label: {
                            Label(L("Share Page…"), systemImage: "square.and.arrow.up")
                        }
                    }

                    Button {
                        exportCurrentPageAsPDF()
                    } label: {
                        Label(L("Save as PDF…"), systemImage: "doc.richtext")
                    }
                }

                if session.currentURL?.isFileURL != true {
                    Button {
                        UIPasteboard.general.string = session.currentURLString
                        showTransientToast(
                            BrowserToastBanner(
                                icon: "doc.on.doc",
                                title: L("Copied Link"),
                                tint: tokens.accent,
                                actionTitle: nil,
                                action: nil
                            )
                        )
                    } label: {
                        Label(L("Copy Link"), systemImage: "doc.on.doc")
                    }
                }

                if let existing = browserStore.existingBookmark(for: session.currentURLString) {
                    Button {
                        favoriteEditorTarget = .edit(existing)
                    } label: {
                        Label(L("Edit Favorite…"), systemImage: "star.fill")
                    }

                    Button(role: .destructive) {
                        browserStore.removeBookmark(id: existing.id)
                    } label: {
                        Label(L("Remove Favorite"), systemImage: "star.slash")
                    }
                } else {
                    Button {
                        let title = session.pageTitle.isEmpty ? session.displayHost : session.pageTitle
                        favoriteEditorTarget = .prefilled(
                            title: title,
                            urlString: session.currentURLString,
                            defaultFolderID: nil
                        )
                    } label: {
                        Label(L("Add to Favorites…"), systemImage: "star")
                    }
                }
            }
        }

        Section {
            if browserStore.isMultiProfileEnabled {
                Menu {
                    ProfileSwitcherMenuContent(
                        browserStore: browserStore,
                        selectedProfileID: session.isPrivate ? "" : browserStore.activeProfileID,
                        onNewProfile: { isShowingNewProfileSheet = true },
                        onManageProfiles: { isShowingProfilesSheet = true }
                    )
                } label: {
                    Label(L("Profile: \(browserStore.activeProfile.localizedDisplayName)"), systemImage: browserStore.activeProfile.symbolName)
                }
            } else {
                Button {
                    isShowingNewProfileSheet = true
                } label: {
                    Label(L("New Profile…"), systemImage: "person.crop.circle.badge.plus")
                }
            }

            Button {
                isShowingBookmarksHistorySheet = true
            } label: {
                Label(L("Bookmarks & History"), systemImage: "book")
            }

            Button {
                browserStore.openNewTab(isPrivate: false, activate: true)
            } label: {
                Label(L("New Tab"), systemImage: "plus.square")
            }

            Button {
                browserStore.openNewTab(isPrivate: true, activate: true)
            } label: {
                Label(L("New Private Tab"), systemImage: "hand.raised")
            }

            Button(role: .destructive) {
                isShowingClearDataSheet = true
            } label: {
                Label(L("Clear Browsing Data…"), systemImage: "trash.slash")
            }
        }
    }

    // MARK: - Z = 1 Persistent Omnibox Inner Content

    private var omniboxExpandedInnerContent: some View {
        let showProfileChip = browserStore.isMultiProfileEnabled && !session.isPrivate && !isAddressEditing
        return HStack(spacing: 4) {
            omniboxShieldControl

            OmniboxAddressField(
                tabID: session.id,
                placeholder: session.isPrivate ? L("Private search or URL…") : L("Search or enter website"),
                focusTrigger: omniboxFocusTrigger,
                dismissTrigger: omniboxDismissTrigger,
                text: $addressInput,
                isEditing: $isAddressEditing,
                onSubmit: { submitted in
                    handleOmniboxSubmit(submitted)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 22)

            if showProfileChip {
                omniboxProfileSwitcherChip
            }

            if !isAddressEditing && hasActivePageOrLoad {
                Button {
                    if session.isLoading {
                        session.stopCurrentLoad()
                    } else {
                        session.reloadCurrentContent()
                    }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 12.5, weight: session.isLoading ? .bold : .semibold))
                        .foregroundStyle(tokens.glassIconSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isLoading ? L("Stop Loading") : L("Refresh"))
                .accessibilityIdentifier("browser-reload-button")
            }
        }
        .padding(.leading, 3)
        .padding(.trailing, (!isAddressEditing && (hasActivePageOrLoad || showProfileChip)) ? 3 : 10)
    }

    private var omniboxProfileSwitcherChip: some View {
        let activeProfile = browserStore.activeProfile
        return Menu {
            ProfileSwitcherMenuContent(
                browserStore: browserStore,
                onNewProfile: { isShowingNewProfileSheet = true },
                onManageProfiles: { isShowingProfilesSheet = true }
            )
        } label: {
            Image(systemName: activeProfile.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 26, height: 26)
                .background(tokens.accentSubtleFill, in: Circle())
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Profile: \(activeProfile.localizedDisplayName)"))
        .accessibilityHint(L("Switch profile"))
        .accessibilityIdentifier("browser-profile-chip")
    }

    @ViewBuilder
    private var omniboxShieldControl: some View {
        if let activePDF = session.activePDF {
            Menu {
                Section("\(activePDF.suggestedFilename) · \(activePDF.formattedFileSize)") {
                    Label(
                        activePDF.isLocalFileSource ? L("Local PDF Document") : L("Online PDF · \(session.displayHost)"),
                        systemImage: activePDF.isLocalFileSource ? "doc.richtext" : (session.isSecureConnection ? "lock.fill" : "globe")
                    )
                }

                Section(L("Reading Appearance")) {
                    Picker(L("PDF Appearance"), selection: $browserStore.pdfAppearanceMode) {
                        ForEach(PDFAppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                }

                if activePDF.pageCount > 1 {
                    Section(L("Page Layout")) {
                        Picker(L("PDF Layout"), selection: $browserStore.pdfDisplayLayoutMode) {
                            ForEach(PDFDisplayLayoutMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                    }
                }

                Section(L("PDF Zoom")) {
                    ControlGroup {
                        Button {
                            activePDF.dispatch(.zoomOut)
                        } label: {
                            Label(L("Zoom Out −"), systemImage: "minus.magnifyingglass")
                        }
                        Button {
                            activePDF.dispatch(.resetZoom)
                        } label: {
                            Label(L("Fit Width"), systemImage: "arrow.uturn.backward")
                        }
                        Button {
                            activePDF.dispatch(.zoomIn)
                        } label: {
                            Label(L("Zoom In +"), systemImage: "plus.magnifyingglass")
                        }
                    }
                }

                Section {
                    Button {
                        if activePDF.isSavedInVault {
                            onOpenDownloadsTab()
                        } else {
                            saveActivePDFToVault()
                        }
                    } label: {
                        Label(
                            activePDF.isSavedInVault ? L("View in Downloads") : L("Save PDF to Downloads"),
                            systemImage: activePDF.isSavedInVault ? "checkmark.circle.fill" : "arrow.down.to.line"
                        )
                    }

                    Button {
                        activeSharePayload = BrowserSharePayload(items: [activePDF.localFileURL])
                    } label: {
                        Label(L("Share Original PDF…"), systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                omniboxLeadingIconView
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("PDF Reader Options"))
            .accessibilityIdentifier("browser-shield-button")
        } else if let host = session.currentBypassableHost, !isStartPageVisible {
            let tabIsPrivate = session.isPrivate
            let isSecure = session.isSecureConnection && session.currentURL?.scheme?.lowercased() == "https"
            let currentZoom = browserStore.effectivePageZoom(forHost: host, isPrivate: tabIsPrivate)
            let zoomPercent = Int((currentZoom * 100).rounded())
            let siteShieldEnabled = browserStore.effectiveShieldEnabled(forHost: host, isPrivate: tabIsPrivate)
            let siteDarkEnabled = browserStore.effectiveAutoDark(forHost: host, isPrivate: tabIsPrivate)
            let isDesktopSite = (browserStore.effectiveUserAgent(forHost: host, isPrivate: tabIsPrivate) == .macosSafari)

            Menu {
                Section(isSecure ? L("Secure HTTPS · \(host)") : L("Not Secure HTTP · \(host)")) {
                    Label(
                        isSecure ? L("Encrypted Connection") : L("Connection Not Encrypted"),
                        systemImage: isSecure ? "lock.fill" : "exclamationmark.triangle"
                    )
                }

                Section(L("Page Zoom · \(zoomPercent)%")) {
                    ControlGroup {
                        Button {
                            stepSiteZoom(forHost: host, direction: -1)
                        } label: {
                            Label(L("Zoom Out −"), systemImage: "minus.magnifyingglass")
                        }
                        .disabled(currentZoom <= SiteRuleRecord.minPageZoom + 0.01)

                        Button {
                            applySiteZoom(1.0, forHost: host)
                        } label: {
                            Label(L("Reset 100%"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(abs(currentZoom - 1.0) < 0.01)

                        Button {
                            stepSiteZoom(forHost: host, direction: 1)
                        } label: {
                            Label(L("Zoom In +"), systemImage: "plus.magnifyingglass")
                        }
                        .disabled(currentZoom >= SiteRuleRecord.maxPageZoom - 0.01)
                    }
                }

                Section {
                    Toggle(
                        isOn: Binding(
                            get: { siteShieldEnabled },
                            set: { enabled in
                                browserStore.updateSiteRule(
                                    forHost: host,
                                    shieldMode: enabled ? 1 : -1,
                                    isPrivate: tabIsPrivate
                                )
                            }
                        )
                    ) {
                        Label(L("Per-Site Shield"), systemImage: siteShieldEnabled ? "checkmark.shield.fill" : "shield.slash")
                    }

                    Toggle(
                        isOn: Binding(
                            get: { siteDarkEnabled },
                            set: { enabled in
                                browserStore.updateSiteRule(
                                    forHost: host,
                                    darkMode: enabled ? 1 : -1,
                                    isPrivate: tabIsPrivate
                                )
                            }
                        )
                    ) {
                        Label(L("Dark Mode on Site"), systemImage: siteDarkEnabled ? "moon.stars.fill" : "moon")
                    }

                    Menu {
                        Section(L("Theme Preset")) {
                            Picker(L("Web Theme"), selection: $browserStore.webDarkThemePreset) {
                                ForEach(DarkReaderEngine.WebDarkThemePreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                        }

                        Section(L("Global Mode")) {
                            Picker(L("Web Dark Mode"), selection: $browserStore.webDarkModeBehavior) {
                                ForEach(DarkReaderEngine.WebDarkModeBehavior.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                        }
                    } label: {
                        Label(
                            L("Web Theme (\(browserStore.webDarkThemePreset.title))"),
                            systemImage: "circle.lefthalf.filled"
                        )
                    }

                    Toggle(
                        isOn: Binding(
                            get: { isDesktopSite },
                            set: { useDesktop in
                                browserStore.updateSiteRule(
                                    forHost: host,
                                    uaMode: useDesktop ? 2 : 1,
                                    isPrivate: tabIsPrivate
                                )
                            }
                        )
                    ) {
                        Label(L("Request Desktop Website"), systemImage: "laptopcomputer")
                    }
                }

                Section {
                    Button {
                        session.rotateFingerprintAndReload()
                    } label: {
                        Label(L("Rotate Fingerprint & Reload"), systemImage: "viewfinder.circle")
                    }

                    Button {
                        isShowingShieldSheet = true
                    } label: {
                        Label(
                            L("Shield & Filters (\(shieldBadgeTitle))…"),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }
            } label: {
                omniboxLeadingIconView
            }
            .buttonStyle(.plain)
            .accessibilityLabel(omniboxShieldAccessibilityLabel)
            .accessibilityIdentifier("browser-shield-button")
        } else {
            Button {
                isShowingShieldSheet = true
            } label: {
                omniboxLeadingIconView
            }
            .buttonStyle(.plain)
            .accessibilityLabel(omniboxShieldAccessibilityLabel)
            .accessibilityIdentifier("browser-shield-button")
        }
    }

    private var omniboxLeadingIconView: some View {
        Image(systemName: omniboxLeadingIcon)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(omniboxLeadingColor)
            .font(.system(size: 13, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private var omniboxAutocompleteDropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(omniboxSuggestions.enumerated()), id: \.element.id) { idx, item in
                Button {
                    selectOmniboxSuggestion(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isFavorite ? "star.fill" : "clock.arrow.circlepath")
                            .symbolRenderingMode(.monochrome)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.isFavorite ? tokens.bookmarkStar : tokens.glassIconSecondary)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title.isEmpty ? item.urlString : item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(item.urlString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 4)

                        Image(systemName: "arrow.up.left")
                            .symbolRenderingMode(.monochrome)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tokens.glassIconSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx < omniboxSuggestions.count - 1 {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("omnibox-autocomplete-dropdown")
    }

    private func popupBlockedBanner(for blockedURL: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.badge.minus")
                .symbolRenderingMode(.monochrome)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tokens.statusWarning)

            VStack(alignment: .leading, spacing: 0) {
                Text(L("Popup Blocked"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if let host = blockedURL.host(), !host.isEmpty {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(L("Allow")) {
                session.allowLastBlockedPopup()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .tint(tokens.accent)

            Button {
                session.dismissBlockedPopupBanner()
            } label: {
                Image(systemName: "xmark")
                    .symbolRenderingMode(.monochrome)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tokens.glassIconSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Dismiss Popup Banner"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: Capsule())
    }

    private func toastBannerView(_ toast: BrowserToastBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .symbolRenderingMode(.monochrome)
                .font(.caption.weight(.semibold))
                .foregroundStyle(toast.tint)

            Text(toast.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    toastDismissTask?.cancel()
                    withAnimation(.snappy(duration: 0.2)) {
                        activeToastBanner = nil
                    }
                    switch action {
                    case .jumpToTransfer(let jobID):
                        onJumpToTransfer(jobID)
                    case .openDownloads:
                        onOpenDownloadsTab()
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.mini)
                .tint(tokens.accent)
            }

            Button {
                toastDismissTask?.cancel()
                withAnimation(.snappy(duration: 0.2)) {
                    activeToastBanner = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .symbolRenderingMode(.monochrome)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tokens.glassIconSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Dismiss Notification"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: Capsule())
    }

    private var clipboardSuggestionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .symbolRenderingMode(.monochrome)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tokens.glassIconSecondary)

            Text(L("Clipboard Link"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            PasteButton(payloadType: String.self) { strings in
                browserStore.consumeOrDismissClipboardURL()
                if let first = strings.first {
                    handleOmniboxSubmit(first)
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .tint(tokens.accent)

            Button {
                browserStore.consumeOrDismissClipboardURL()
            } label: {
                Image(systemName: "xmark")
                    .symbolRenderingMode(.monochrome)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tokens.glassIconSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Dismiss Clipboard Prompt"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: Capsule())
    }

    private var mediaRadarPopoverContent: some View {
        MediaRadarSheet(
            session: session,
            scheduler: scheduler,
            defaultLanes: defaultLanes,
            onPlayStream: { chosen, displayTitle in
                let item = CleanroomStreamPreviewItem(
                    url: chosen.directPlayURL ?? chosen.url,
                    headers: chosen.headers,
                    title: displayTitle
                )
                isShowingRadarPopover = false
                let targetWebView = session.webView
                Task { @MainActor in
                    await targetWebView.pauseAllMediaPlayback()
                    try? await Task.sleep(for: .milliseconds(220))
                    activeStreamPreview = item
                }
            },
            onEnqueueSingle: { chosen, domain, filename in
                enqueueVariant(chosen, domain: domain, filename: filename)
            },
            onEnqueueBatch: { batch in
                for item in batch {
                    enqueueVariant(item.variant, domain: item.domain, filename: item.filename)
                }
                isShowingRadarPopover = false
            },
            onInspectTransfer: { jobID in
                isShowingRadarPopover = false
                onJumpToTransfer(jobID)
            },
            onOpenDownloads: {
                isShowingRadarPopover = false
                onOpenDownloadsTab()
            }
        )
        .presentationDetents([.medium, .large])
    }

    @discardableResult
    private func enqueueVariant(_ v: SniffedVariantOption, domain: String, filename: String) -> UUID? {
        guard v.isDownloadSupported else { return nil }
        let created = scheduler.enqueue(
            url: v.url,
            pairedAudioURL: v.pairedAudioURL,
            pairedAudioBytes: v.pairedAudioBytes,
            expectedTotalBytes: v.exactOrEstimatedBytes,
            siteDomainOverride: domain,
            lanes: defaultLanes,
            headers: v.headers,
            suggestedTitle: filename,
            preloadedManifestText: v.preloadedManifestText,
            sourceProfileID: session.transferSourceProfileID
        )
        return created.id
    }

    private func handleOmniboxSubmit(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        omniboxSuggestions = []
        isAddressEditing = false

        let candidateURL: URL? = {
            if trimmed.contains("://") { return URL(string: trimmed) }
            if !trimmed.contains(" ") && trimmed.contains(".") { return URL(string: "https://\(trimmed)") }
            return nil
        }()

        if let url = candidateURL, MediaURLClassifier.isDirectSingleAssetURL(url) {
            let activeSession = session
            addressInput = activeSession.currentURLString
            Task { @MainActor in
                let headers = await activeSession.buildHostScopedDownloadHeaders(for: url)
                let created = scheduler.enqueue(
                    url: url,
                    sourcePageURL: activeSession.currentURL,
                    lanes: defaultLanes,
                    headers: headers,
                    sourceProfileID: activeSession.transferSourceProfileID
                )
                onJumpToTransfer(created.id)
            }
            return
        }

        session.load(urlString: trimmed)
    }

    private func selectOmniboxSuggestion(_ item: OmniboxDropdownItem) {
        omniboxSuggestions = []
        dismissOmniboxFocus()
        addressInput = item.urlString
        session.load(urlString: item.urlString)
    }

    private func dismissOmniboxFocus() {
        isAddressEditing = false
        omniboxDismissTrigger &+= 1
    }

    private func exportCurrentPageAsPDF() {
        let activeSession = session
        Task { @MainActor in
            if let pdfURL = await activeSession.createCurrentPagePDF() {
                activeSharePayload = BrowserSharePayload(items: [pdfURL])
            } else {
                showTransientToast(
                    BrowserToastBanner(
                        icon: "exclamationmark.triangle.fill",
                        title: L("Could not create page PDF"),
                        tint: tokens.statusWarning,
                        actionTitle: nil,
                        action: nil
                    )
                )
            }
        }
    }

    private func saveActivePDFToVault() {
        // Anti-split-brain guard: if a sibling LiveContainer host configured a Custom Save Folder
        // that this host hasn't granted yet, prompt for 1-tap folder grant before saving.
        if CustomSaveFolderManager.shared.status.needsHostGrant {
            pendingSavePDFAfterGrant = true
            isShowingGrantFolderPicker = true
            return
        }
        performSaveActivePDFToVault()
    }

    private func performSaveActivePDFToVault() {
        let activeSession = session
        Task { @MainActor in
            if let savedURL = await activeSession.saveActivePDFToVault() {
                showTransientToast(
                    BrowserToastBanner(
                        icon: "checkmark.circle.fill",
                        title: L("Saved \(savedURL.lastPathComponent)"),
                        tint: tokens.statusSuccess,
                        actionTitle: L("View"),
                        action: .openDownloads
                    )
                )
            } else {
                showTransientToast(
                    BrowserToastBanner(
                        icon: "exclamationmark.triangle.fill",
                        title: L("Could not save PDF"),
                        tint: tokens.statusDanger,
                        actionTitle: nil,
                        action: nil
                    )
                )
            }
        }
    }

    private func showTransientToast(_ banner: BrowserToastBanner) {
        toastDismissTask?.cancel()
        activeToastBanner = banner
        let bannerID = banner.id
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, activeToastBanner?.id == bannerID else { return }
            withAnimation(.snappy(duration: 0.2)) {
                activeToastBanner = nil
            }
        }
    }

    private func syncDialogInputsForActiveSession() {
        syncJSDialogPromptInput()
        authUsername = ""
        authPassword = ""
    }

    private func syncJSDialogPromptInput() {
        if case .prompt(let defaultText) = session.activeJSDialog?.kind {
            jsPromptInput = defaultText ?? ""
        } else {
            jsPromptInput = ""
        }
    }

    private func authAlertTitle(for challenge: WebAuthChallengeRequest?) -> String {
        guard let challenge else { return L("Authentication") }
        switch challenge.kind {
        case .httpCredentials:
            return L("Sign in to \(challenge.host)")
        case .lanSelfSignedTrust:
            return L("Untrusted Local Certificate")
        }
    }

    private func wireAllSessionCallbacks() {
        // Capture lightweight state bindings and `[weak scheduler]` (never `self`/`browserStore`)
        // to prevent `browserStore -> tabs -> session -> closure -> browserStore` retain cycles
        // and read the live lane count & theme tokens dynamically on each callback invocation.
        let toastBinding = $activeToastBanner
        let dismissTaskBinding = $toastDismissTask
        let shareBinding = $activeSharePayload
        let weakScheduler = scheduler

        let presentToast: @MainActor (BrowserToastBanner) -> Void = { banner in
            dismissTaskBinding.wrappedValue?.cancel()
            toastBinding.wrappedValue = banner
            let bannerID = banner.id
            dismissTaskBinding.wrappedValue = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, toastBinding.wrappedValue?.id == bannerID else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    toastBinding.wrappedValue = nil
                }
            }
        }

        for tab in browserStore.tabs {
            tab.onEnqueueBrowserDownload = { [weak tab, weak weakScheduler] request in
                guard let sched = weakScheduler else { return }
                let liveTokens = DysprosiumThemeStore.shared.tokens
                let job = sched.enqueue(
                    url: request.url,
                    sourcePageURL: tab?.currentURL,
                    expectedTotalBytes: request.expectedBytes,
                    siteDomainOverride: request.sourceDomain,
                    lanes: sched.defaultLanesPerTransfer,
                    headers: request.headers,
                    suggestedTitle: request.suggestedFilename,
                    sourceProfileID: request.sourceProfileID
                )
                let fallbackName = request.url.lastPathComponent
                let resolvedName = (request.suggestedFilename?.isEmpty == false ? request.suggestedFilename : nil)
                    ?? (fallbackName.isEmpty ? nil : fallbackName)
                let toastTitle = resolvedName.map { L("Downloading \($0)") } ?? L("Downloading file")
                presentToast(
                    BrowserToastBanner(
                        icon: "arrow.down.circle.fill",
                        title: toastTitle,
                        tint: liveTokens.accent,
                        actionTitle: L("View"),
                        action: .jumpToTransfer(job.id)
                    )
                )
            }
            tab.onWKDownloadFinished = { fileURL in
                let liveTokens = DysprosiumThemeStore.shared.tokens
                presentToast(
                    BrowserToastBanner(
                        icon: "checkmark.circle.fill",
                        title: L("Saved \(fileURL.lastPathComponent)"),
                        tint: liveTokens.statusSuccess,
                        actionTitle: L("View"),
                        action: .openDownloads
                    )
                )
            }
            tab.onWKDownloadFailed = { message in
                let liveTokens = DysprosiumThemeStore.shared.tokens
                presentToast(
                    BrowserToastBanner(
                        icon: "exclamationmark.triangle.fill",
                        title: message,
                        tint: liveTokens.statusDanger,
                        actionTitle: nil,
                        action: nil
                    )
                )
            }
            tab.onShareURL = { url in
                shareBinding.wrappedValue = BrowserSharePayload(items: [url])
            }
        }
    }

    private static let zoomSteps: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

    private func stepSiteZoom(forHost host: String, direction: Int) {
        let current = browserStore.effectivePageZoom(forHost: host, isPrivate: session.isPrivate)
        let nextZoom: Double
        if direction > 0 {
            nextZoom = Self.zoomSteps.first(where: { $0 > current + 0.01 }) ?? SiteRuleRecord.maxPageZoom
        } else {
            nextZoom = Self.zoomSteps.last(where: { $0 < current - 0.01 }) ?? SiteRuleRecord.minPageZoom
        }
        applySiteZoom(nextZoom, forHost: host)
    }

    private func applySiteZoom(_ zoom: Double, forHost host: String) {
        let clamped = SiteRuleRecord.clampedZoom(zoom)
        if abs(clamped - 1.0) < 0.01 {
            browserStore.updateSiteRule(forHost: host, resetPageZoom: true, isPrivate: session.isPrivate)
            session.applyPageZoom(1.0)
        } else {
            browserStore.updateSiteRule(forHost: host, pageZoom: clamped, isPrivate: session.isPrivate)
            session.applyPageZoom(clamped)
        }
    }

    private var keyboardShortcutsLayer: some View {
        Group {
            Button(L("Focus Address Bar")) {
                isAddressEditing = true
                omniboxFocusTrigger &+= 1
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(L("New Tab")) {
                browserStore.openNewTab(isPrivate: session.isPrivate, activate: true)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button(L("Close Tab")) {
                browserStore.closeTab(id: session.id)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button(L("Reopen Closed Tab")) {
                _ = browserStore.reopenLastClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(L("Reload")) {
                if !isStartPageVisible {
                    session.reloadCurrentContent()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(L("Find on Page")) {
                if let activePDF = session.activePDF {
                    withAnimation(.snappy(duration: 0.2)) {
                        activePDF.isSearchVisible = true
                    }
                } else if !isStartPageVisible {
                    session.presentFindInPage()
                }
            }
            .keyboardShortcut("f", modifiers: .command)

            Button(L("Back")) {
                if session.canGoBack {
                    session.navigateBack()
                }
            }
            .keyboardShortcut("[", modifiers: .command)

            Button(L("Forward")) {
                if session.canGoForward {
                    session.navigateForward()
                }
            }
            .keyboardShortcut("]", modifiers: .command)

            Button(L("Zoom In")) {
                if let activePDF = session.activePDF {
                    activePDF.dispatch(.zoomIn)
                } else if let host = session.currentBypassableHost, !isStartPageVisible {
                    stepSiteZoom(forHost: host, direction: 1)
                }
            }
            .keyboardShortcut("=", modifiers: .command)

            Button(L("Zoom In")) {
                if let activePDF = session.activePDF {
                    activePDF.dispatch(.zoomIn)
                } else if let host = session.currentBypassableHost, !isStartPageVisible {
                    stepSiteZoom(forHost: host, direction: 1)
                }
            }
            .keyboardShortcut("+", modifiers: .command)

            Button(L("Zoom Out")) {
                if let activePDF = session.activePDF {
                    activePDF.dispatch(.zoomOut)
                } else if let host = session.currentBypassableHost, !isStartPageVisible {
                    stepSiteZoom(forHost: host, direction: -1)
                }
            }
            .keyboardShortcut("-", modifiers: .command)

            Button(L("Reset Zoom")) {
                if let activePDF = session.activePDF {
                    activePDF.dispatch(.resetZoom)
                } else if let host = session.currentBypassableHost, !isStartPageVisible {
                    applySiteZoom(1.0, forHost: host)
                }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .clipped()
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static var badgedRadarImageCache: [String: UIImage] = [:]

    private func makeBadgedRadarToolbarImage(count: Int, compact: Bool) -> UIImage {
        let clamped = min(count, 100)
        let cacheKey = "\(clamped)|\(compact ? "c" : "r")|\(tokens.preset.rawValue)"
        if let cached = Self.badgedRadarImageCache[cacheKey] {
            return cached
        }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark] {
            for scale: CGFloat in [2.0, 3.0] {
                let traits = UITraitCollection { mutable in
                    mutable.userInterfaceStyle = style
                    mutable.displayScale = scale
                }
                let img = renderBadgedRadarToolbarImage(count: clamped, compact: compact, scale: scale, traits: traits)
                    .withRenderingMode(.alwaysOriginal)
                asset.register(img, with: traits)
            }
        }
        let resolved = asset.image(with: .current).withRenderingMode(.alwaysOriginal)
        if Self.badgedRadarImageCache.count >= 32 {
            Self.badgedRadarImageCache.removeAll(keepingCapacity: true)
        }
        Self.badgedRadarImageCache[cacheKey] = resolved
        return resolved
    }

    private func renderBadgedRadarToolbarImage(count: Int, compact: Bool, scale: CGFloat, traits: UITraitCollection) -> UIImage {
        let canvasSize = compact ? CGSize(width: 24, height: 22) : CGSize(width: 26, height: 24)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let badgeText = count > 99 ? "99+" : "\(count)"
        let font = UIFont.monospacedDigitSystemFont(ofSize: compact ? 8.0 : 8.5, weight: .bold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(tokens.onAccent).resolvedColor(with: traits)
        ]
        let textSize = (badgeText as NSString).size(withAttributes: textAttrs)
        let badgeHeight: CGFloat = compact ? 10.5 : 11.5
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 5.0)
        let badgeRect = CGRect(
            x: canvasSize.width - badgeWidth,
            y: 1.0,
            width: badgeWidth,
            height: badgeHeight
        )

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: compact ? 13.5 : 15.0, weight: .medium)
        let baseSymbol = UIImage(systemName: "dot.radiowaves.left.and.right", withConfiguration: symbolConfig)?
            .withTintColor(UIColor(tokens.glassIconPrimary).resolvedColor(with: traits), renderingMode: .alwaysOriginal)

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { rendererCtx in
            if let baseSymbol {
                let symSize = baseSymbol.size
                let symOrigin = CGPoint(
                    x: round((canvasSize.width - symSize.width) * 0.5),
                    y: round((canvasSize.height - symSize.height) * 0.5 + 1.0)
                )
                baseSymbol.draw(in: CGRect(origin: symOrigin, size: symSize))
            }

            let cg = rendererCtx.cgContext
            cg.saveGState()
            cg.setBlendMode(.clear)
            let moatRect = badgeRect.insetBy(dx: -1.2, dy: -1.2)
            UIBezierPath(roundedRect: moatRect, cornerRadius: moatRect.height * 0.5).fill()
            cg.restoreGState()

            UIColor(tokens.accent).resolvedColor(with: traits).setFill()
            UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeHeight * 0.5).fill()

            let textOrigin = CGPoint(
                x: badgeRect.midX - textSize.width * 0.5,
                y: badgeRect.midY - textSize.height * 0.5
            )
            (badgeText as NSString).draw(at: textOrigin, withAttributes: textAttrs)
        }
    }

    private var tabsToolbarSymbol: String {
        let n = min(max(activeScopeTabCount, 1), 50)
        return "\(n).square"
    }

    private var isShieldPausedOnCurrentSite: Bool {
        session.isShieldEnabled
            && !browserStore.effectiveShieldEnabled(forHost: session.currentBypassableHost, isPrivate: session.isPrivate)
            && session.currentBypassableHost != nil
    }

    private var isInsecureHTTPPage: Bool {
        guard !isStartPageVisible, session.currentBypassableHost != nil else { return false }
        if session.currentURL?.scheme?.lowercased() == "http" {
            return true
        }
        return !session.isLoading && !session.isSecureConnection
    }

    private var omniboxLeadingIcon: String {
        if session.activePDF != nil { return "doc.richtext.fill" }
        if isShieldPausedOnCurrentSite { return "shield.slash" }
        if isInsecureHTTPPage { return "exclamationmark.triangle.fill" }
        if session.isPrivate { return "hand.raised.fill" }
        if session.isShieldEnabled {
            return !isStartPageVisible && session.isSecureConnection ? "lock.shield.fill" : "checkmark.shield.fill"
        }
        return (!isStartPageVisible && session.isSecureConnection) ? "lock.fill" : "shield.slash"
    }

    private var omniboxLeadingColor: Color {
        if session.activePDF != nil { return tokens.accent }
        if isShieldPausedOnCurrentSite || isInsecureHTTPPage { return tokens.statusWarning }
        if session.isPrivate { return tokens.privateAccent }
        if session.isShieldEnabled { return tokens.statusSuccess }
        return tokens.glassIconSecondary
    }

    private var omniboxShieldAccessibilityLabel: String {
        if isShieldPausedOnCurrentSite, let host = session.currentBypassableHost {
            return L("Content Shield Paused on \(host)")
        }
        guard session.isShieldEnabled else {
            return L("Content Shield Off")
        }
        if let host = session.currentBypassableHost {
            return L("Content Shield Active on \(host) (\(shieldBadgeTitle))")
        }
        return L("Content Shield (\(shieldBadgeTitle))")
    }

    private var shieldBadgeTitle: String {
        guard session.isShieldEnabled else { return L("Off") }
        if isShieldPausedOnCurrentSite { return L("Paused") }
        let n = contentBlocker.activeRuleCount
        if n >= 1_000 {
            return L("\(n / 1_000)k")
        }
        return contentBlocker.isSyncing ? L("Sync") : L("On")
    }
}

// MARK: - Native UIKit `UITextField` Omnibox (`clearButtonMode = .whileEditing` + Select-All on Focus)

private struct OmniboxLoadingProgressStrip: View {
    let session: CleanroomWebKitSession
    let accentColor: Color

    var body: some View {
        if session.isLoading {
            let clamped = min(1.0, max(0.10, session.estimatedProgress))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.primary.opacity(0.06))
                Rectangle()
                    .fill(accentColor)
                    .scaleEffect(x: clamped, y: 1, anchor: .leading)
                    .animation(.easeOut(duration: 0.18), value: clamped)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 12)
            .transition(.opacity)
        }
    }
}

private struct OmniboxAddressField: UIViewRepresentable {
    let tabID: UUID
    let placeholder: String
    let focusTrigger: Int
    let dismissTrigger: Int
    @Binding var text: String
    @Binding var isEditing: Bool
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            parent: self,
            tabID: tabID,
            focusTrigger: focusTrigger,
            dismissTrigger: dismissTrigger
        )
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.text = text
        tf.font = UIFont.preferredFont(forTextStyle: .subheadline)
        tf.textColor = .label
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.keyboardType = .URL
        tf.returnKeyType = .go
        tf.clearButtonMode = .whileEditing
        tf.accessibilityIdentifier = "browser-address-field"
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
        if context.coordinator.lastTabID != tabID {
            context.coordinator.lastTabID = tabID
            if uiView.isFirstResponder {
                let focusGen = context.coordinator.focusRequestGeneration
                // Defer first-responder resignation out of SwiftUI's AttributeGraph update transaction
                // to prevent iOS 27.2 `_UIHostingView.canBecomeFirstResponder` re-entrancy cycles.
                DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
                    guard let uiView, let coordinator,
                          coordinator.focusRequestGeneration == focusGen,
                          uiView.isFirstResponder else { return }
                    uiView.resignFirstResponder()
                }
            }
            uiView.text = text
        } else if !uiView.isFirstResponder && uiView.text != text {
            uiView.text = text
        }

        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            context.coordinator.focusRequestGeneration &+= 1
            Task { @MainActor [weak uiView] in
                guard let uiView else { return }
                if !uiView.isFirstResponder {
                    uiView.becomeFirstResponder()
                }
                if let txt = uiView.text, !txt.isEmpty {
                    uiView.selectAll(nil)
                }
            }
        }

        if context.coordinator.lastDismissTrigger != dismissTrigger {
            context.coordinator.lastDismissTrigger = dismissTrigger
            if uiView.isFirstResponder {
                let focusGen = context.coordinator.focusRequestGeneration
                DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
                    guard let uiView, let coordinator,
                          coordinator.focusRequestGeneration == focusGen,
                          uiView.isFirstResponder else { return }
                    uiView.resignFirstResponder()
                }
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: OmniboxAddressField
        var lastTabID: UUID
        var lastFocusTrigger: Int
        var lastDismissTrigger: Int
        var focusRequestGeneration: Int = 0

        init(
            parent: OmniboxAddressField,
            tabID: UUID,
            focusTrigger: Int,
            dismissTrigger: Int
        ) {
            self.parent = parent
            self.lastTabID = tabID
            self.lastFocusTrigger = focusTrigger
            self.lastDismissTrigger = dismissTrigger
        }

        @objc func editingChanged(_ sender: UITextField) {
            let current = sender.text ?? ""
            if parent.text != current {
                parent.text = current
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isEditing = true
            DispatchQueue.main.async {
                if textField.isFirstResponder, let txt = textField.text, !txt.isEmpty {
                    textField.selectAll(nil)
                }
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isEditing = false
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            parent.text = ""
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let submitted = textField.text ?? ""
            textField.resignFirstResponder()
            parent.isEditing = false
            parent.onSubmit(submitted)
            return true
        }
    }
}

// MARK: - Isolated Continuous Scroll-Collapse State & Persistent Liquid Glass Overlay

@MainActor
@Observable
final class BrowserChromeCollapseModel {
    /// Continuous collapse fraction: `0.0` (expanded 36 pt omnibox) ... `1.0` (24 pt centered domain pill).
    var progress: CGFloat = 0 {
        didSet {
            updateImmersiveHiddenIfNeeded()
        }
    }

    /// Discrete hysteresis-filtered immersive state (`true` when chrome is collapsed to the compact pill).
    /// Drives system status-bar hiding (`prefersStatusBarHidden`) at most once per direction change—never at 120 Hz.
    private(set) var isImmersiveHidden: Bool = false

    @ObservationIgnored
    var onImmersiveHiddenChange: ((Bool) -> Void)?

    @ObservationIgnored
    var onExternalProgressChange: ((CGFloat) -> Void)?

    func updateFromScroll(_ nextProgress: CGFloat, animated: Bool) {
        let clamped = min(1, max(0, nextProgress))
        guard abs(progress - clamped) > 0.001 else { return }
        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                progress = clamped
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                progress = clamped
            }
        }
    }

    func setExternalProgress(_ target: CGFloat, animated: Bool) {
        let clamped = min(1, max(0, target))
        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                progress = clamped
            }
        } else {
            progress = clamped
        }
        onExternalProgressChange?(clamped)
    }

    private func updateImmersiveHiddenIfNeeded() {
        let next: Bool
        if progress >= 0.55 {
            next = true
        } else if progress <= 0.45 {
            next = false
        } else {
            return
        }
        guard next != isImmersiveHidden else { return }
        isImmersiveHidden = next
        onImmersiveHiddenChange?(next)
    }
}

@MainActor
private enum BrowserCompactPillWidthCache {
    private static var widths: [String: CGFloat] = [:]
    private static let font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)

    static func width(title: String, hasIcon: Bool, maxWidth: CGFloat) -> CGFloat {
        let key = "\(title)|\(hasIcon ? 1 : 0)|\(Int(maxWidth))"
        if let cached = widths[key] {
            return cached
        }
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let iconWidth: CGFloat = hasIcon ? 14 : 0
        let resolved = min(maxWidth, max(72, textWidth + iconWidth + 24))
        if widths.count >= 64 {
            widths.removeAll(keepingCapacity: true)
        }
        widths[key] = resolved
        return resolved
    }
}

private struct BrowserFloatingTopChromeOverlay<
    OmniboxExpandedContent: View,
    BackButtonContent: View,
    TrailingCapsuleContent: View
>: View {
    let collapseModel: BrowserChromeCollapseModel
    let allowScrollCollapse: Bool
    let viewportWidth: CGFloat
    let layout: BrowserTopChromeLayout
    let isVerticalRailActive: Bool
    let hasBackButton: Bool
    let trailingClusterWidth: CGFloat
    let compactDomainTitle: String
    let isPrivate: Bool
    let isInsecureHTTP: Bool
    let profileSymbolName: String?
    let profileAccent: Color
    let privateAccent: Color
    let warningTint: Color
    let glassIconPrimary: Color
    let progressAccent: Color
    let session: CleanroomWebKitSession
    let canSwipeSwitchTabs: Bool
    let onSwipeTabDelta: (Int) -> Void
    let onExpandFromPill: () -> Void
    @ViewBuilder let omniboxExpandedContent: () -> OmniboxExpandedContent
    @ViewBuilder let backButtonContent: () -> BackButtonContent
    @ViewBuilder let trailingCapsuleContent: () -> TrailingCapsuleContent

    private var measuredCompactPillWidth: CGFloat {
        let hasIcon = isPrivate || isInsecureHTTP || profileSymbolName != nil
        return BrowserCompactPillWidthCache.width(
            title: compactDomainTitle,
            hasIcon: hasIcon,
            maxWidth: layout.compactMaxWidth
        )
    }

    var body: some View {
        let p: CGFloat = allowScrollCollapse ? min(1, max(0, collapseModel.progress)) : 0
        let capsuleFrame = layout.omniboxFrame(
            viewportWidth: viewportWidth,
            isVerticalRailActive: isVerticalRailActive,
            hasBackButton: hasBackButton,
            trailingClusterWidth: trailingClusterWidth,
            compactPillWidth: measuredCompactPillWidth,
            progress: p
        )
        let expandedOpacity = max(0, 1 - p * 2.15)
        let compactOpacity = max(0, (p - 0.42) / 0.58)
        let isExpandedInteractive = p < 0.35
        let showExpandedSiblings = !isVerticalRailActive && p < 0.35
        let isPillTapActive = p >= 0.5

        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if showExpandedSiblings && hasBackButton {
                    backButtonContent()
                        .glassEffectTransition(.materialize)
                        .offset(x: layout.leading, y: layout.top)
                        .transition(.opacity)
                }

                // Single persistent Liquid Glass capsule: smoothly morphs from 36 pt omnibox
                // to 24 pt top-edge centered domain pill without ever unmounting `UITextField`.
                ZStack {
                    omniboxExpandedContent()
                        .opacity(expandedOpacity)
                        .allowsHitTesting(isExpandedInteractive)
                        .accessibilityHidden(!isExpandedInteractive)

                    HStack(spacing: 4) {
                        if isPrivate {
                            Image(systemName: "hand.raised.fill")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(privateAccent)
                        } else if isInsecureHTTP {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(warningTint)
                        } else if let profileSymbolName {
                            Image(systemName: profileSymbolName)
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(profileAccent)
                        }

                        Text(compactDomainTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(glassIconPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .opacity(compactOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .frame(width: capsuleFrame.width, height: capsuleFrame.height)
                .overlay(alignment: .bottom) {
                    if expandedOpacity > 0.01 {
                        OmniboxLoadingProgressStrip(
                            session: session,
                            accentColor: progressAccent
                        )
                        .clipShape(Capsule())
                        .opacity(expandedOpacity)
                    }
                }
                .clipShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .simultaneousGesture(
                    DragGesture(minimumDistance: (canSwipeSwitchTabs && isExpandedInteractive) ? 24 : 10_000, coordinateSpace: .local)
                        .onEnded { value in
                            guard canSwipeSwitchTabs && isExpandedInteractive else { return }
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) >= 48, abs(dx) > abs(dy) * 1.4 else { return }
                            onSwipeTabDelta(dx < 0 ? 1 : -1)
                        }
                )
                .overlay(alignment: .top) {
                    if isPillTapActive {
                        Button(action: onExpandFromPill) {
                            Color.clear
                                .frame(width: max(capsuleFrame.width, 84), height: capsuleFrame.height + 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Expand address bar, \(compactDomainTitle)"))
                        .accessibilityIdentifier("browser-minimized-pill")
                    }
                }
                .offset(x: capsuleFrame.minX, y: capsuleFrame.minY)

                if showExpandedSiblings {
                    let trailingX = max(layout.leading, viewportWidth - layout.trailing - trailingClusterWidth)
                    trailingCapsuleContent()
                        .glassEffectTransition(.materialize)
                        .offset(x: trailingX, y: layout.top)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.snappy(duration: 0.2), value: showExpandedSiblings)
        }
    }
}

// MARK: - 100% Native iOS 27.2 `WKWebView.obscuredContentInsets` + Dynamic Top Inset Host

private final class NativeWebKitHostController: UIViewController {
    private(set) weak var hostedWebView: WKWebView?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var scrollState = BrowserChromeScrollState()
    private var isUpdatingModelInternally = false
    private var lastAppliedMaxViewportTop: CGFloat = -1
    private var lastAppliedTopInset: CGFloat = -1
    private var lastAppliedBottomInset: CGFloat = -1

    weak var collapseModel: BrowserChromeCollapseModel? {
        didSet {
            bindExternalCollapseCallback()
        }
    }
    var allowScrollCollapse: Bool = true {
        didSet {
            if oldValue != allowScrollCollapse {
                syncWebViewInsets()
            }
        }
    }
    var isScrollViewActive: Bool = true {
        didSet {
            if oldValue != isScrollViewActive {
                syncContentScrollViewOwnership()
            }
        }
    }

    var desiredTopOverlayHeight: CGFloat = 0 {
        didSet {
            if abs(oldValue - desiredTopOverlayHeight) > 0.5 {
                syncViewportInsetBounds()
                syncWebViewInsets()
            }
        }
    }

    deinit {
        contentOffsetObservation?.invalidate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncContentScrollViewOwnership()
        syncWebViewInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncWebViewInsets()
    }

    private func syncContentScrollViewOwnership() {
        if isScrollViewActive, let webView = hostedWebView {
            setContentScrollView(webView.scrollView, for: [.top, .bottom])
        } else {
            setContentScrollView(nil, for: [.top, .bottom])
        }
    }

    private func syncViewportInsetBounds() {
        guard let webView = hostedWebView else { return }
        let clampedTop = max(0, desiredTopOverlayHeight)
        guard abs(lastAppliedMaxViewportTop - clampedTop) > 0.5 else { return }
        lastAppliedMaxViewportTop = clampedTop
        webView.setMinimumViewportInset(
            .zero,
            maximumViewportInset: UIEdgeInsets(top: clampedTop, left: 0, bottom: 0, right: 0)
        )
    }

    func syncWebViewInsets() {
        guard let webView = hostedWebView else { return }
        let scrollView = webView.scrollView
        let p = allowScrollCollapse ? scrollState.progress : 0
        let hardwareTop = max(0, view.window?.safeAreaInsets.top ?? 0)
        let expandedTop = max(hardwareTop, desiredTopOverlayHeight)
        let desiredTop = max(hardwareTop, expandedTop * (1 - p))
        let currentOffsetY = scrollView.contentOffset.y
        // Floor by `-contentOffset.y` while still within the initial top band so UIKit never
        // clamps `contentOffset.y` upward under the user's finger or during status-bar transitions.
        let scrollFloorTop = min(expandedTop, max(0, -currentOffsetY))
        let effectiveTop = max(desiredTop, scrollFloorTop)
        let effectiveBottom = max(0, view.safeAreaInsets.bottom)

        let topChanged = abs(lastAppliedTopInset - effectiveTop) > 0.5
        let bottomChanged = abs(lastAppliedBottomInset - effectiveBottom) > 0.5
        if topChanged || bottomChanged {
            let previousTop = lastAppliedTopInset
            let wasRestingAtTop = (previousTop < 0 && abs(currentOffsetY) < 1.0)
                || (previousTop >= 0 && abs(currentOffsetY + previousTop) < 1.5 && p < 0.01)
            lastAppliedTopInset = effectiveTop
            lastAppliedBottomInset = effectiveBottom
            let insets = UIEdgeInsets(top: effectiveTop, left: 0, bottom: effectiveBottom, right: 0)
            scrollView.contentInset = insets
            scrollView.verticalScrollIndicatorInsets = insets
            if #available(iOS 26.0, *) {
                webView.obscuredContentInsets = insets
            }
            if wasRestingAtTop, !scrollView.isTracking, !scrollView.isDragging {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: -effectiveTop), animated: false)
            }
        }
    }

    private func bindExternalCollapseCallback() {
        collapseModel?.onExternalProgressChange = { [weak self] target in
            self?.applyExternalProgress(target)
        }
    }

    private func applyExternalProgress(_ target: CGFloat) {
        let clamped = allowScrollCollapse ? min(1, max(0, target)) : 0
        let currentOffsetY = hostedWebView?.scrollView.contentOffset.y ?? 0
        scrollState.syncExternal(progress: clamped, contentOffsetY: currentOffsetY)
        syncWebViewInsets()
        if clamped <= 0.01, let scrollView = hostedWebView?.scrollView, scrollView.contentOffset.y <= 2 {
            let topRest = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y > topRest + 1 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topRest), animated: true)
            }
        }
    }

    func syncExternalCollapseState() {
        guard !isUpdatingModelInternally, let model = collapseModel else { return }
        let target = allowScrollCollapse ? model.progress : 0
        guard abs(scrollState.progress - target) > 0.005 else { return }
        let currentOffsetY = hostedWebView?.scrollView.contentOffset.y ?? 0
        scrollState.syncExternal(progress: target, contentOffsetY: currentOffsetY)
        syncWebViewInsets()
    }

    func detachScrollObservers() {
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        hostedWebView?.scrollView.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollPanGesture(_:)))
        setContentScrollView(nil, for: [.top, .bottom])
    }

    func attach(_ webView: WKWebView?) {
        guard hostedWebView !== webView else { return }
        let previousWebView = hostedWebView
        detachScrollObservers()
        if let previousWebView {
            // Hide immediately, then defer `removeFromSuperview()` to the next RunLoop turn.
            // Calling `removeFromSuperview()` synchronously inside `updateUIViewController` while
            // the outgoing `WKWebView` holds first responder triggers `UIResponder.nextFirstResponder`
            // -> `_UIHostingView.canBecomeFirstResponder` -> SwiftUI `AttributeGraph` re-entrancy deadlock.
            previousWebView.isHidden = true
            previousWebView.isUserInteractionEnabled = false
            DispatchQueue.main.async { [weak self, weak previousWebView] in
                guard let self, let previousWebView,
                      previousWebView !== self.hostedWebView,
                      previousWebView.superview === self.view else { return }
                previousWebView.endEditing(true)
                previousWebView.removeFromSuperview()
            }
        }
        hostedWebView = webView
        lastAppliedMaxViewportTop = -1
        lastAppliedTopInset = -1
        lastAppliedBottomInset = -1
        scrollState.reset()
        guard let webView else {
            syncContentScrollViewOwnership()
            return
        }
        webView.isHidden = false
        webView.isUserInteractionEnabled = true
        // Manage scroll & obscured insets explicitly via `contentInset` + `WKWebView.obscuredContentInsets`
        // so `NavigationStack`'s phantom 24 pt inline bar inset never pins site sticky headers 24 pt below the top edge.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            webView.scrollView.topEdgeEffect.style = .soft
        }
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if webView.superview !== view {
            view.addSubview(webView)
        } else {
            view.bringSubviewToFront(webView)
        }
        // Register WebKit's scroll view with UIKit so `TabView.tabBarMinimizeBehavior(.onScrollDown)`
        // natively minimizes the Inner Portrait bottom tab bar alongside the top domain pill.
        syncContentScrollViewOwnership()
        syncViewportInsetBounds()
        syncWebViewInsets()

        // Passively observe `contentOffset` via KVO and pan end via `panGestureRecognizer.addTarget`
        // without ever replacing `WKWebView`'s own `UIScrollViewDelegate`.
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollPanGesture(_:)))
        contentOffsetObservation = webView.scrollView.observe(
            \.contentOffset,
            options: [.new]
        ) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                self?.handleScrollOffsetChange(scrollView)
            }
        }
    }

    @objc private func handleScrollPanGesture(_ pan: UIPanGestureRecognizer) {
        guard allowScrollCollapse,
              pan.state == .ended || pan.state == .cancelled,
              let scrollView = hostedWebView?.scrollView else {
            return
        }
        let velocityY = pan.velocity(in: scrollView).y
        let preferMinimize: Bool?
        if velocityY < -120 {
            preferMinimize = true
        } else if velocityY > 120 {
            preferMinimize = false
        } else {
            preferMinimize = nil
        }

        if scrollState.settleIfPartial(preferMinimize: preferMinimize) {
            syncWebViewInsets()
            emitProgress(scrollState.progress, animated: true)
        }
    }

    private func handleScrollOffsetChange(_ scrollView: UIScrollView) {
        guard allowScrollCollapse else { return }
        let isUserDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        let changed = scrollState.handleScroll(
            contentOffsetY: scrollView.contentOffset.y,
            topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom,
            contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height,
            isUserDriven: isUserDriven
        )
        if changed || (lastAppliedTopInset > 0.5 && scrollState.progress > 0.001) {
            syncWebViewInsets()
        }
        if changed {
            // Finger-tracked during drag (`animated: false`), spring-smoothed on programmatic scroll-to-top (`animated: true`).
            emitProgress(scrollState.progress, animated: !isUserDriven)
        }
    }

    private func emitProgress(_ nextProgress: CGFloat, animated: Bool) {
        guard let model = collapseModel else { return }
        guard abs(model.progress - nextProgress) > 0.001 else { return }
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self, let model else { return }
            self.isUpdatingModelInternally = true
            defer { self.isUpdatingModelInternally = false }
            model.updateFromScroll(nextProgress, animated: animated)
        }
    }
}

private struct NativeWebKitHost: UIViewControllerRepresentable {
    let webView: WKWebView?
    let desiredTopOverlayHeight: CGFloat
    let collapseModel: BrowserChromeCollapseModel
    let allowScrollCollapse: Bool
    let isScrollViewActive: Bool

    func makeUIViewController(context: Context) -> NativeWebKitHostController {
        let vc = NativeWebKitHostController()
        vc.view.backgroundColor = .clear
        vc.collapseModel = collapseModel
        vc.allowScrollCollapse = allowScrollCollapse
        vc.isScrollViewActive = isScrollViewActive
        vc.desiredTopOverlayHeight = desiredTopOverlayHeight
        vc.attach(webView)
        vc.syncExternalCollapseState()
        return vc
    }

    func updateUIViewController(_ uiViewController: NativeWebKitHostController, context: Context) {
        uiViewController.collapseModel = collapseModel
        uiViewController.allowScrollCollapse = allowScrollCollapse
        uiViewController.isScrollViewActive = isScrollViewActive
        uiViewController.desiredTopOverlayHeight = desiredTopOverlayHeight
        uiViewController.attach(webView)
        uiViewController.syncExternalCollapseState()
    }

    static func dismantleUIViewController(_ uiViewController: NativeWebKitHostController, coordinator: ()) {
        uiViewController.detachScrollObservers()
    }
}

// MARK: - Native Direct Stream Player (`AVPlayerViewController` + Authenticated Headers)

private struct CleanroomStreamPreviewItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let title: String
}

private struct CleanroomStreamPlayerContainer: UIViewControllerRepresentable {
    let item: CleanroomStreamPreviewItem

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let effectiveHeaders = HLSStreamEngine.normalizedBrowserHeaders(
            item.headers,
            manifestURL: item.url
        )
        let asset = AVURLAsset(
            url: item.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": effectiveHeaders]
        )
        let playerItem = AVPlayerItem(asset: asset)
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            let titleMetadata = AVMutableMetadataItem()
            titleMetadata.identifier = .commonIdentifierTitle
            titleMetadata.value = trimmedTitle as NSString
            titleMetadata.extendedLanguageTag = "und"
            playerItem.externalMetadata = [titleMetadata]
        }

        let player = AVPlayer(playerItem: playerItem)
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.player = player
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
        uiViewController.player = nil
    }
}

private struct OmniboxDropdownItem: Identifiable, Hashable {
    let id: String
    let title: String
    let urlString: String
    let isFavorite: Bool
}

private struct BrowserToastBanner: Identifiable, Equatable {
    enum ActionKind: Equatable {
        case jumpToTransfer(UUID)
        case openDownloads
    }

    let id = UUID()
    let icon: String
    let title: String
    let tint: Color
    let actionTitle: String?
    let action: ActionKind?
}

private struct BrowserSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct BrowserActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
