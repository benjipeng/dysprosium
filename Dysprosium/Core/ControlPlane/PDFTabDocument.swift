import Foundation
import Observation
import PDFKit
import UIKit

/// Lightweight unchecked Sendable transfer box for read-only PDFKit objects moved between
/// off-main parsing/search workers and `@MainActor` presentation.
public struct PDFTransferBox<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) {
        self.value = value
    }
}

/// Visual reading theme for Dysprosium's native `PDFKit` tab reader.
/// - `original`: True PDF inks over a calm semantic workbench backdrop.
/// - `paper`: Warm archival sepia multiply pass harmonized with Dysprosium's Paper preset (`#F1E6CE`).
/// - `dark`: Single-pass tile-clipped luminance inversion + hue restoration so body text softens to
///   comfortable off-white on Obsidian while colored links, charts, and highlights retain true hues.
public enum PDFAppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case original
    case paper
    case dark

    public var id: String { rawValue }

    public static let defaultsKey = "dysprosium.pdf.appearanceMode"

    public static var persistedCurrent: PDFAppearanceMode {
        let raw = CleanroomBrowserStore.readSharedString(forKey: defaultsKey) ?? ""
        return PDFAppearanceMode(rawValue: raw) ?? .original
    }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .paper: return "Paper"
        case .dark: return "Dark"
        }
    }

    public var systemImage: String {
        switch self {
        case .original: return "sun.max"
        case .paper: return "doc.plaintext"
        case .dark: return "moon.fill"
        }
    }

    /// Backdrop color behind PDF pages (`PDFView.backgroundColor` and workspace root surface).
    public var canvasUIColor: UIColor {
        switch self {
        case .original:
            return UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.085, green: 0.088, blue: 0.098, alpha: 1.0)
                    : UIColor(red: 0.910, green: 0.918, blue: 0.933, alpha: 1.0)
            }
        case .paper:
            return UIColor(red: 0.835, green: 0.784, blue: 0.675, alpha: 1.0)
        case .dark:
            return UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1.0)
        }
    }
}

/// Page spread preference for Dysprosium's native `PDFKit` reader.
public enum PDFDisplayLayoutMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case singlePage
    case twoUp

    public var id: String { rawValue }

    public static let defaultsKey = "dysprosium.pdf.displayLayoutMode"

    public static var persistedCurrent: PDFDisplayLayoutMode {
        let raw = CleanroomBrowserStore.readSharedString(forKey: defaultsKey) ?? ""
        return PDFDisplayLayoutMode(rawValue: raw) ?? .auto
    }

    public var title: String {
        switch self {
        case .auto: return "Auto (Duo)"
        case .singlePage: return "Single Page"
        case .twoUp: return "Two-Page Spread"
        }
    }

    public var shortTitle: String {
        switch self {
        case .auto: return "Auto"
        case .singlePage: return "Single"
        case .twoUp: return "Two-Up"
        }
    }

    public var systemImage: String {
        switch self {
        case .auto: return "rectangle.split.2x1"
        case .singlePage: return "doc"
        case .twoUp: return "book.pages"
        }
    }
}

/// Pure, deterministic iPhone Duo posture layout resolver for `PDFView`.
/// Automatically uses Two-Up Book Spread on Inner Landscape (`951×669`) and Book Pose while
/// opening a center page-break gutter wide enough to clear the `40 pt` `.division` fold crease.
public struct PDFDuoLayoutConfiguration: Equatable, Sendable {
    public let displayMode: PDFDisplayMode
    public let displaysAsBook: Bool
    public let pageBreakMargins: UIEdgeInsets

    public var isTwoUp: Bool {
        displayMode == .twoUpContinuous || displayMode == .twoUp
    }

