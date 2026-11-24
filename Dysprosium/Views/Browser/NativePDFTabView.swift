import PDFKit
import SwiftUI
import UIKit

/// Safe-area-respecting floating chrome overlay for native `PDFKit` tabs inside `CleanroomBrowserWorkspaceView`:
/// - The edge-to-edge `NativePDFHost` (`UIViewControllerRepresentable`) mounts directly in `CleanroomBrowserWorkspaceView`'s
///   `Z = 0` viewport slot (mutually exclusive with `NativeWebKitHost`) with `.ignoresSafeArea(edges: [.top, .bottom])`
///   so `PDFView`'s internal `UIScrollView` extends seamlessly beneath the bottom `UITabBar` and owns
///   `setContentScrollView(_:for:)` without competing with a hidden `WKWebView` sibling.
/// - Renders floating Liquid Glass controls exclusively on the overlay chrome layer (never on content cards).
struct NativePDFChromeOverlay: View {
    @Environment(\.dysprosiumTokens) private var tokens

    let pdfDoc: PDFTabDocument
    let metrics: DuoViewportMetrics
    let topChromeLayout: BrowserTopChromeLayout
    let desiredTopOverlayHeight: CGFloat
    let collapseModel: BrowserChromeCollapseModel
    let allowScrollCollapse: Bool
    @Binding var appearanceMode: PDFAppearanceMode
    @Binding var displayLayoutMode: PDFDisplayLayoutMode
    let onSaveToVault: () -> Void
    let onRevealInVault: () -> Void
    let onShareOriginalPDF: () -> Void

