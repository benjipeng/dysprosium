import Foundation
import Network
import PDFKit
import UIKit
import XCTest
@testable import Dysprosium

final class NativePDFTabTests: XCTestCase {

    // MARK: - Synthetic Multi-Page Color PDF Generator

    private func makeTestPDFData(
        pageCount: Int = 4,
        rotateFirstPage90: Bool = false
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 520)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Lanthanide Optics Handbook"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let baseData = renderer.pdfData { ctx in
            for idx in 0..<pageCount {
                ctx.beginPage()
                let cg = ctx.cgContext
                // Explicit crisp white background
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(pageRect)

                // Black ink block at top-left (x=40..120, y=40..120 in UIKit coords)
                cg.setFillColor(UIColor.black.cgColor)
                cg.fill(CGRect(x: 40, y: 40, width: 80, height: 80))

                // Pure blue accent block (x=160..240, y=40..120)
                cg.setFillColor(UIColor(red: 0.10, green: 0.35, blue: 0.92, alpha: 1.0).cgColor)
                cg.fill(CGRect(x: 160, y: 40, width: 80, height: 80))

                // Pure red accent block (x=280..360, y=40..120)
                cg.setFillColor(UIColor(red: 0.90, green: 0.16, blue: 0.16, alpha: 1.0).cgColor)
                cg.fill(CGRect(x: 280, y: 40, width: 80, height: 80))

                // Searchable body text
                let title = "Chapter \(idx + 1): Dysprosium Native PDF Reader"
                let body = "Page \(idx + 1) discusses lanthanide optical efficiency and folding displays."
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 18),
                    .foregroundColor: UIColor.black
                ]
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13),
                    .foregroundColor: UIColor.darkGray
                ]
                (title as NSString).draw(in: CGRect(x: 40, y: 160, width: 320, height: 36), withAttributes: titleAttrs)
                (body as NSString).draw(in: CGRect(x: 40, y: 210, width: 320, height: 80), withAttributes: bodyAttrs)
            }

            // Embed real ISO-32000 PDF `/Outlines` (1-based destinations per CoreGraphics spec)
            let outline: [String: Any] = [
                kCGPDFOutlineChildren as String: (1...pageCount).map { pageNum in
                    [
                        kCGPDFOutlineTitle as String: "Chapter \(pageNum)",
                        kCGPDFOutlineDestination as String: pageNum,
                        kCGPDFOutlineDestinationRect as String: pageRect.dictionaryRepresentation
                    ] as [String: Any]
                }
            ]
            CGPDFContextSetOutline(ctx.cgContext, outline as CFDictionary)
        }

        if rotateFirstPage90, let doc = PDFDocument(data: baseData), let p0 = doc.page(at: 0) {
            p0.rotation = 90
            return doc.dataRepresentation() ?? baseData
        }
        return baseData
    }

    private func renderPixelRGBA(
        from doc: ThemedPDFDocument,
        pageIndex: Int,
        at point: CGPoint,
        canvasSize: CGSize = CGSize(width: 400, height: 520)
    ) -> (r: Int, g: Int, b: Int) {
        guard let page = doc.page(at: pageIndex) else {
            XCTFail("Missing PDF page \(pageIndex)")
            return (0, 0, 0)
        }
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to build bitmap CGContext")
            return (0, 0, 0)
        }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvasSize))
        page.draw(with: .mediaBox, to: ctx)

        // CoreGraphics bitmap row 0 is TOP of image (UIKit y = point.y); PDF page draws bottom-up so
        // UIKit y=80 corresponds to bitmap row y=80 directly when drawn unflipped with page.draw!
        let px = min(max(0, Int(point.x)), width - 1)
        let py = min(max(0, Int(point.y)), height - 1)
        let offset = (py * width + px) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    // MARK: - 1. iPhone Duo Posture & Fold-Crease Layout Tests

    func testDuoLayoutResolvesAcrossAllPosturesAndBookPoseFold() {
        // Closed Outer Display (466×678) -> Single Page Continuous
        let outer = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 382, height: 678),
            verticalHingeRect: nil,
            preference: .auto,
            pageCount: 12
        )
        XCTAssertEqual(outer.displayMode, .singlePageContinuous)
        XCTAssertFalse(outer.displaysAsBook)

        // Inner Portrait (669×951) -> Single Page Continuous
        let innerPortrait = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 669, height: 951),
            verticalHingeRect: nil,
            preference: .auto,
            pageCount: 12
        )
        XCTAssertEqual(innerPortrait.displayMode, .singlePageContinuous)
        XCTAssertFalse(innerPortrait.displaysAsBook)

        // Inner Landscape flat (867×669 safe width) -> Two-Up Book Spread
        let innerLandscape = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 867, height: 669),
            verticalHingeRect: nil,
            preference: .auto,
            pageCount: 12
        )
        XCTAssertEqual(innerLandscape.displayMode, .twoUpContinuous)
        XCTAssertTrue(innerLandscape.displaysAsBook)

        // Book Pose with active 40 pt `.division` vertical crease -> Two-Up with >= 48 pt total horizontal gutter
        let bookPose = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 867, height: 669),
            verticalHingeRect: CGRect(x: 455.5, y: 0, width: 40, height: 669),
            preference: .auto,
            pageCount: 12
        )
        XCTAssertEqual(bookPose.displayMode, .twoUpContinuous)
        XCTAssertTrue(bookPose.displaysAsBook)
        XCTAssertGreaterThanOrEqual(bookPose.pageBreakMargins.left + bookPose.pageBreakMargins.right, 48)

        // Single-page PDF on Inner Landscape stays centered single-page (never awkwardly pushed to one half)
        let singlePageDoc = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 867, height: 669),
            verticalHingeRect: nil,
            preference: .auto,
            pageCount: 1
        )
        XCTAssertEqual(singlePageDoc.displayMode, .singlePageContinuous)

        // Explicit Single Page override respected in Inner Landscape
        let forcedSingle = PDFDuoLayoutConfiguration.resolve(
            viewportSize: CGSize(width: 867, height: 669),
            verticalHingeRect: nil,
            preference: .singlePage,
            pageCount: 12
        )
        XCTAssertEqual(forcedSingle.displayMode, .singlePageContinuous)
    }

    // MARK: - 2. CoreGraphics Original / Paper / Hue-Preserving Dark Pixel Verification

    func testThemedPDFPageRenderingPreservesHuesInDarkAndTintsPaper() {
        let pdfData = makeTestPDFData(pageCount: 2)
        guard let doc = ThemedPDFDocument(data: pdfData) else {
            return XCTFail("Failed to parse generated PDF")
        }

        // Sample coordinates (in bitmap top-down coordinates matching UIGraphicsPDFRenderer blocks)
        let whiteBgPt = CGPoint(x: 20, y: 460)
        let blackInkPt = CGPoint(x: 80, y: 80)
        let blueBlockPt = CGPoint(x: 200, y: 80)
        let redBlockPt = CGPoint(x: 320, y: 80)

        // Original
        doc.appearanceMode = .original
        let origBg = renderPixelRGBA(from: doc, pageIndex: 0, at: whiteBgPt)
        let origBlack = renderPixelRGBA(from: doc, pageIndex: 0, at: blackInkPt)
        let origBlue = renderPixelRGBA(from: doc, pageIndex: 0, at: blueBlockPt)
        let origRed = renderPixelRGBA(from: doc, pageIndex: 0, at: redBlockPt)
        XCTAssertGreaterThan(origBg.r, 250)
        XCTAssertLessThan(origBlack.r, 10)
        XCTAssertGreaterThan(origBlue.b, origBlue.r + 120)
        XCTAssertGreaterThan(origRed.r, origRed.b + 120)

        // Paper (warm sepia: white -> R > G > B, black stays crisp black)
        doc.appearanceMode = .paper
        let paperBg = renderPixelRGBA(from: doc, pageIndex: 0, at: whiteBgPt)
        let paperBlack = renderPixelRGBA(from: doc, pageIndex: 0, at: blackInkPt)
        XCTAssertGreaterThan(paperBg.r, paperBg.g)
        XCTAssertGreaterThan(paperBg.g, paperBg.b + 15)
        XCTAssertLessThan(paperBlack.r, 10)

        // Dark (soft Obsidian background, off-white text, AND true hue preserved on blue & red blocks)
        doc.appearanceMode = .dark
        let darkBg = renderPixelRGBA(from: doc, pageIndex: 0, at: whiteBgPt)
        let darkBlack = renderPixelRGBA(from: doc, pageIndex: 0, at: blackInkPt)
        let darkBlue = renderPixelRGBA(from: doc, pageIndex: 0, at: blueBlockPt)
        let darkRed = renderPixelRGBA(from: doc, pageIndex: 0, at: redBlockPt)

        XCTAssertLessThan(darkBg.r, 35, "White page background must invert to soft Obsidian")
        XCTAssertLessThan(darkBg.g, 35)
        XCTAssertLessThan(darkBg.b, 35)

        XCTAssertGreaterThan(darkBlack.r, 215, "Black text must invert to comfortable off-white")
        XCTAssertGreaterThan(darkBlack.g, 215)
        XCTAssertGreaterThan(darkBlack.b, 215)

        XCTAssertGreaterThan(darkBlue.b, darkBlue.r + 40, "Blue links/charts must keep blue hue in Dark Mode")
        XCTAssertGreaterThan(darkRed.r, darkRed.b + 40, "Red annotations/charts must keep red hue in Dark Mode")
    }

    func testThemedPDFPageDarkModeHandlesRotatedPage() {
        let pdfData = makeTestPDFData(pageCount: 1, rotateFirstPage90: true)
        guard let doc = ThemedPDFDocument(data: pdfData) else {
            return XCTFail("Failed to parse rotated PDF")
        }
        doc.appearanceMode = .dark
        guard let page = doc.page(at: 0) else { return XCTFail("Missing page 0") }
        let thumb = page.thumbnail(of: CGSize(width: 260, height: 200), for: .mediaBox)
        XCTAssertGreaterThan(thumb.size.width, 10)
        XCTAssertGreaterThan(thumb.size.height, 10)
    }

    // MARK: - 3. Outline Extraction, Search, One-Tap Save Original & Temp Hygiene

    @MainActor
    func testOutlineSearchSaveOriginalAndTemporaryFileCleanup() async throws {
        let pdfData = makeTestPDFData(pageCount: 4)
        let tempURL = PDFTabDocument.makeTemporaryPreviewFileURL(tabID: UUID(), suggestedFilename: "optics-paper.pdf")
        try pdfData.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let session = CleanroomWebKitSession(isPrivate: false)
        session.openLocalPDF(
            fileURL: tempURL,
            displayTitle: "optics-paper.pdf",
            isTemporaryPreviewFile: true,
            sourceURLOverride: URL(string: "https://example.org/papers/optics-paper.pdf")!
        )

        // Wait briefly for off-main PDF parsing
        let deadline = ContinuousClock.now + .seconds(3)
        while session.activePDF == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }

        let activePDF = try XCTUnwrap(session.activePDF)
        XCTAssertEqual(activePDF.pageCount, 4)
        XCTAssertEqual(activePDF.displayTitle, "Lanthanide Optics Handbook")
        XCTAssertEqual(activePDF.outlineNodes.count, 4)
        XCTAssertEqual(activePDF.outlineNodes.first?.title, "Chapter 1")
        XCTAssertFalse(activePDF.isSavedInVault, "Online preview must NOT pollute Vault until explicitly saved")

        // In-document search
        activePDF.updateSearchQuery("lanthanide")
        let searchDeadline = ContinuousClock.now + .seconds(3)
        while activePDF.searchResults.isEmpty && ContinuousClock.now < searchDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(activePDF.searchResults.count, 4)

        // One-tap Save Original PDF to Vault (copies untouched original bytes without re-downloading)
        let savedURL = await session.saveActivePDFToVault()
        let unwrappedSaved = try XCTUnwrap(savedURL)
        defer { try? FileManager.default.removeItem(at: unwrappedSaved) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrappedSaved.path))
        XCTAssertEqual(try Data(contentsOf: unwrappedSaved), pdfData, "Saved PDF must be byte-identical to original")
        XCTAssertTrue(activePDF.isSavedInVault)

        // Idempotent second save returns the exact same Vault URL without creating duplicates
        let secondSave = await session.saveActivePDFToVault()
        XCTAssertEqual(secondSave?.standardizedFileURL.path, unwrappedSaved.standardizedFileURL.path)

        // Teardown removes the temporary preview file while leaving the saved Vault copy intact
        session.teardown()
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while FileManager.default.fileExists(atPath: tempURL.path) && ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "Temporary preview must be cleaned up on teardown")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrappedSaved.path), "Saved Vault PDF must remain intact")
    }

    // MARK: - 4. End-to-End Live Loopback HTTP `application/pdf` -> `WKWebView` -> Native `PDFKit` Tab + Instant Back

    @MainActor
    func testLiveLoopbackInlinePDFOpensInNativeTabWithoutVaultPollutionAndReturnsBack() async throws {
        let pdfBytes = makeTestPDFData(pageCount: 3)
        let server = try InlinePDFLoopbackServer(pdfData: pdfBytes)
        let port = try await server.start()
        defer { server.stop() }

        let session = CleanroomWebKitSession(isPrivate: true)
        defer { session.teardown() }

        // 1. Load a regular HTML page first
        let indexURL = "http://127.0.0.1:\(port)/index.html"
        session.load(urlString: indexURL)
        let htmlDeadline = ContinuousClock.now + .seconds(20)
        while (session.isLoading || session.pageTitle != "Paper Index") && ContinuousClock.now < htmlDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.pageTitle, "Paper Index", "Referring HTML page must commit before navigating to PDF")
        XCTAssertNil(session.activePDF)

        // 2. Navigate to an inline `application/pdf` response (no Content-Disposition: attachment)
        let pdfURL = "http://127.0.0.1:\(port)/paper.pdf"
        session.load(urlString: pdfURL)

        let pdfDeadline = ContinuousClock.now + .seconds(20)
        while session.activePDF == nil && ContinuousClock.now < pdfDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let opened = try XCTUnwrap(session.activePDF, "Inline HTTP application/pdf must hand off into native PDFKit tab")
        XCTAssertEqual(opened.pageCount, 3)
        XCTAssertEqual(opened.sourceURL.absoluteString, pdfURL)
        XCTAssertTrue(opened.isTemporaryPreviewFile)
        XCTAssertFalse(opened.isSavedInVault, "Viewing online PDF must not auto-save to Downloads Vault")
        XCTAssertTrue(session.canGoBack, "Back must be enabled to return to the referring webpage")

        // 3. Navigating Back dismisses the native PDF immediately and exposes the live HTML page underneath
        session.navigateBack()
        XCTAssertNil(session.activePDF)
        XCTAssertEqual(session.currentURLString, indexURL)
        XCTAssertTrue(session.canGoForward, "Forward must remain enabled to revisit the PDF")
    }
}

// MARK: - Minimal Local Loopback Server Serving HTML + Inline `application/pdf`

private final class InlinePDFLoopbackServer: @unchecked Sendable {
    private let pdfData: Data
    private let queue = DispatchQueue(label: "com.dysprosium.test.pdf-loopback")
    private var listener: NWListener?

    init(pdfData: Data) throws {
        self.pdfData = pdfData
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: .any)
    }

    private final class ResumeOnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    func start() async throws -> UInt16 {
        guard let listener else { throw URLError(.cannotOpenFile) }
        return try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let err):
                    guard once.claim() else { return }
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = req.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            let responseData: Data
            if path.hasPrefix("/paper.pdf") {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Length: \(self.pdfData.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(self.pdfData)
                responseData = payload
            } else {
                let html = "<!doctype html><html><head><title>Paper Index</title></head><body><a href=\"/paper.pdf\">Read Paper</a></body></html>"
                let body = Data(html.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(body)
                responseData = payload
            }

            conn.send(content: responseData, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
}