    public static func resolve(
        viewportSize: CGSize,
        verticalHingeRect: CGRect?,
        preference: PDFDisplayLayoutMode,
        pageCount: Int
    ) -> PDFDuoLayoutConfiguration {
        let canSpread = pageCount > 1 && viewportSize.width >= 600
        let shouldUseTwoUp: Bool
        switch preference {
        case .singlePage:
            shouldUseTwoUp = false
        case .twoUp:
            shouldUseTwoUp = pageCount > 1
        case .auto:
            // Inner Landscape (`951×669`, safe width ~867 pt) or Book Pose with active vertical hinge -> Two-Up Book Spread.
            // Outer Portrait (`466×678`), Inner Portrait (`669×951`), and 50/50 Split View -> crisp Single-Page Continuous.
            let isLandscapeInner = viewportSize.width >= 740 && viewportSize.width > viewportSize.height
            let hasVerticalBookHinge = verticalHingeRect != nil && viewportSize.width >= 620
            shouldUseTwoUp = canSpread && (isLandscapeInner || hasVerticalBookHinge)
        }

        if shouldUseTwoUp {
            // In two-up mode, PDFView places `left + right` margin between facing pages.
            // When Book Pose exposes a 40 pt `.division` crease, widen horizontal break margins so
            // left and right pages rest cleanly on opposite halves of the fold.
            let horizontalBreak: CGFloat
            if let hinge = verticalHingeRect, hinge.width > 0 {
                horizontalBreak = max(24, ceil(hinge.width * 0.5) + 6)
            } else {
                horizontalBreak = 10
            }
            return PDFDuoLayoutConfiguration(
                displayMode: .twoUpContinuous,
                displaysAsBook: true,
                pageBreakMargins: UIEdgeInsets(top: 12, left: horizontalBreak, bottom: 12, right: horizontalBreak)
            )
        }

        return PDFDuoLayoutConfiguration(
            displayMode: .singlePageContinuous,
            displaysAsBook: false,
            pageBreakMargins: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        )
    }
}

/// Flattened, cycle-safe outline node for the PDF Document Navigator sheet.
public struct PDFOutlineNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let pageIndex: Int
    public let depth: Int

    public init(id: String, title: String, pageIndex: Int, depth: Int) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.depth = depth
    }
}

// MARK: - Custom CoreGraphics Themed `PDFDocument` / `PDFPage`

/// `PDFDocument` subclass that vends `ThemedPDFPage` instances reading `appearanceMode` atomically
/// from `CATiledLayer` background render threads.
public final class ThemedPDFDocument: PDFDocument {
    private let modeLock = NSLock()
    private var _appearanceMode: PDFAppearanceMode = .original

    public var appearanceMode: PDFAppearanceMode {
        get {
            modeLock.lock()
            defer { modeLock.unlock() }
            return _appearanceMode
        }
        set {
            modeLock.lock()
            _appearanceMode = newValue
            modeLock.unlock()
        }
    }

    public override var pageClass: AnyClass {
        ThemedPDFPage.self
    }

