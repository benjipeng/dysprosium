import Foundation
import ObjectiveC.runtime
import PDFKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Dysprosium

final class CustomSaveFolderAndTabsTests: XCTestCase {

    // MARK: - 1. LiveContainer `DocumentPicker.m` Inbox Rejection & Real Read/Write Verification

    func testRejectsTemporaryAndLiveContainerInboxURLs() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dys-test-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        XCTAssertTrue(CustomSaveFolderManager.isRejectedInboxOrTemporaryURL(tmpDir))

        let lcInbox = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/1234/tmp/com.example-Inbox/Downloads")
        XCTAssertTrue(CustomSaveFolderManager.isRejectedInboxOrTemporaryURL(lcInbox))

        let validDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DysprosiumCustomFolderTest", isDirectory: true)
        XCTAssertFalse(CustomSaveFolderManager.isRejectedInboxOrTemporaryURL(validDocs))

        // Friendly root folder display names for iOS Files providers
        let localRoot = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/1234/File Provider Storage", isDirectory: true)
        XCTAssertEqual(CustomSaveFolderManager.cleanFolderName(for: localRoot), "On My iPhone")
        XCTAssertEqual(CustomSaveFolderManager.displayBreadcrumb(for: localRoot), "On My iPhone")

        let iCloudRoot = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        XCTAssertEqual(CustomSaveFolderManager.cleanFolderName(for: iCloudRoot), "iCloud Drive")
        XCTAssertEqual(CustomSaveFolderManager.displayBreadcrumb(for: iCloudRoot), "iCloud Drive")