    @State private var isShowingNavigatorSheet: Bool = false
    @State private var unlockPassword: String = ""
    @State private var unlockFailed: Bool = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if pdfDoc.isLocked {
                Color(uiColor: appearanceMode.canvasUIColor)
                    .ignoresSafeArea(.all)

                encryptedDocumentUnlockView
                    .padding(.top, desiredTopOverlayHeight)
            } else {
                // Floating in-document search bar anchored cleanly below the expanded top omnibox
                if pdfDoc.isSearchVisible {
                    VStack(spacing: 0) {
                        pdfSearchBar
                            .frame(maxWidth: topChromeLayout.maxWidth ?? .infinity)
                            .padding(.top, topChromeLayout.top + 42)
                            .padding(.leading, topChromeLayout.leading)
                            .padding(.trailing, topChromeLayout.trailing)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                // Floating Liquid Glass bottom reader pill (hides smoothly during scroll-down reading)
                PDFReaderFloatingPillOverlay(
                    pdfDoc: pdfDoc,
                    metrics: metrics,
                    collapseModel: collapseModel,
                    allowScrollCollapse: allowScrollCollapse && !pdfDoc.isSearchVisible,
                    showLayoutToggle: metrics.supportsSideBySideColumns && pdfDoc.pageCount > 1,
                    appearanceMode: $appearanceMode,
                    displayLayoutMode: $displayLayoutMode,
                    onOpenNavigator: {
                        isShowingNavigatorSheet = true
                    },
                    onToggleSearch: {
                        withAnimation(.snappy(duration: 0.2)) {
                            if pdfDoc.isSearchVisible {
                                pdfDoc.dismissSearch()
                                isSearchFieldFocused = false
                            } else {
                                chromeExpand()
                                pdfDoc.isSearchVisible = true
                                isSearchFieldFocused = true
                            }
                        }
                    },
                    onSaveOrReveal: {
                        if pdfDoc.isSavedInVault {
                            onRevealInVault()
                        } else {
                            onSaveToVault()
                        }
                    },
                    onShareOriginalPDF: onShareOriginalPDF
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: pdfDoc.isSearchVisible) { _, visible in
            if visible {
                chromeExpand()
                isSearchFieldFocused = true
            } else {
                isSearchFieldFocused = false
            }
        }
        .sheet(isPresented: $isShowingNavigatorSheet) {
            PDFNavigatorSheet(
                pdfDoc: pdfDoc,
                appearanceMode: appearanceMode
            )
        }
    }

    private func chromeExpand() {
        if collapseModel.progress > 0 {
            collapseModel.setExternalProgress(0, animated: true)
        }
    }

    // MARK: - Encrypted PDF Unlock Card (Semantic Surface, Zero Glass-on-Content)

    private var encryptedDocumentUnlockView: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tokens.accent.opacity(0.14))
                        .frame(width: 54, height: 54)
                    Image(systemName: "lock.doc.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tokens.accent)
                }

                VStack(spacing: 4) {
                    Text(L("Password Protected PDF"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(pdfDoc.suggestedFilename)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }

                SecureField(L("Document Password"), text: $unlockPassword)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit(attemptUnlock)
                    .accessibilityIdentifier("pdf-unlock-password-field")

                if unlockFailed {
                    Text(L("Incorrect password. Please try again."))
                        .font(.caption)
                        .foregroundStyle(tokens.statusDanger)
                }

                Button(action: attemptUnlock) {
                    Text(L("Unlock Document"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(tokens.accent)
                .disabled(unlockPassword.isEmpty)
                .accessibilityIdentifier("pdf-unlock-submit-button")
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attemptUnlock() {
        if pdfDoc.unlock(password: unlockPassword) {
            unlockPassword = ""
            unlockFailed = false
        } else {
            unlockFailed = true
        }
    }

    // MARK: - Floating Liquid Glass In-PDF Search Bar

    private var pdfSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.monochrome)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tokens.glassIconSecondary)

            TextField(
                L("Find in PDF…"),
                text: Binding(
                    get: { pdfDoc.searchQuery },
                    set: { pdfDoc.updateSearchQuery($0) }
                )
            )
            .focused($isSearchFieldFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .font(.subheadline)
            .onSubmit {
                pdfDoc.stepSearchResult(delta: 1)
            }
            .accessibilityIdentifier("pdf-search-field")

            if pdfDoc.isSearching {
                ProgressView()
                    .controlSize(.mini)
            } else if !pdfDoc.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(
                    pdfDoc.searchResults.isEmpty
                        ? "0 / 0"
                        : "\(pdfDoc.activeSearchResultIndex + 1) / \(pdfDoc.searchResults.count)"
                )
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pdf-search-count")
            }

            HStack(spacing: 2) {
                Button {
                    pdfDoc.stepSearchResult(delta: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .symbolRenderingMode(.monochrome)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pdfDoc.searchResults.isEmpty)
                .accessibilityLabel(L("Previous Match"))

                Button {
                    pdfDoc.stepSearchResult(delta: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .symbolRenderingMode(.monochrome)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pdfDoc.searchResults.isEmpty)
                .accessibilityLabel(L("Next Match"))
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    pdfDoc.dismissSearch()
                    isSearchFieldFocused = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.subheadline)
                    .foregroundStyle(tokens.glassIconSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close PDF Search"))
            .accessibilityIdentifier("pdf-search-close-button")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

// MARK: - Isolated 120 Hz Floating Bottom Liquid Glass Reader Pill

private struct PDFReaderFloatingPillOverlay: View {
    @Environment(\.dysprosiumTokens) private var tokens

    let pdfDoc: PDFTabDocument
    let metrics: DuoViewportMetrics
    let collapseModel: BrowserChromeCollapseModel
    let allowScrollCollapse: Bool
    let showLayoutToggle: Bool
    @Binding var appearanceMode: PDFAppearanceMode
    @Binding var displayLayoutMode: PDFDisplayLayoutMode
    let onOpenNavigator: () -> Void
    let onToggleSearch: () -> Void
    let onSaveOrReveal: () -> Void
    let onShareOriginalPDF: () -> Void

    var body: some View {
        let p: CGFloat = allowScrollCollapse ? min(1, max(0, collapseModel.progress)) : 0
        let opacity = max(0, 1 - p * 1.45)
        let yOffset = 28 * p
        let bookHalf = metrics.bookPoseTrailingHalfFrame(horizontalPadding: 16)

        Group {
            if let bookHalf {
                // Book Pose: dock cleanly inside the trailing half so the capsule never straddles `.division`.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(width: bookHalf.leading)
                    readerCapsule
                        .frame(maxWidth: bookHalf.maxWidth)
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            } else {
                readerCapsule
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
        .opacity(opacity)
        .offset(y: yOffset)
        .allowsHitTesting(opacity > 0.2)
        .accessibilityHidden(opacity <= 0.2)
    }

    private var readerCapsule: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 2) {
                // 1. Page indicator -> opens Pages Thumbnail Grid & Outline Navigator
                Button(action: onOpenNavigator) {
                    HStack(spacing: 5) {
                        Image(systemName: pdfDoc.outlineNodes.isEmpty ? "square.grid.2x2" : "list.bullet.indent")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tokens.glassIconSecondary)

                        Text("\(min(pdfDoc.currentPageIndex + 1, max(1, pdfDoc.pageCount))) / \(max(1, pdfDoc.pageCount))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tokens.glassIconPrimary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Pages and Contents, page \(pdfDoc.currentPageIndex + 1) of \(pdfDoc.pageCount)"))
                .accessibilityIdentifier("pdf-navigator-button")

                pillDivider

                // 2. Find in PDF
                Button(action: onToggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(pdfDoc.isSearchVisible ? tokens.accent : tokens.glassIconPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Find in PDF"))
                .accessibilityIdentifier("pdf-find-button")

                // 3. Appearance Mode (Original / Paper / Dark)
                Menu {
                    Picker(L("Reading Appearance"), selection: $appearanceMode) {
                        ForEach(PDFAppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: appearanceMode.systemImage)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(tokens.glassIconPrimary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("PDF Appearance, \(appearanceMode.title)"))
                .accessibilityIdentifier("pdf-appearance-button")

                // 4. Layout Mode on wide / iPhone Duo inner screens (Auto Duo / Single / Two-Up)
                if showLayoutToggle {
                    Menu {
                        Picker(L("Page Layout"), selection: $displayLayoutMode) {
                            ForEach(PDFDisplayLayoutMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: displayLayoutMode.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(tokens.glassIconPrimary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("PDF Page Layout, \(displayLayoutMode.title)"))
                    .accessibilityIdentifier("pdf-layout-button")
                }

                pillDivider

                // 5. One-tap Save Original PDF to Vault (or Reveal if already saved), with Share secondary menu
                Menu {
                    if pdfDoc.isSavedInVault {
                        Button(action: onSaveOrReveal) {
                            Label(L("View in Downloads"), systemImage: "folder")
                        }
                    } else {
                        Button(action: onSaveOrReveal) {
                            Label(L("Save to Downloads (\(pdfDoc.formattedFileSize))"), systemImage: "arrow.down.to.line")
                        }
                    }

                    Button(action: onShareOriginalPDF) {
                        Label(L("Share / Save to Files…"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: pdfDoc.isSavedInVault ? "checkmark.circle.fill" : "arrow.down.to.line")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(pdfDoc.isSavedInVault ? tokens.statusSuccess : tokens.glassIconPrimary)
                        .frame(width: 38, height: 36)
                        .contentShape(Rectangle())
                } primaryAction: {
                    onSaveOrReveal()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pdfDoc.isSavedInVault ? L("Saved in Downloads") : L("Save PDF to Downloads"))
                .accessibilityIdentifier("pdf-save-button")
            }
            .padding(.horizontal, 4)
            .frame(height: 40)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 18)
    }
}

// MARK: - 100% Native UIKit `PDFView` Host (Safe Area + Continuous Scroll Compaction + Duo Spread)

final class NativePDFHostController: UIViewController, PDFViewDelegate {
    private let pdfView = PDFView()
    private var attachedPDFDocID: UUID?
    private weak var observedScrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var pageChangedObserver: NSObjectProtocol?
    private var scrollState = BrowserChromeScrollState()
    private var isUpdatingModelInternally = false
    private var lastAppliedAppearance: PDFAppearanceMode = .original
    private var lastAppliedLayout: PDFDuoLayoutConfiguration?
    private var lastCommandSequence: Int = 0
    private var lastHighlightedSelectionCount: Int = 0
    private var didInitialAutoScale: Bool = false

    weak var pdfDoc: PDFTabDocument?
    weak var collapseModel: BrowserChromeCollapseModel? {
        didSet {
            bindExternalCollapseCallback()
        }
    }
    var allowScrollCollapse: Bool = true {
        didSet {
            if oldValue != allowScrollCollapse {
                syncTopSafeAreaInset()
            }
        }
    }
    var onOpenExternalLink: ((URL) -> Void)?

    var desiredTopOverlayHeight: CGFloat = 0 {
        didSet {
            if abs(oldValue - desiredTopOverlayHeight) > 0.5 {
                syncTopSafeAreaInset()
            }
        }
    }

    deinit {
        detachObservers()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.usePageViewController(false)
        pdfView.delegate = self
        view.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        pageChangedObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncCurrentPageIndex()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachScrollViewIfNeeded()
        if let scrollView = observedScrollView {
            // Re-assert bottom scroll view ownership after VC mount so `UITabBarController`
            // binds `.tabBarMinimizeBehavior(.onScrollDown)` directly to `PDFView`'s scroll view.
            setContentScrollView(scrollView, for: [.top, .bottom])
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachScrollViewIfNeeded()
        if !didInitialAutoScale, pdfView.document != nil, pdfView.bounds.width > 40 {
            didInitialAutoScale = true
            pdfView.autoScales = true
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncTopSafeAreaInset()
    }

    func syncTopSafeAreaInset() {
        let p = allowScrollCollapse ? scrollState.progress : 0
        let desiredTop = desiredTopOverlayHeight * (1 - p)
        let currentOffsetY = observedScrollView?.contentOffset.y ?? 0
        let scrollFloorTop = min(desiredTopOverlayHeight, max(0, -currentOffsetY))
        let effectiveTop = max(desiredTop, scrollFloorTop)
        let systemTop = max(0, view.safeAreaInsets.top - additionalSafeAreaInsets.top)
        let neededAdditionalTop = max(0, effectiveTop - systemTop)
        if abs(additionalSafeAreaInsets.top - neededAdditionalTop) > 0.5 {
            additionalSafeAreaInsets = UIEdgeInsets(top: neededAdditionalTop, left: 0, bottom: 0, right: 0)
        }
    }

    private func bindExternalCollapseCallback() {
        collapseModel?.onExternalProgressChange = { [weak self] target in
            self?.applyExternalProgress(target)
        }
    }

    private func applyExternalProgress(_ target: CGFloat) {
        let clamped = allowScrollCollapse ? min(1, max(0, target)) : 0
        let currentOffsetY = observedScrollView?.contentOffset.y ?? 0
        scrollState.syncExternal(progress: clamped, contentOffsetY: currentOffsetY)
        syncTopSafeAreaInset()
        // If expanding back to full omnibox while resting right at document top (`y <= 2`),
        // settle the scroll offset cleanly below the newly expanded bar.
        if clamped <= 0.01, let scrollView = observedScrollView, scrollView.contentOffset.y <= 2 {
            view.layoutIfNeeded()
            let topRest = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y > topRest + 1 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topRest), animated: true)
            }
        }
    }

    func apply(
        pdfDoc: PDFTabDocument,
        appearanceMode: PDFAppearanceMode,
        layoutConfig: PDFDuoLayoutConfiguration
    ) {
        self.pdfDoc = pdfDoc
        let isNewDocument = (attachedPDFDocID != pdfDoc.id)
        let appearanceChanged = (lastAppliedAppearance != appearanceMode)
        let layoutChanged = (lastAppliedLayout != layoutConfig)

        pdfView.backgroundColor = appearanceMode.canvasUIColor

        if isNewDocument {
            attachedPDFDocID = pdfDoc.id
            lastAppliedAppearance = appearanceMode
            lastAppliedLayout = layoutConfig
            lastCommandSequence = pdfDoc.commandSequence
            didInitialAutoScale = false
            scrollState.reset()

            pdfDoc.document.appearanceMode = appearanceMode
            applyLayoutConfig(layoutConfig)
            pdfView.document = pdfDoc.document
            pdfView.autoScales = true
            if pdfDoc.currentPageIndex > 0,
               let targetPage = pdfDoc.document.page(at: pdfDoc.currentPageIndex) {
                pdfView.go(to: targetPage)
            }
            attachScrollViewIfNeeded()
            syncTopSafeAreaInset()
            syncCurrentPageIndex()
        } else {
            if layoutChanged {
                lastAppliedLayout = layoutConfig
                let anchorPage = pdfView.currentPage
                applyLayoutConfig(layoutConfig)
                pdfView.autoScales = true
                if pdfView.bounds.width > 40 {
                    pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
                }
                if let anchorPage {
                    pdfView.go(to: anchorPage)
                }
            }

            if appearanceChanged {
                lastAppliedAppearance = appearanceMode
                reloadTilesPreservingViewport(for: pdfDoc, appearanceMode: appearanceMode)
            }
        }

        // Sync live search highlights
        let matchCount = pdfDoc.searchResults.count
        if matchCount != lastHighlightedSelectionCount || (matchCount == 0 && pdfView.highlightedSelections != nil) {
            lastHighlightedSelectionCount = matchCount
            if matchCount == 0 {
                pdfView.highlightedSelections = nil
                pdfView.clearSelection()
            } else {
                pdfView.highlightedSelections = pdfDoc.searchResults
            }
        }

        // Consume one-shot navigation / zoom / search-jump commands
        if pdfDoc.commandSequence != lastCommandSequence {
            lastCommandSequence = pdfDoc.commandSequence
            if let cmd = pdfDoc.pendingCommand {
                executeCommand(cmd, on: pdfDoc)
            }
        }
    }

    private func applyLayoutConfig(_ config: PDFDuoLayoutConfiguration) {
        pdfView.displayMode = config.displayMode
        pdfView.displaysAsBook = config.displaysAsBook
        pdfView.pageBreakMargins = config.pageBreakMargins
    }

    private func reloadTilesPreservingViewport(for pdfDoc: PDFTabDocument, appearanceMode: PDFAppearanceMode) {
        let savedDestination = pdfView.currentDestination
        let savedAutoScales = pdfView.autoScales
        let savedScale = pdfView.scaleFactor
        let savedOffset = observedScrollView?.contentOffset

        pdfDoc.document.appearanceMode = appearanceMode
        // Re-binding document flushes CATiledLayer cached tiles synchronously so new CoreGraphics
        // blend/theme passes paint immediately without stale white/dark tile flashes.
        pdfView.document = nil
        pdfView.document = pdfDoc.document
        attachScrollViewIfNeeded()

        pdfView.autoScales = savedAutoScales
        if !savedAutoScales {
            pdfView.scaleFactor = savedScale
        }
        if let savedDestination {
            pdfView.go(to: savedDestination)
        }
        if let savedOffset, let scrollView = observedScrollView {
            let maxOffsetY = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let clampedY = min(maxOffsetY, max(-scrollView.adjustedContentInset.top, savedOffset.y))
            scrollView.setContentOffset(CGPoint(x: savedOffset.x, y: clampedY), animated: false)
        }
    }

    private func executeCommand(_ command: PDFNavigationCommand, on pdfDoc: PDFTabDocument) {
        switch command {
        case .goToPage(let index):
            guard let page = pdfDoc.document.page(at: index) else { return }
            let bounds = page.bounds(for: .cropBox)
            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
            // Clear the active top bar height so jumped-to page headers stay fully visible.
            if let scrollView = observedScrollView, scrollView.adjustedContentInset.top > 0 {
                let minY = -scrollView.adjustedContentInset.top
                let adjustedY = max(minY, scrollView.contentOffset.y - scrollView.adjustedContentInset.top)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: adjustedY), animated: false)
            }
            syncCurrentPageIndex()

        case .highlightSelection(let index):
            guard pdfDoc.searchResults.indices.contains(index) else { return }
            let selection = pdfDoc.searchResults[index]
            pdfView.highlightedSelections = pdfDoc.searchResults
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
            syncCurrentPageIndex()

        case .zoomIn:
            pdfView.autoScales = false
            pdfView.zoomIn(nil)

        case .zoomOut:
            pdfView.autoScales = false
            pdfView.zoomOut(nil)

        case .resetZoom:
            pdfView.autoScales = true
            if pdfView.bounds.width > 40 {
                pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
            }
        }
    }

    func syncExternalCollapseState() {
        guard !isUpdatingModelInternally, let model = collapseModel else { return }
        let target = allowScrollCollapse ? model.progress : 0
        guard abs(scrollState.progress - target) > 0.005 else { return }
        let currentOffsetY = observedScrollView?.contentOffset.y ?? 0
        scrollState.syncExternal(progress: target, contentOffsetY: currentOffsetY)
        syncTopSafeAreaInset()
    }

    func detachObservers() {
        contentOffsetObservation?.invalidate()
        contentOffsetObservation = nil
        observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollPanGesture(_:)))
        observedScrollView = nil
        setContentScrollView(nil, for: [.top, .bottom])
        if let pageChangedObserver {
            NotificationCenter.default.removeObserver(pageChangedObserver)
            self.pageChangedObserver = nil
        }
    }

    private func findEmbeddedScrollView(in root: UIView, depth: Int = 0) -> UIScrollView? {
        if let sv = root as? UIScrollView { return sv }
        guard depth < 4 else { return nil }
        for child in root.subviews {
            if let found = findEmbeddedScrollView(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func attachScrollViewIfNeeded() {
        guard let scrollView = findEmbeddedScrollView(in: pdfView),
              scrollView !== observedScrollView else {
            return
        }
        contentOffsetObservation?.invalidate()
        observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollPanGesture(_:)))

        observedScrollView = scrollView
        scrollView.contentInsetAdjustmentBehavior = .automatic
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.style = .soft
        }
        setContentScrollView(scrollView, for: [.top, .bottom])
        syncTopSafeAreaInset()

        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollPanGesture(_:)))
        contentOffsetObservation = scrollView.observe(
            \.contentOffset,
            options: [.new]
        ) { [weak self] sv, _ in
            MainActor.assumeIsolated {
                self?.handleScrollOffsetChange(sv)
            }
        }
    }

    private func syncCurrentPageIndex() {
        guard let pdfDoc,
              let page = pdfView.currentPage else { return }
        let idx = pdfDoc.document.index(for: page)
        if idx != NSNotFound, idx >= 0, pdfDoc.currentPageIndex != idx {
            pdfDoc.currentPageIndex = idx
        }
    }

    @objc private func handleScrollPanGesture(_ pan: UIPanGestureRecognizer) {
        guard allowScrollCollapse,
              pan.state == .ended || pan.state == .cancelled,
              let scrollView = observedScrollView else {
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
            syncTopSafeAreaInset()
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
        if changed || (additionalSafeAreaInsets.top > 0.5 && scrollState.progress > 0.001) {
            syncTopSafeAreaInset()
        }
        if changed {
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

    // MARK: - `PDFViewDelegate`

    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        MainActor.assumeIsolated {
            onOpenExternalLink?(url)
        }
    }
}

struct NativePDFHost: UIViewControllerRepresentable {
    let pdfDoc: PDFTabDocument
    let appearanceMode: PDFAppearanceMode
    let layoutConfig: PDFDuoLayoutConfiguration
    let desiredTopOverlayHeight: CGFloat
    let collapseModel: BrowserChromeCollapseModel
    let allowScrollCollapse: Bool
    let onOpenExternalLink: (URL) -> Void

    func makeUIViewController(context: Context) -> NativePDFHostController {
        let vc = NativePDFHostController()
        vc.collapseModel = collapseModel
        vc.allowScrollCollapse = allowScrollCollapse
        vc.desiredTopOverlayHeight = desiredTopOverlayHeight
        vc.onOpenExternalLink = onOpenExternalLink
        vc.apply(pdfDoc: pdfDoc, appearanceMode: appearanceMode, layoutConfig: layoutConfig)
        vc.syncExternalCollapseState()
        return vc
    }

    func updateUIViewController(_ uiViewController: NativePDFHostController, context: Context) {
        uiViewController.collapseModel = collapseModel
        uiViewController.allowScrollCollapse = allowScrollCollapse
        uiViewController.desiredTopOverlayHeight = desiredTopOverlayHeight
        uiViewController.onOpenExternalLink = onOpenExternalLink
        uiViewController.apply(pdfDoc: pdfDoc, appearanceMode: appearanceMode, layoutConfig: layoutConfig)
        uiViewController.syncExternalCollapseState()
    }

    static func dismantleUIViewController(_ uiViewController: NativePDFHostController, coordinator: ()) {
        uiViewController.detachObservers()
    }
}

// MARK: - Document Navigator Sheet (Even-Column Duo Page Thumbnails + Table of Contents Outline)

private struct PDFNavigatorSheet: View {
    private enum NavigatorTab: String, CaseIterable, Identifiable {
        case pages
        case outline

        var id: String { rawValue }
    }

    @Environment(\.dysprosiumTokens) private var tokens
    @Environment(\.dismiss) private var dismiss

    let pdfDoc: PDFTabDocument
    let appearanceMode: PDFAppearanceMode

    @State private var selectedTab: NavigatorTab = .pages
    @State private var gridWidth: CGFloat = 460
    @State private var thumbnailCache = PDFPageThumbnailCache()

    private var columnCount: Int {
        // Strict iPhone Duo even-column rule (`2` or `4`) so thumbnails divide cleanly across `.division`.
        gridWidth >= 520 ? 4 : 2
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedTab == .outline {
                    outlineListView
                } else {
                    thumbnailsGridView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { width in
                gridWidth = width
            }
            .navigationTitle(pdfDoc.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !pdfDoc.outlineNodes.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker(L("Navigator Section"), selection: $selectedTab) {
                            Text(L("Pages")).tag(NavigatorTab.pages)
                            Text(L("Contents")).tag(NavigatorTab.outline)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 210)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }

    private var thumbnailsGridView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(0..<pdfDoc.pageCount, id: \.self) { index in
                        PDFPageThumbnailCell(
                            document: pdfDoc.document,
                            pageIndex: index,
                            isCurrent: index == pdfDoc.currentPageIndex,
                            appearanceMode: appearanceMode,
                            cache: thumbnailCache,
                            accentColor: tokens.accent,
                            onSelect: {
                                pdfDoc.jumpToPage(index)
                                dismiss()
                            }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onAppear {
                proxy.scrollTo(pdfDoc.currentPageIndex, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private var outlineListView: some View {
        if pdfDoc.outlineNodes.isEmpty {
            ContentUnavailableView(
                L("No Table of Contents"),
                systemImage: "list.bullet.indent",
                description: Text(L("This PDF document does not include an embedded outline."))
            )
        } else {
            List {
                ForEach(pdfDoc.outlineNodes) { node in
                    Button {
                        pdfDoc.jumpToPage(node.pageIndex)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Text(node.title)
                                .font(node.depth == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .padding(.leading, CGFloat(min(node.depth, 4)) * 14)

                            Spacer(minLength: 8)

                            Text("\(node.pageIndex + 1)")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

private final class PDFPageThumbnailCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        return c
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

private struct PDFPageThumbnailCell: View {
    let document: ThemedPDFDocument
    let pageIndex: Int
    let isCurrent: Bool
    let appearanceMode: PDFAppearanceMode
    let cache: PDFPageThumbnailCache
    let accentColor: Color
    let onSelect: () -> Void

    @State private var renderedImage: UIImage?

    var body: some View {
        let cacheKey = "\(appearanceMode.rawValue)-\(pageIndex)"
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: appearanceMode.canvasUIColor))

                    if let renderedImage {
                        Image(uiImage: renderedImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(4)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .aspectRatio(0.75, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isCurrent ? accentColor : Color.primary.opacity(0.10),
                            lineWidth: isCurrent ? 2.5 : 0.75
                        )
                )

                Text("\(pageIndex + 1)")
                    .font(.caption.weight(isCurrent ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isCurrent ? accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: cacheKey) {
            if let cached = cache.image(for: cacheKey) {
                renderedImage = cached
                return
            }
            let docBox = PDFTransferBox(document)
            let idx = pageIndex
            let img = await Task.detached(priority: .utility) { () -> UIImage? in
                docBox.value.renderThemedThumbnail(pageIndex: idx, maxDimension: 280)
            }.value
            guard !Task.isCancelled, let img else { return }
            cache.store(img, for: cacheKey)
            renderedImage = img
        }
    }
}