    /// Renders a theme-aware page thumbnail through `ThemedPDFPage.draw(with:to:)` so Navigator grids
    /// and Tab Switcher cards match `Original`, `Paper`, and `Dark` modes accurately.
    public func renderThemedThumbnail(pageIndex: Int, maxDimension: CGFloat = 340) -> UIImage? {
        guard !isLocked, let page = page(at: pageIndex) else { return nil }
        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 1, pageBounds.height > 1 else { return nil }
        let scale = maxDimension / max(pageBounds.width, pageBounds.height)
        let targetSize = CGSize(
            width: max(32, floor(pageBounds.width * scale)),
            height: max(32, floor(pageBounds.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { rendererCtx in
            let cg = rendererCtx.cgContext
            cg.setFillColor(appearanceMode.canvasUIColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: targetSize))
            // Flip UIKit top-down context to CoreGraphics PDF bottom-up page space.
            cg.translateBy(x: 0, y: targetSize.height)
            cg.scaleBy(x: targetSize.width / pageBounds.width, y: -(targetSize.height / pageBounds.height))
            cg.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            page.draw(with: .cropBox, to: cg)
        }
    }

    /// Extracts a cycle-safe, depth-bounded outline list for fast SwiftUI List presentation.
    public func extractOutlineNodes(maxDepth: Int = 5, maxEntries: Int = 600) -> [PDFOutlineNode] {
        guard let root = outlineRoot else { return [] }
        var output: [PDFOutlineNode] = []
        var visited = Set<ObjectIdentifier>()

        func walk(_ node: PDFOutline, depth: Int, pathPrefix: String) {
            guard output.count < maxEntries, depth <= maxDepth else { return }
            let oid = ObjectIdentifier(node)
            guard visited.insert(oid).inserted else { return }

            for idx in 0..<node.numberOfChildren {
                guard output.count < maxEntries, let child = node.child(at: idx) else { break }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedPage: PDFPage? = {
                    if let destPage = child.destination?.page { return destPage }
                    if let goTo = child.action as? PDFActionGoTo { return goTo.destination.page }
                    return nil
                }()
                let nodePath = "\(pathPrefix).\(idx)"
                if !label.isEmpty, let page = resolvedPage {
                    let pageIdx = index(for: page)
                    if pageIdx != NSNotFound && pageIdx >= 0 {
                        output.append(
                            PDFOutlineNode(
                                id: nodePath,
                                title: label,
                                pageIndex: pageIdx,
                                depth: depth
                            )
                        )
                    }
                }
                if child.numberOfChildren > 0 {
                    walk(child, depth: depth + 1, pathPrefix: nodePath)
                }
            }
        }

        walk(root, depth: 0, pathPrefix: "r")
        return output
    }
}

/// CoreGraphics-themed `PDFPage` preserving 100% vector Retina sharpness, native `PDFView` text selection,
/// and hue fidelity across `Original`, `Paper`, and `Dark` modes with zero private APIs.
public final class ThemedPDFPage: PDFPage {
    private static let paperTintColor = CGColor(
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        components: [0.945, 0.902, 0.808, 1.0]
    )!
    private static let whiteBackdropColor = CGColor(
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        components: [1.0, 1.0, 1.0, 1.0]
    )!
    /// Soft obsidian difference complement: maps pure white `#FFFFFF` -> `#171714` Obsidian
    /// and pure black `#000000` -> `#E8E8EB` comfortable off-white (avoiding OLED halation).
    private static let obsidianInvertColor = CGColor(
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        components: [0.910, 0.910, 0.922, 1.0]
    )!

    public override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let mode = (document as? ThemedPDFDocument)?.appearanceMode ?? .original

        switch mode {
        case .original:
            super.draw(with: box, to: context)

        case .paper:
            let pageBounds = bounds(for: box)
            context.saveGState()
            context.setFillColor(Self.whiteBackdropColor)
            context.fill(pageBounds)
            super.draw(with: box, to: context)
            context.setBlendMode(.multiply)
            context.setFillColor(Self.paperTintColor)
            context.fill(pageBounds)
            context.restoreGState()

        case .dark:
            drawHuePreservingDark(with: box, to: context)
        }
    }

    /// Single-pass tile-clipped dark rendering:
    /// 1. Draws original PDF vector graphics once into a tile-sized `CGLayer` over explicit white backdrop.
    /// 2. Composites the layer into `context`, applies `.difference` against soft obsidian (`0.91, 0.91, 0.92`)
    ///    to invert luminance cleanly without blinding contrast, then re-applies the same `CGLayer` with
    ///    `.hue` blend mode so links, syntax highlights, and charts keep their original colors.
    private func drawHuePreservingDark(with box: PDFDisplayBox, to context: CGContext) {
        let pageBounds = bounds(for: box)
        let rawClip = context.boundingBoxOfClipPath
        let clipRect: CGRect = {
            if rawClip.isNull || rawClip.isInfinite || rawClip.isEmpty {
                return pageBounds
            }
            let intersected = rawClip.intersection(pageBounds)
            return intersected.isEmpty ? pageBounds : intersected
        }()

        guard clipRect.width > 0.5, clipRect.height > 0.5 else {
            super.draw(with: box, to: context)
            return
        }

        // Derive physical scale from CTM columns (rotation-invariant for 90°/180°/270° PDF pages).
        let ctm = context.ctm
        let rawScaleX = max(1.0, hypot(ctm.a, ctm.b))
        let rawScaleY = max(1.0, hypot(ctm.c, ctm.d))
        let maxTileEdge: CGFloat = 2048
        let pixelW = min(maxTileEdge, max(1, ceil(clipRect.width * rawScaleX)))
        let pixelH = min(maxTileEdge, max(1, ceil(clipRect.height * rawScaleY)))
        let effScaleX = pixelW / clipRect.width
        let effScaleY = pixelH / clipRect.height

        if let layer = CGLayer(context, size: CGSize(width: pixelW, height: pixelH), auxiliaryInfo: nil),
           let layerCtx = layer.context {
            layerCtx.saveGState()
            layerCtx.scaleBy(x: effScaleX, y: effScaleY)
            layerCtx.translateBy(x: -clipRect.minX, y: -clipRect.minY)
            layerCtx.setFillColor(Self.whiteBackdropColor)
            layerCtx.fill(clipRect)
            super.draw(with: box, to: layerCtx)
            layerCtx.restoreGState()

            context.saveGState()
            context.clip(to: clipRect)
            context.draw(layer, in: clipRect)
            context.setBlendMode(.difference)
            context.setFillColor(Self.obsidianInvertColor)
            context.fill(clipRect)
            context.setBlendMode(.hue)
            context.draw(layer, in: clipRect)
            context.restoreGState()
        } else {
            // Safe fallback if CGLayer allocation is declined under extreme memory pressure.
            context.saveGState()
            context.setFillColor(Self.whiteBackdropColor)
            context.fill(pageBounds)
            super.draw(with: box, to: context)
            context.setBlendMode(.difference)
            context.setFillColor(Self.obsidianInvertColor)
            context.fill(pageBounds)
            context.restoreGState()
        }
    }
}

// MARK: - Per-Tab Observable PDF Document Session

/// Lightweight navigation command routed from SwiftUI controls to `NativePDFHostController`.
public enum PDFNavigationCommand: Equatable {
    case goToPage(Int)
    case highlightSelection(Int)
    case zoomIn
    case zoomOut
    case resetZoom
}

/// Active native PDF document state owned by a single browser tab (`CleanroomWebKitSession`).
/// Keeps temporary online preview files strictly outside the user's Downloads Vault until the user
/// explicitly invokes Save, and guarantees deterministic cleanup on navigation, close, or teardown.
@Observable
@MainActor
public final class PDFTabDocument: Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let localFileURL: URL
    public let isTemporaryPreviewFile: Bool
    public let suggestedFilename: String
    public let fileByteCount: Int64
    public let document: ThemedPDFDocument