        let iCloudSub = iCloudRoot.appendingPathComponent("Papers", isDirectory: true)
        XCTAssertEqual(CustomSaveFolderManager.cleanFolderName(for: iCloudSub), "Papers")
        XCTAssertEqual(CustomSaveFolderManager.displayBreadcrumb(for: iCloudSub), "iCloud Drive › Papers")
    }

    // MARK: - 2. Per-Host Bookmark Isolation, Atomic Commit, Single-Truth Scan & Clean Reset

    @MainActor
    func testCustomSaveFolderLifecycleSingleTruthScanAndAtomicCommit() async throws {
        let fm = FileManager.default
        let docsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let customDir = docsRoot.appendingPathComponent("CustomSaveTest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: customDir, withIntermediateDirectories: true)

        let manager = CustomSaveFolderManager.shared
        let previousRecord = CustomSaveFolderManager.loadRecord()
        defer {
            _ = manager.resetToDefaultFolder()
            manager.dismissPendingMoveOffer()
            if let previousRecord {
                CustomSaveFolderManager.saveRecord(previousRecord)
            }
            try? fm.removeItem(at: customDir)
        }

        // Seed a file inside default internal downloads to verify single-truth exclusion once custom folder activates
        let defaultMarker = LiveContainerEnvironment.defaultDownloadsDirectory
            .appendingPathComponent("internal-only-\(UUID().uuidString.prefix(6)).txt")
        try Data("internal".utf8).write(to: defaultMarker, options: .atomic)
        defer { try? fm.removeItem(at: defaultMarker) }

        // 1. Adopt custom folder
        let outcome = manager.adoptPickedFolder(customDir)
        switch outcome {
        case .activated(let folderName, _, _):
            XCTAssertEqual(folderName, customDir.lastPathComponent)
        default:
            XCTFail("Expected .activated, got \(outcome)")
        }
        manager.dismissPendingMoveOffer()

        XCTAssertTrue(manager.status.isCustomActive)
        XCTAssertTrue(LiveContainerEnvironment.isUsingCustomDownloadsFolder)
        XCTAssertEqual(
            LiveContainerEnvironment.downloadsDirectory.standardizedFileURL.path,
            customDir.standardizedFileURL.path
        )

        // 2. Commit staged files atomically (collision-safe naming)
        let stage1 = fm.temporaryDirectory.appendingPathComponent("stage1-\(UUID().uuidString).pdf")
        let stage2 = fm.temporaryDirectory.appendingPathComponent("stage2-\(UUID().uuidString).pdf")
        try Data("PDF-BYTES-1".utf8).write(to: stage1)
        try Data("PDF-BYTES-2".utf8).write(to: stage2)
        defer {
            try? fm.removeItem(at: stage1)
            try? fm.removeItem(at: stage2)
        }

        let committed1 = try LiveContainerEnvironment.commitStagedFile(
            from: stage1,
            toDirectory: LiveContainerEnvironment.downloadsDirectory,
            preferredFilename: "paper.pdf",
            removeSource: true
        )
        let committed2 = try LiveContainerEnvironment.commitStagedFile(
            from: stage2,
            toDirectory: LiveContainerEnvironment.downloadsDirectory,
            preferredFilename: "paper.pdf",
            removeSource: true
        )
        XCTAssertEqual(committed1.lastPathComponent, "paper.pdf")
        XCTAssertEqual(committed2.lastPathComponent, "paper (2).pdf")
        XCTAssertFalse(fm.fileExists(atPath: stage1.path), "Staged source must be cleaned when removeSource == true")
        XCTAssertEqual(try Data(contentsOf: committed1), Data("PDF-BYTES-1".utf8))
        XCTAssertEqual(try Data(contentsOf: committed2), Data("PDF-BYTES-2".utf8))

        // 3. Single-truth scan must see ONLY files in customDir (never mixing internal-only legacy files)
        let scanned = LiveContainerEnvironment.scanDownloadedFiles()
        let scannedNames = Set(scanned.map(\.filename))
        XCTAssertEqual(scannedNames, Set(["paper.pdf", "paper (2).pdf"]))
        XCTAssertFalse(scannedNames.contains(defaultMarker.lastPathComponent))

        // 4. Simulate sibling LiveContainer 2 record (bookmark only exists for another host ID) -> `.needsHostGrant`
        let siblingRecord = CustomSaveFolderManager.SharedFolderRecord(
            folderName: customDir.lastPathComponent,
            breadcrumb: "Files › \(customDir.lastPathComponent)",
            canonicalPathHint: customDir.standardizedFileURL.path,
            bookmarksByHost: ["com.kdt.LiveContainer99.SIMULATED": Data([0x01, 0x02])]
        )
        CustomSaveFolderManager.saveRecord(siblingRecord)
        manager.resolveInBackgroundIfNeeded()

        if case .needsHostGrant(let expectedName, _, let hint) = manager.status {
            XCTAssertEqual(expectedName, customDir.lastPathComponent)
            XCTAssertEqual(hint, customDir.standardizedFileURL.path)
        } else {
            XCTFail("Expected .needsHostGrant when current host has no bookmark, got \(manager.status)")
        }

        // 5. Picking a DIFFERENT folder during `.needsHostGrant` triggers mismatch guard (prevents split-brain)
        let otherDir = docsRoot.appendingPathComponent("OtherFolder-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: otherDir) }

        let mismatch = manager.adoptPickedFolder(otherDir, forceSwitchSharedTarget: false)
        if case .confirmSwitchFromExpected(_, let pickedName, let expectedName) = mismatch {
            XCTAssertEqual(pickedName, otherDir.lastPathComponent)
            XCTAssertEqual(expectedName, customDir.lastPathComponent)
        } else {
            XCTFail("Expected .confirmSwitchFromExpected, got \(mismatch)")
        }

        // 6. Picking the MATCHING folder silently links LC 2 with zero move prompt
        let linked = manager.adoptPickedFolder(customDir, forceSwitchSharedTarget: false)
        XCTAssertEqual(linked, .linkedExistingSharedFolder(folderName: customDir.lastPathComponent))
        XCTAssertTrue(manager.status.isCustomActive)

        // 7. Reset back to default cleanly
        let resetOffer = manager.resetToDefaultFolder()
        XCTAssertEqual(resetOffer.movableFileCount, 2)
        manager.dismissPendingMoveOffer()
        XCTAssertEqual(manager.status, .defaultInternal)
        XCTAssertFalse(LiveContainerEnvironment.isUsingCustomDownloadsFolder)
    }

    // MARK: - 3. Live PDF Appearance Broadcast Updates All Open PDF Tabs

    @MainActor
    func testPDFAppearanceModeBroadcastUpdatesActiveAndBackgroundPDFDocuments() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        let tempPDF = PDFTabDocument.makeTemporaryPreviewFileURL(tabID: UUID(), suggestedFilename: "broadcast-test.pdf")
        try data.write(to: tempPDF, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempPDF) }

        let tempStateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dys-tabs-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempStateDir) }

        let store = CleanroomBrowserStore(customStateDirectory: tempStateDir)
        let previousAppearance = store.pdfAppearanceMode
        defer { store.pdfAppearanceMode = previousAppearance }

        store.pdfAppearanceMode = .original
        let pdfTab = store.openLocalPDFTab(fileURL: tempPDF, displayTitle: "broadcast-test.pdf")

        let deadline = ContinuousClock.now + .seconds(3)
        while pdfTab.activePDF == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        let doc = try XCTUnwrap(pdfTab.activePDF)
        XCTAssertEqual(doc.document.appearanceMode, .original)

        // Switching appearance updates the live `ThemedPDFDocument` immediately
        store.pdfAppearanceMode = .dark
        XCTAssertEqual(doc.document.appearanceMode, .dark)

        store.pdfAppearanceMode = .paper
        XCTAssertEqual(doc.document.appearanceMode, .paper)
    }

    // MARK: - 4. LiveContainer `DocumentPicker.m` Folder-Picker & `DOCConfiguration` Self-Heal

    @MainActor
    func testLiveContainerDocumentPickerBypassPreservesSoleFolderTypeAndOpenInPlace() throws {
        @MainActor
        enum Probe {
            static var poisonedInitCalled = false
            static var poisonedMultiCalled = false
            static var unswizzledContentTypes: [UTType] = []
            static var unswizzledAsCopy: Bool?
            static var unswizzledMultiFlag: Bool?
            static var didSwizzle = false
        }

        final class SimulatedLCSwizzledPicker: UIDocumentPickerViewController {
            override init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) {
                Probe.unswizzledContentTypes = contentTypes
                Probe.unswizzledAsCopy = asCopy
                super.init(forOpeningContentTypes: contentTypes, asCopy: asCopy)
            }

            // Before exchange: simulates LiveContainer's poisoned hook; after `method_exchangeImplementations`,
            // this selector holds the REAL `init(forOpeningContentTypes:asCopy:)` IMP above (identical to DocumentPicker.m).
            @objc(hook_initForOpeningContentTypes:asCopy:)
            func lcPoisonedInit(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> Self {
                Probe.poisonedInitCalled = true
                let swappedSel = NSSelectorFromString("hook_initForOpeningContentTypes:asCopy:")
                let origIMP = method_getImplementation(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, swappedSel)!)
                typealias InitIMP = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, ObjCBool) -> UnsafeMutableRawPointer
                let callOrig = unsafeBitCast(origIMP, to: InitIMP.self)
                let ptr = callOrig(Unmanaged.passRetained(self).toOpaque(), swappedSel, [UTType.item, UTType.folder] as NSArray, ObjCBool(true))
                return Unmanaged<Self>.fromOpaque(ptr).takeRetainedValue()
            }

            override var allowsMultipleSelection: Bool {
                get { super.allowsMultipleSelection }
                set {
                    Probe.unswizzledMultiFlag = newValue
                    super.allowsMultipleSelection = newValue
                }
            }

            @objc(hook_setAllowsMultipleSelection:)
            func lcPoisonedSetAllowsMultipleSelection(_ allows: Bool) {
                Probe.poisonedMultiCalled = true
                let swappedSel = NSSelectorFromString("hook_setAllowsMultipleSelection:")
                let origIMP = method_getImplementation(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, swappedSel)!)
                typealias SetBoolIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
                unsafeBitCast(origIMP, to: SetBoolIMP.self)(self, swappedSel, ObjCBool(true))
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError() }
        }

        // Perform the exact `method_exchangeImplementations` swizzles from LiveContainer's `TweakLoader/DocumentPicker.m`.
        let origInit = try XCTUnwrap(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, NSSelectorFromString("initForOpeningContentTypes:asCopy:")))
        let hookInit = try XCTUnwrap(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, NSSelectorFromString("hook_initForOpeningContentTypes:asCopy:")))
        let origMulti = try XCTUnwrap(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, NSSelectorFromString("setAllowsMultipleSelection:")))
        let hookMulti = try XCTUnwrap(class_getInstanceMethod(SimulatedLCSwizzledPicker.self, NSSelectorFromString("hook_setAllowsMultipleSelection:")))

        let realOriginalIMPs: Set<UnsafeRawPointer> = [
            UnsafeRawPointer(method_getImplementation(origInit)),
            UnsafeRawPointer(method_getImplementation(origMulti))
        ]
        let isOriginal: (IMP) -> Bool = { imp in
            realOriginalIMPs.contains(UnsafeRawPointer(imp))
        }

        // Case A: LiveContainer default (`doSymlinkInbox == false`): ONLY `initForOpeningContentTypes:asCopy:` is swizzled,
        // while `hook_setAllowsMultipleSelection:` exists as an UNSWIZZLED category method that must NOT be called (would recurse!).
        if !Probe.didSwizzle {
            Probe.didSwizzle = true
            method_exchangeImplementations(origInit, hookInit)
        }

        let initialDir = FileManager.default.temporaryDirectory
        let defaultPicker = LiveContainerDocumentPickerBridge.makeFolderPickerController(
            initialDirectoryURL: initialDir,
            pickerClass: SimulatedLCSwizzledPicker.self,
            isOriginalImplementation: isOriginal
        )
        XCTAssertTrue(defaultPicker is SimulatedLCSwizzledPicker)
        XCTAssertFalse(Probe.poisonedInitCalled, "Must bypass LiveContainer's poisoned [.item, .folder] swizzle")
        XCTAssertFalse(Probe.poisonedMultiCalled, "Must NOT invoke unswizzled hook_setAllowsMultipleSelection: category method")
        XCTAssertEqual(Probe.unswizzledContentTypes, [.folder], "Folder picker must pass sole [.folder] to Apple's initializer")
        XCTAssertEqual(Probe.unswizzledAsCopy, false, "Folder picker must open in-place (asCopy == false)")
        XCTAssertEqual(Probe.unswizzledMultiFlag, false, "Default path must invoke canonical allowsMultipleSelection = false")
        XCTAssertFalse(defaultPicker.allowsMultipleSelection)
        XCTAssertEqual(defaultPicker.directoryURL?.standardizedFileURL.path, initialDir.standardizedFileURL.path)

        // Case B: Legacy Fix File Picker (`doSymlinkInbox == true`): BOTH `init` and `setAllowsMultipleSelection:` are swizzled.
        method_exchangeImplementations(origMulti, hookMulti)
        defer { method_exchangeImplementations(origMulti, hookMulti) }
        Probe.unswizzledMultiFlag = nil

        let legacyPicker = LiveContainerDocumentPickerBridge.makeFolderPickerController(
            initialDirectoryURL: initialDir,
            pickerClass: SimulatedLCSwizzledPicker.self,
            isOriginalImplementation: isOriginal
        )
        XCTAssertFalse(Probe.poisonedInitCalled)
        XCTAssertFalse(Probe.poisonedMultiCalled, "Must bypass swizzled forced-multiselect hook")
        XCTAssertEqual(Probe.unswizzledMultiFlag, false)
        XCTAssertFalse(legacyPicker.allowsMultipleSelection)
    }

    @MainActor
    func testLiveContainerHostIdentifierFixOverridesSpoofedGuestBundleIDAndVerifiesDOCConfiguration() throws {
        final class SimulatedDOCConfiguration: NSObject {
            @objc dynamic var hostIdentifier: String?
        }

        let installed = LiveContainerDocumentPickerBridge.installHostIdentifierFix(
            on: SimulatedDOCConfiguration.self,
            hostBundleID: "com.kdt.livecontainer.6NH22AYRHG"
        )
        XCTAssertTrue(installed)

        let cfg = SimulatedDOCConfiguration()
        cfg.perform(NSSelectorFromString("setHostIdentifier:"), with: "com.appautomaton.dysprosium")
        XCTAssertEqual(
            cfg.hostIdentifier,
            "com.kdt.livecontainer.6NH22AYRHG",
            "Host identifier fix must substitute real host bundle ID for spoofed guest bundle ID"
        )

        // Verify iOS 27.2 runtime exposes `DOCConfiguration.setHostIdentifier:` and `UIDocumentPickerViewController`
        // initializers inside Apple's `/System/Library/` image so `dladdr` swizzle detection works deterministically.
        _ = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        let realPickerInit = try XCTUnwrap(
            class_getInstanceMethod(UIDocumentPickerViewController.self, NSSelectorFromString("initForOpeningContentTypes:asCopy:"))
        )
        let pickerInitPath = LiveContainerDocumentPickerBridge.imagePath(for: method_getImplementation(realPickerInit))
        XCTAssertTrue(
            LiveContainerDocumentPickerBridge.isAppleSystemImplementation(method_getImplementation(realPickerInit)),
            "Stock UIKit initForOpeningContentTypes:asCopy: resolved to \(String(describing: pickerInitPath))"
        )
        let realDOCClass: AnyClass? = NSClassFromString("DOCConfiguration")
        XCTAssertNotNil(realDOCClass, "DOCConfiguration must be present in iOS 27.2 DocumentManagerCore")
        if let realDOCClass {
            let realSetHost = try XCTUnwrap(
                class_getInstanceMethod(realDOCClass, NSSelectorFromString("setHostIdentifier:"))
            )
            let setHostPath = LiveContainerDocumentPickerBridge.imagePath(for: method_getImplementation(realSetHost))
            XCTAssertTrue(
                LiveContainerDocumentPickerBridge.isAppleSystemImplementation(method_getImplementation(realSetHost)),
                "Stock DOCConfiguration.setHostIdentifier: resolved to \(String(describing: setHostPath))"
            )
        }
    }
}