    public private(set) var pageCount: Int
    public var currentPageIndex: Int = 0
    public private(set) var isLocked: Bool
    public private(set) var outlineNodes: [PDFOutlineNode]
    public var savedVaultURL: URL?

    // In-document Find state
    public var isSearchVisible: Bool = false
    public var searchQuery: String = ""
    public private(set) var searchResults: [PDFSelection] = []
    public private(set) var activeSearchResultIndex: Int = 0
    public private(set) var isSearching: Bool = false

    // Monotonic command channel consumed by `NativePDFHostController`
    public private(set) var commandSequence: Int = 0
    public private(set) var pendingCommand: PDFNavigationCommand?

    private var searchTask: Task<Void, Never>?
    private var didCleanTemporaryFile: Bool = false

    public var isLocalFileSource: Bool {
        sourceURL.isFileURL
    }

    public var isSavedInVault: Bool {
        if savedVaultURL != nil { return true }
        guard !isTemporaryPreviewFile else { return false }
        let vaultRoot = LiveContainerEnvironment.downloadsDirectory.standardizedFileURL.path
        let localPath = localFileURL.standardizedFileURL.path
        return localPath.hasPrefix(vaultRoot + "/")
    }

    public var displayTitle: String {
        if let attrs = document.documentAttributes,
           let metaTitle = attrs[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = metaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.lowercased() != "untitled" {
                return trimmed
            }
        }
        let stem = (suggestedFilename as NSString).deletingPathExtension
        return stem.isEmpty ? suggestedFilename : stem
    }

    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: max(0, fileByteCount), countStyle: .file)
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        localFileURL: URL,
        isTemporaryPreviewFile: Bool,
        suggestedFilename: String,
        fileByteCount: Int64,
        document: ThemedPDFDocument,
        initialAppearance: PDFAppearanceMode = .persistedCurrent,
        initialOutline: [PDFOutlineNode]? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.localFileURL = localFileURL
        self.isTemporaryPreviewFile = isTemporaryPreviewFile
        self.suggestedFilename = suggestedFilename
        self.fileByteCount = fileByteCount
        self.document = document
        document.appearanceMode = initialAppearance
        self.isLocked = document.isLocked
        self.pageCount = document.pageCount
        self.outlineNodes = initialOutline ?? (document.isLocked ? [] : document.extractOutlineNodes())
    }

    isolated deinit {
        searchTask?.cancel()
        if isTemporaryPreviewFile && !didCleanTemporaryFile {
            let url = localFileURL
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func dispatch(_ command: PDFNavigationCommand) {
        pendingCommand = command
        commandSequence &+= 1
    }

    public func jumpToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        let clamped = min(max(0, index), pageCount - 1)
        currentPageIndex = clamped
        dispatch(.goToPage(clamped))
    }

    @discardableResult
    public func unlock(password: String) -> Bool {
        guard isLocked else { return true }
        guard document.unlock(withPassword: password) else { return false }
        isLocked = document.isLocked
        pageCount = document.pageCount
        outlineNodes = document.extractOutlineNodes()
        currentPageIndex = 0
        return !isLocked
    }

    // MARK: - Asynchronous Debounced In-Document Search

    public func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLocked else {
            searchResults = []
            activeSearchResultIndex = 0
            isSearching = false
            return
        }

        isSearching = true
        let docBox = PDFTransferBox(document)
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let matchBox = await Task.detached(priority: .userInitiated) {
                PDFTransferBox(docBox.value.findString(trimmed, withOptions: [.caseInsensitive, .diacriticInsensitive]))
            }.value
            let matches = matchBox.value
            guard let self, !Task.isCancelled, self.searchQuery == query else { return }
            self.isSearching = false
            self.searchResults = matches
            self.activeSearchResultIndex = 0
            if !matches.isEmpty {
                self.dispatch(.highlightSelection(0))
            }
        }
    }

    public func stepSearchResult(delta: Int) {
        guard !searchResults.isEmpty else { return }
        let count = searchResults.count
        let next = ((activeSearchResultIndex + delta) % count + count) % count
        activeSearchResultIndex = next
        dispatch(.highlightSelection(next))
    }

    public func dismissSearch() {
        searchTask?.cancel()
        isSearchVisible = false
        searchQuery = ""
        searchResults = []
        activeSearchResultIndex = 0
        isSearching = false
    }

    // MARK: - Tab Thumbnail & Temporary File Lifecycle

    public func renderPageThumbnail(pageIndex: Int = 0, maxDimension: CGFloat = 320) -> UIImage? {
        document.renderThemedThumbnail(pageIndex: pageIndex, maxDimension: maxDimension)
    }

    public func cleanupTemporaryFileIfNeeded() {
        guard isTemporaryPreviewFile, !didCleanTemporaryFile else { return }
        didCleanTemporaryFile = true
        let url = localFileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Temporary Preview Cache Directory

    public nonisolated static var temporaryPreviewRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dys-pdf-preview", isDirectory: true)
    }

    public nonisolated static func makeTemporaryPreviewFileURL(
        tabID: UUID,
        suggestedFilename: String
    ) -> URL {
        let dir = temporaryPreviewRootDirectory
            .appendingPathComponent(tabID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = sanitizePDFFilename(suggestedFilename)
        return dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(baseName)", isDirectory: false)
    }

    /// Removes orphaned online PDF preview files left behind by prior app terminations.
    public nonisolated static func purgeOrphanedTemporaryPreviewFiles() {
        let root = temporaryPreviewRootDirectory
        try? FileManager.default.removeItem(at: root)
    }

    public nonisolated static func sanitizePDFFilename(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        let nonEmpty = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Document.pdf" : cleaned
        let truncated = nonEmpty.count > 140 ? String(nonEmpty.prefix(140)) : nonEmpty
        if truncated.lowercased().hasSuffix(".pdf") {
            return truncated
        }
        return "\(truncated).pdf"
    }
}
