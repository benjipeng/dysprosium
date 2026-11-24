import Darwin
import Foundation
import ObjectiveC.runtime
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Multi-instance safe Security-Scoped Save Folder manager for LiveContainer (`LC 1` / `LC 2` / `LC 3+`)
/// and standalone iOS builds.
///
/// Key iOS & LiveContainer invariants enforced:
/// - Keys security-scoped bookmarks by the **real host bundle ID** (`+[NSUserDefaults lcMainBundle]`),
///   which stays distinct per LiveContainer host and stable across 7-day certificate refreshes even
///   after `overwriteMainNSBundle` rewrites `Bundle.main` to the guest identifier.
/// - Holds a **single process-scoped security lease** (`startAccessingSecurityScopedResource`) to prevent
///   ref-count leaks and keep `AVPlayer`, `PDFKit`, `QLPreviewController`, and `ShareLink` authorized.
/// - Resolves bookmarks strictly **off `@MainActor`** so cold `iCloud Drive` / `fileproviderd` mounts
///   never block launch or trigger watchdog terminations.
/// - Defends against LiveContainer's legacy *Fix File Picker* (`doSymlinkInbox`) swizzle by rejecting
///   temporary `-Inbox` URLs and verifying real `isWritableFile` + `contentsOfDirectory` access.
@Observable
@MainActor
public final class CustomSaveFolderManager {
    public static let shared = CustomSaveFolderManager()

    public enum Status: Equatable, Sendable {
        case defaultInternal
        case customActive(url: URL, folderName: String, breadcrumb: String)
        case needsHostGrant(folderName: String, breadcrumb: String, canonicalPathHint: String)

        public var isCustomActive: Bool {
            if case .customActive = self { return true }
            return false
        }

        public var needsHostGrant: Bool {
            if case .needsHostGrant = self { return true }
            return false
        }

        public var activeURL: URL? {
            if case .customActive(let url, _, _) = self { return url }
            return nil
        }
    }

    public enum PickOutcome: Equatable, Sendable {
        case linkedExistingSharedFolder(folderName: String)
        case activated(folderName: String, offerMoveFrom: URL?, movableFileCount: Int)
        case confirmSwitchFromExpected(pickedURL: URL, pickedName: String, expectedName: String)
        case rejected(message: String)
    }

    public struct SharedFolderRecord: Codable, Equatable, Sendable {
        public var folderName: String
        public var breadcrumb: String
        public var canonicalPathHint: String
        public var bookmarksByHost: [String: Data]

        public init(
            folderName: String,
            breadcrumb: String,
            canonicalPathHint: String,
            bookmarksByHost: [String: Data]
        ) {
            self.folderName = folderName
            self.breadcrumb = breadcrumb
            self.canonicalPathHint = canonicalPathHint
            self.bookmarksByHost = bookmarksByHost
        }
    }

    private nonisolated static let recordDefaultsKey = "dysprosium.storage.customSaveFolderRecord.v1"

    public private(set) var status: Status = .defaultInternal
    public private(set) var isResolving: Bool = false
    public private(set) var revision: Int = 0
    public var lastErrorMessage: String?

    private var activeScopedURL: URL?
    private var pendingMoveSourceLease: URL?
    private var resolveTask: Task<Void, Never>?

    private init() {}

    // MARK: - LiveContainer Real Host Identity (`LCBootstrap.m`)

    /// Resolves the genuine host app bundle identifier (`com.kdt.livecontainer...` / `com.kdt.LiveContainer2...`),
    /// bypassing LiveContainer's `overwriteMainNSBundle` guest spoofing.
    public nonisolated static func currentHostBundleIdentifier() -> String {
        let sel = NSSelectorFromString("lcMainBundle")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let hostBundle = unmanaged.takeUnretainedValue() as? Bundle,
           let hostID = hostBundle.bundleIdentifier,
           !hostID.isEmpty {
            return hostID
        }
        return Bundle.main.bundleIdentifier ?? "com.appautomaton.dysprosium.standalone"
    }

    /// Friendly human-readable label for the current LiveContainer host (`LiveContainer`, `LiveContainer 2`, etc.).
    public nonisolated static func currentHostDisplayName() -> String {
        let sel = NSSelectorFromString("lcAppUrlScheme")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let scheme = unmanaged.takeUnretainedValue() as? String,
           !scheme.isEmpty {
            let lower = scheme.lowercased()
            if lower == "livecontainer" {
                return "LiveContainer"
            }
            if lower.hasPrefix("livecontainer") {
                let suffix = String(lower.dropFirst("livecontainer".count))
                if !suffix.isEmpty {
                    return "LiveContainer \(suffix)"
                }
            }
            return scheme
        }
        return LiveContainerEnvironment.isRunningInLiveContainer ? "LiveContainer" : L("This Device")
    }

    /// Detects LiveContainer's legacy *Fix File Picker* toggle (`guestAppInfo["doSymlinkInbox"] == true`),
    /// which converts folder picks into Inbox copies and stubs `startAccessingSecurityScopedResource()` to `true`.
    public nonisolated static func isLegacySymlinkInboxEnabled() -> Bool {
        let sel = NSSelectorFromString("lcGuestAppInfo")
        if (UserDefaults.self as AnyObject).responds(to: sel),
           let unmanaged = (UserDefaults.self as AnyObject).perform(sel),
           let info = unmanaged.takeUnretainedValue() as? [String: Any],
           let flag = info["doSymlinkInbox"] as? Bool {
            return flag
        }
        if let info = UserDefaults.standard.dictionary(forKey: "guestAppInfo"),
           let flag = info["doSymlinkInbox"] as? Bool {
            return flag
        }
        return false
    }

    // MARK: - Startup & Foreground Asynchronous Bookmark Resolution

    public func resolveInBackgroundIfNeeded() {
        resolveTask?.cancel()
        guard let record = Self.loadRecord() else {
            releaseScopedAccess()
            LiveContainerEnvironment.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
            if status != .defaultInternal {
                status = .defaultInternal
                revision &+= 1
            }
            return
        }

        let hostID = Self.currentHostBundleIdentifier()
        guard let bookmarkData = record.bookmarksByHost[hostID] else {
            releaseScopedAccess()
            LiveContainerEnvironment.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
            status = .needsHostGrant(
                folderName: record.folderName,
                breadcrumb: record.breadcrumb,
                canonicalPathHint: record.canonicalPathHint
            )
            revision &+= 1
            return
        }

        // Fast-path: if already holding an active lease for this exact folder and it remains writable, keep it.
        if let existing = activeScopedURL,
           existing.standardizedFileURL.path == record.canonicalPathHint,
           Self.verifyRealDirectoryReadWrite(at: existing) {
            LiveContainerEnvironment.setActiveCustomDownloadsFolder(
                url: existing,
                displayBreadcrumb: record.breadcrumb
            )
            status = .customActive(url: existing, folderName: record.folderName, breadcrumb: record.breadcrumb)
            return
        }

        isResolving = true
        resolveTask = Task { @MainActor [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) { () -> (url: URL, refreshedBookmark: Data?)? in
                var isStale = false
                guard let url = Self.resolvePersistentBookmark(bookmarkData, isStale: &isStale) else {
                    return nil
                }
                let granted = url.startAccessingSecurityScopedResource()
                // Verify real filesystem read/write instead of trusting swizzled `startAccessingSecurityScopedResource`.
                guard Self.verifyRealDirectoryReadWrite(at: url) else {
                    if granted { url.stopAccessingSecurityScopedResource() }
                    return nil
                }
                let refreshed: Data?
                if isStale {
                    refreshed = Self.createPersistentBookmark(for: url)
                } else {
                    refreshed = nil
                }
                return (url, refreshed)
            }.value

            guard let self, !Task.isCancelled else {
                resolved?.url.stopAccessingSecurityScopedResource()
                return
            }
            self.isResolving = false

            guard let resolved else {
                self.releaseScopedAccess()
                LiveContainerEnvironment.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
                self.status = .needsHostGrant(
                    folderName: record.folderName,
                    breadcrumb: record.breadcrumb,
                    canonicalPathHint: record.canonicalPathHint
                )
                self.revision &+= 1
                return
            }

            // Atomically swap active security lease
            self.releaseScopedAccess()
            self.activeScopedURL = resolved.url

            var updatedRecord = record
            let canonicalPath = resolved.url.standardizedFileURL.path
            let folderName = Self.cleanFolderName(for: resolved.url)
            let breadcrumb = Self.displayBreadcrumb(for: resolved.url)
            var didMutate = false
            if let refreshedBookmark = resolved.refreshedBookmark {
                updatedRecord.bookmarksByHost[hostID] = refreshedBookmark
                didMutate = true
            }
            if updatedRecord.canonicalPathHint != canonicalPath
                || updatedRecord.folderName != folderName
                || updatedRecord.breadcrumb != breadcrumb {
                updatedRecord.canonicalPathHint = canonicalPath
                updatedRecord.folderName = folderName
                updatedRecord.breadcrumb = breadcrumb
                didMutate = true
            }
            if didMutate {
                Self.saveRecord(updatedRecord)
            }

            LiveContainerEnvironment.setActiveCustomDownloadsFolder(
                url: resolved.url,
                displayBreadcrumb: updatedRecord.breadcrumb
            )
            self.status = .customActive(
                url: resolved.url,
                folderName: updatedRecord.folderName,
                breadcrumb: updatedRecord.breadcrumb
            )
            self.revision &+= 1
        }
    }

    // MARK: - Adopting a User-Picked Folder

    /// Processes a folder chosen via `UIDocumentPickerViewController`.
    /// When `forceSwitchSharedTarget` is `false` and the current host is in `.needsHostGrant`,
    /// picking a *different* folder than the one configured on another LiveContainer host returns
    /// `.confirmSwitchFromExpected` to prevent accidental split-brain between LC 1 and LC 2.
    public func adoptPickedFolder(
        _ pickedURL: URL,
        forceSwitchSharedTarget: Bool = false
    ) -> PickOutcome {
        lastErrorMessage = nil

        if Self.isRejectedInboxOrTemporaryURL(pickedURL) {
            let msg = Self.isLegacySymlinkInboxEnabled()
                ? L("Turn off \"Fix File Picker\" in LiveContainer app settings so iOS can grant real folder access.")
                : L("Please pick a permanent folder in On My iPhone or iCloud Drive (temporary Inbox folders cannot persist).")
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let granted = pickedURL.startAccessingSecurityScopedResource()
        guard Self.verifyRealDirectoryReadWrite(at: pickedURL) else {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            let msg = Self.isLegacySymlinkInboxEnabled()
                ? L("Folder is not writable. Disable \"Fix File Picker\" in LiveContainer app settings and try again.")
                : L("Dysprosium could not obtain write access to that folder. Please choose a writable folder in On My iPhone or iCloud Drive.")
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let canonicalPath = pickedURL.standardizedFileURL.path
        let folderName = Self.cleanFolderName(for: pickedURL)
        let breadcrumb = Self.displayBreadcrumb(for: pickedURL)
        let hostID = Self.currentHostBundleIdentifier()

        // Path-match guard when linking a secondary LiveContainer host (e.g. LC 2 linking LC 1's folder).
        if case .needsHostGrant(let expectedName, _, let expectedPath) = status,
           !forceSwitchSharedTarget,
           canonicalPath != expectedPath {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            return .confirmSwitchFromExpected(
                pickedURL: pickedURL,
                pickedName: folderName,
                expectedName: expectedName
            )
        }

        guard let bookmarkData = Self.createPersistentBookmark(for: pickedURL) else {
            if granted { pickedURL.stopAccessingSecurityScopedResource() }
            let msg = L("iOS could not create a persistent bookmark for \"\(folderName)\".")
            lastErrorMessage = msg
            return .rejected(message: msg)
        }

        let previousDir = LiveContainerEnvironment.downloadsDirectory
        let previousScoped = activeScopedURL
        let wasMatchingNeedsGrant: Bool = {
            if case .needsHostGrant(_, _, let expectedPath) = status {
                return canonicalPath == expectedPath
            }
            return false
        }()

        var nextRecord: SharedFolderRecord
        if wasMatchingNeedsGrant, var existing = Self.loadRecord() {
            existing.bookmarksByHost[hostID] = bookmarkData
            existing.folderName = folderName
            existing.breadcrumb = breadcrumb
            existing.canonicalPathHint = canonicalPath
            nextRecord = existing
        } else {
            // Fresh folder or intentional switch across all hosts: drop stale bookmarks for other hosts
            // so sibling LiveContainer instances promptly ask to link the new shared folder.
            nextRecord = SharedFolderRecord(
                folderName: folderName,
                breadcrumb: breadcrumb,
                canonicalPathHint: canonicalPath,
                bookmarksByHost: [hostID: bookmarkData]
            )
        }

        Self.saveRecord(nextRecord)
        releasePendingMoveSourceLease()
        let oldPath = previousDir.standardizedFileURL.path
        let movableCount = (wasMatchingNeedsGrant || oldPath == canonicalPath)
            ? 0
            : Self.countVisibleRegularFiles(in: previousDir)
        if movableCount > 0, let previousScoped, previousScoped.standardizedFileURL.path == oldPath {
            // Retain read/move scope on the departing custom folder until the user resolves the move dialog.
            pendingMoveSourceLease = previousScoped
            activeScopedURL = nil
        } else {
            releaseScopedAccess()
        }
        activeScopedURL = pickedURL
        LiveContainerEnvironment.setActiveCustomDownloadsFolder(
            url: pickedURL,
            displayBreadcrumb: breadcrumb
        )
        status = .customActive(url: pickedURL, folderName: folderName, breadcrumb: breadcrumb)
        revision &+= 1

        if wasMatchingNeedsGrant {
            return .linkedExistingSharedFolder(folderName: folderName)
        }

        if movableCount > 0 {
            return .activated(folderName: folderName, offerMoveFrom: previousDir, movableFileCount: movableCount)
        }
        return .activated(folderName: folderName, offerMoveFrom: nil, movableFileCount: 0)
    }

    /// Resets storage back to Dysprosium's built-in default container across all LiveContainer hosts.
    public func resetToDefaultFolder() -> (offerMoveFrom: URL?, movableFileCount: Int) {
        lastErrorMessage = nil
        releasePendingMoveSourceLease()
        let previousCustom = activeScopedURL
        let previousCount = previousCustom.map { Self.countVisibleRegularFiles(in: $0) } ?? 0

        Self.clearRecord()
        if previousCount > 0, let previousCustom {
            pendingMoveSourceLease = previousCustom
            activeScopedURL = nil
        } else {
            releaseScopedAccess()
        }
        LiveContainerEnvironment.setActiveCustomDownloadsFolder(url: nil, displayBreadcrumb: nil)
        status = .defaultInternal
        revision &+= 1

        return (previousCount > 0 ? previousCustom : nil, previousCount)
    }

    /// Releases any temporarily retained read/move lease when the user declines moving previous files.
    public func dismissPendingMoveOffer() {
        releasePendingMoveSourceLease()
    }

    /// One-shot non-blocking move of existing files from `sourceDir` into the active `downloadsDirectory`.
    public func moveExistingFiles(from sourceDir: URL) async -> (moved: Int, failed: Int) {
        defer { releasePendingMoveSourceLease() }
        let destinationDir = LiveContainerEnvironment.downloadsDirectory
        guard sourceDir.standardizedFileURL.path != destinationDir.standardizedFileURL.path else {
            return (0, 0)
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Int) in
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return (0, 0)
            }

            var moved = 0
            var failed = 0
            for item in items {
                let name = item.lastPathComponent
                guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { continue }
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if vals?.isDirectory == true { continue }

                do {
                    _ = try LiveContainerEnvironment.commitStagedFile(
                        from: item,
                        toDirectory: destinationDir,
                        preferredFilename: name,
                        removeSource: true
                    )
                    moved += 1
                } catch {
                    failed += 1
                }
            }
            return (moved, failed)
        }.value
        revision &+= 1
        return result
    }

    /// Best-effort parent directory URL to pre-seed `UIDocumentPickerViewController.directoryURL`
    /// when granting LC 2 access to an existing folder chosen on LC 1.
    public var suggestedPickerDirectoryURL: URL? {
        switch status {
        case .customActive(let url, _, _):
            return url.deletingLastPathComponent()
        case .needsHostGrant(_, _, let hint):
            let parent = URL(fileURLWithPath: hint, isDirectory: true).deletingLastPathComponent()
            return FileManager.default.fileExists(atPath: parent.path) ? parent : nil
        case .defaultInternal:
            return nil
        }
    }

    // MARK: - Internal Helpers & Pure Validators

    private func releaseScopedAccess() {
        if let activeScopedURL {
            activeScopedURL.stopAccessingSecurityScopedResource()
            self.activeScopedURL = nil
        }
    }

    private func releasePendingMoveSourceLease() {
        if let pendingMoveSourceLease {
            pendingMoveSourceLease.stopAccessingSecurityScopedResource()
            self.pendingMoveSourceLease = nil
        }
    }

    public nonisolated static func isRejectedInboxOrTemporaryURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let tmpPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if path == tmpPath || path.hasPrefix(tmpPath + "/") {
            return true
        }
        if path.contains("-Inbox/") || path.hasSuffix("-Inbox") || path.contains("/tmp/") {
            return true
        }
        return false
    }

    public nonisolated static func verifyRealDirectoryReadWrite(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard fm.isWritableFile(atPath: url.path) else {
            return false
        }
        return (try? fm.contentsOfDirectory(atPath: url.path)) != nil
    }

    public nonisolated static func cleanFolderName(for url: URL) -> String {
        let raw = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "File Provider Storage" {
            return L("On My iPhone")
        }
        if raw == "com~apple~CloudDocs" {
            return L("iCloud Drive")
        }
        return raw.isEmpty ? L("Custom Folder") : raw
    }

    public nonisolated static func displayBreadcrumb(for url: URL) -> String {
        let raw = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanFolderName(for: url)
        if raw == "File Provider Storage" || raw == "com~apple~CloudDocs" {
            return name
        }
        let path = url.standardizedFileURL.path
        if FileManager.default.isUbiquitousItem(at: url) || path.contains("Mobile Documents") || path.contains("com~apple~CloudDocs") {
            return L("iCloud Drive › \(name)")
        }
        return L("Files › \(name)")
    }

    public nonisolated static func localizedBreadcrumb(
        url: URL,
        folderName: String,
        storedBreadcrumb: String
    ) -> String {
        let raw = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "File Provider Storage" {
            return L("On My iPhone")
        }
        if raw == "com~apple~CloudDocs" {
            return L("iCloud Drive")
        }
        let path = url.standardizedFileURL.path
        if storedBreadcrumb.hasPrefix("iCloud Drive › ") || path.contains("Mobile Documents") || path.contains("com~apple~CloudDocs") {
            return L("iCloud Drive › \(folderName)")
        }
        return L("Files › \(folderName)")
    }

    private nonisolated static func countVisibleRegularFiles(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        return items.filter { item in
            let name = item.lastPathComponent
            guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { return false }
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
            return vals?.isDirectory != true
        }.count
    }

    public nonisolated static func loadRecord(defaults: UserDefaults = LiveContainerEnvironment.sharedDefaults) -> SharedFolderRecord? {
        guard let data = defaults.data(forKey: recordDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SharedFolderRecord.self, from: data)
    }

    public nonisolated static func saveRecord(_ record: SharedFolderRecord, defaults: UserDefaults = LiveContainerEnvironment.sharedDefaults) {
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: recordDefaultsKey)
        }
    }

    public nonisolated static func clearRecord(defaults: UserDefaults = LiveContainerEnvironment.sharedDefaults) {
        defaults.removeObject(forKey: recordDefaultsKey)
    }

    // MARK: - Persistent Bookmark Helpers (iOS & LiveContainer Parity)

    public nonisolated static func createPersistentBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), !data.isEmpty {
            return data
        }
        // Fallback matching LiveContainer's `LCUtils.bookmarkForURL:` (`NSURLBookmarkCreationWithSecurityScope = 1 << 11`)
        let securityScopedFallback = URL.BookmarkCreationOptions(rawValue: 1 << 11)
        if let data = try? url.bookmarkData(
            options: securityScopedFallback,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), !data.isEmpty {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public nonisolated static func resolvePersistentBookmark(_ bookmarkData: Data, isStale: inout Bool) -> URL? {
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

// MARK: - LiveContainer `DocumentPicker.m` Runtime Bridge

/// Isolated Objective-C runtime bridge keeping `UIDocumentPickerViewController` working cleanly inside
/// LiveContainer without requiring manual per-app LiveContainer settings.
///
/// Uses `dladdr` image-path verification (`/System/Library/`, `/System/Cryptexes/`, `/usr/lib/`) to tell
/// genuinely exchanged Apple IMPs apart from unswizzled `TweakLoader` category methods—eliminating any
/// possibility of infinite self-recursion across LiveContainer versions and toggle combinations.
@MainActor
public enum LiveContainerDocumentPickerBridge {
    private static var didInstallHostFix = false

    public nonisolated static func imagePath(for imp: IMP) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(imp), &info) != 0,
              let fname = info.dli_fname else {
            return nil
        }
        return String(cString: fname)
    }

    public nonisolated static func isAppleSystemImplementation(_ imp: IMP) -> Bool {
        guard let path = imagePath(for: imp) else { return false }
        return path.contains("/System/Library/")
            || path.contains("/System/Cryptexes/")
            || path.contains("/usr/lib/")
    }

    /// Ensures `DOCConfiguration.setHostIdentifier:` receives LiveContainer's genuine signed host bundle ID
    /// (`lcMainBundle`) even when LiveContainer's `fixFilePickerNew` toggle is off, preventing silent
    /// `fileproviderd` rejections in both folder-open and file-export pickers.
    @discardableResult
    public static func installHostIdentifierFixIfNeeded() -> Bool {
        guard LiveContainerEnvironment.isRunningInLiveContainer else { return false }
        guard !didInstallHostFix else { return true }

        _ = UIDocumentPickerViewController.self
        var docClass: AnyClass? = NSClassFromString("DOCConfiguration")
        if docClass == nil {
            _ = dlopen("/System/Library/PrivateFrameworks/DocumentManagerCore.framework/DocumentManagerCore", RTLD_LAZY)
            docClass = NSClassFromString("DOCConfiguration")
        }
        guard let targetClass = docClass,
              let setHostMethod = class_getInstanceMethod(targetClass, NSSelectorFromString("setHostIdentifier:")) else {
            return false
        }
        if !isAppleSystemImplementation(method_getImplementation(setHostMethod)) {
            didInstallHostFix = true
            return true
        }
        let installed = installHostIdentifierFix(
            on: targetClass,
            hostBundleID: CustomSaveFolderManager.currentHostBundleIdentifier()
        )
        if installed {
            didInstallHostFix = true
        }
        return installed
    }

    @discardableResult
    static func installHostIdentifierFix(on targetClass: AnyClass, hostBundleID: String) -> Bool {
        let setHostSel = NSSelectorFromString("setHostIdentifier:")
        guard let method = class_getInstanceMethod(targetClass, setHostSel) else { return false }
        let origIMP = method_getImplementation(method)
        typealias SetHostIDIMP = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let callOrig = unsafeBitCast(origIMP, to: SetHostIDIMP.self)
        let resolvedHostID = hostBundleID as NSString
        let block: @convention(block) (AnyObject, NSString?) -> Void = { obj, _ in
            callOrig(obj, setHostSel, resolvedHostID)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    /// Builds a `UIDocumentPickerViewController` strictly in single-folder open-in-place mode (`[.folder]`,
    /// `asCopy: false`), bypassing LiveContainer `DocumentPicker.m`'s `[.item, .folder]` rewrite safely.
    public static func makeFolderPickerController(
        initialDirectoryURL: URL?,
        pickerClass: UIDocumentPickerViewController.Type = UIDocumentPickerViewController.self,
        isOriginalImplementation: (IMP) -> Bool = isAppleSystemImplementation
    ) -> UIDocumentPickerViewController {
        installHostIdentifierFixIfNeeded()

        let canonicalInitSel = NSSelectorFromString("initForOpeningContentTypes:asCopy:")
        let lcSwappedInitSel = NSSelectorFromString("hook_initForOpeningContentTypes:asCopy:")
        let controller: UIDocumentPickerViewController

        if let canonicalInitMethod = class_getInstanceMethod(pickerClass, canonicalInitSel),
           let origInitMethod = class_getInstanceMethod(pickerClass, lcSwappedInitSel),
           !isOriginalImplementation(method_getImplementation(canonicalInitMethod)),
           isOriginalImplementation(method_getImplementation(origInitMethod)),
           let metaClass = object_getClass(pickerClass),
           let allocMethod = class_getInstanceMethod(metaClass, NSSelectorFromString("alloc")) {
            typealias AllocIMP = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
            typealias InitContentTypesIMP = @convention(c) (
                UnsafeMutableRawPointer,
                Selector,
                NSArray,
                ObjCBool
            ) -> UnsafeMutableRawPointer?

            let callAlloc = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
            let callOrigInit = unsafeBitCast(method_getImplementation(origInitMethod), to: InitContentTypesIMP.self)
            let allocated = callAlloc(pickerClass, NSSelectorFromString("alloc"))
            let soleFolderTypes: NSArray = [UTType.folder] as NSArray
            if let initializedPtr = callOrigInit(allocated.toOpaque(), canonicalInitSel, soleFolderTypes, ObjCBool(false)) {
                controller = Unmanaged<UIDocumentPickerViewController>.fromOpaque(initializedPtr).takeRetainedValue()
            } else {
                controller = pickerClass.init(forOpeningContentTypes: [.folder])
            }
        } else {
            controller = pickerClass.init(forOpeningContentTypes: [.folder])
        }

        let canonicalMultiSel = NSSelectorFromString("setAllowsMultipleSelection:")
        let lcSwappedMultiSel = NSSelectorFromString("hook_setAllowsMultipleSelection:")
        if let canonicalMultiMethod = class_getInstanceMethod(pickerClass, canonicalMultiSel),
           let origMultiMethod = class_getInstanceMethod(pickerClass, lcSwappedMultiSel),
           !isOriginalImplementation(method_getImplementation(canonicalMultiMethod)),
           isOriginalImplementation(method_getImplementation(origMultiMethod)) {
            typealias SetBoolIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let callOrigSetMulti = unsafeBitCast(method_getImplementation(origMultiMethod), to: SetBoolIMP.self)
            callOrigSetMulti(controller, canonicalMultiSel, ObjCBool(false))
        } else {
            controller.allowsMultipleSelection = false
        }

        if let initialDirectoryURL {
            controller.directoryURL = initialDirectoryURL
        }
        return controller
    }
}

/// Native iOS Folder Picker (`UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`)
/// granting in-place Security-Scoped Folder access (never `asCopy`), with LiveContainer self-healing.
struct SaveFolderPickerSheet: UIViewControllerRepresentable {
    let initialDirectoryURL: URL?
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = LiveContainerDocumentPickerBridge.makeFolderPickerController(initialDirectoryURL: initialDirectoryURL)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                onPick(first)
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// Shared UI helper opening the active `downloadsDirectory` in iOS Files.app via `shareddocuments://`.
@MainActor
enum SaveFolderFilesLauncher {
    static func openActiveDownloadsFolder() {
        let rawPath = LiveContainerEnvironment.downloadsDirectory.path
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath
        let candidates: [URL] = [
            URL(string: "shareddocuments://\(rawPath)"),
            URL(string: "shareddocuments://\(encodedPath)"),
            URL(string: "shareddocuments://")
        ].compactMap { $0 }

        guard let primaryURL = candidates.first else { return }
        UIApplication.shared.open(primaryURL, options: [:]) { success in
            if !success, candidates.count > 1 {
                UIApplication.shared.open(candidates[1], options: [:], completionHandler: nil)
            }
        }
    }
}

/// Per-screen presentation state for `SaveLocationRow` and `.saveFolderPickerFlow(_:)`.
/// Scoped locally via `@State` so sibling tabs in `TabView` never collide on dialogs.
struct SaveFolderFlowState {
    struct PendingMove {
        let sourceDir: URL
        let fileCount: Int
        let destinationName: String
        let isResetToDefault: Bool
    }

    var isShowingPicker: Bool = false
    var pendingMove: PendingMove? = nil
}

/// Shared native `.insetGrouped` row for selecting, revealing, or resetting the Downloads save folder.
/// Used identically by `Downloads → Storage` (`LibraryVaultView`) and `Engine → Storage` (`EngineStatusView`).
struct SaveLocationRow: View {
    @Environment(\.dysprosiumTokens) private var tokens
    @Binding var flow: SaveFolderFlowState
    let accessibilityID: String
    var onFolderUpdated: (() -> Void)? = nil

    private var saveFolderManager = CustomSaveFolderManager.shared

    var body: some View {
        if case .defaultInternal = saveFolderManager.status {
            Button {
                flow.isShowingPicker = true
            } label: {
                rowContent(chevron: "chevron.right")
            }
            .foregroundStyle(Color.primary)
            .tint(Color.primary)
            .accessibilityIdentifier(accessibilityID)
        } else {
            Menu {
                switch saveFolderManager.status {
                case .defaultInternal:
                    EmptyView()
                case .customActive:
                    Button {
                        flow.isShowingPicker = true
                    } label: {
                        Label(L("Change Save Folder…"), systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        SaveFolderFilesLauncher.openActiveDownloadsFolder()
                    } label: {
                        Label(L("Show in iOS Files"), systemImage: "folder")
                    }
                    Divider()
                    Button(role: .destructive) {
                        let offer = saveFolderManager.resetToDefaultFolder()
                        if let src = offer.offerMoveFrom, offer.movableFileCount > 0 {
                            flow.pendingMove = SaveFolderFlowState.PendingMove(
                                sourceDir: src,
                                fileCount: offer.movableFileCount,
                                destinationName: L("App Storage"),
                                isResetToDefault: true
                            )
                        }
                        onFolderUpdated?()
                    } label: {
                        Label(L("Reset to Default Storage"), systemImage: "arrow.uturn.backward")
                    }
                case .needsHostGrant(let folderName, _, _):
                    Button {
                        flow.isShowingPicker = true
                    } label: {
                        Label(L("Grant Access to \"\(folderName)\"…"), systemImage: "folder.badge.person.crop")
                    }
                    Divider()
                    Button(role: .destructive) {
                        _ = saveFolderManager.resetToDefaultFolder()
                        onFolderUpdated?()
                    } label: {
                        Label(L("Reset to Default Storage"), systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                rowContent(chevron: "chevron.up.chevron.down")
            }
            .foregroundStyle(Color.primary)
            .tint(Color.primary)
            .accessibilityIdentifier(accessibilityID)
        }
    }

    @ViewBuilder
    private func rowContent(chevron: String) -> some View {
        HStack(spacing: 10) {
            Text(L("Save Location"))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Group {
                switch saveFolderManager.status {
                case .defaultInternal:
                    Text(L("App Storage"))
                        .foregroundStyle(Color.secondary)
                case .customActive(let url, let folderName, let breadcrumb):
                    Text(CustomSaveFolderManager.localizedBreadcrumb(url: url, folderName: folderName, storedBreadcrumb: breadcrumb))
                        .foregroundStyle(tokens.accent)
                case .needsHostGrant(let folderName, _, _):
                    Label(L("Link \"\(folderName)\""), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(tokens.statusWarning)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            Image(systemName: chevron)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }
}

/// Reusable folder-picker + one-shot migration + multi-host mismatch guard shared between
/// `LibraryVaultView`, `EngineStatusView`, and `BrowserWorkspaceView` (zero duplicated dialogs).
struct SaveFolderPickerFlowModifier: ViewModifier {
    private struct PendingMismatchConfirmation {
        let pickedURL: URL
        let pickedName: String
        let expectedName: String
    }

    @Binding var flow: SaveFolderFlowState
    var onFolderUpdated: (() -> Void)?

    @State private var saveFolderManager = CustomSaveFolderManager.shared
    @State private var pendingMismatch: PendingMismatchConfirmation?
    @State private var rejectedErrorMessage: String?

    private var moveDialogTitle: String {
        guard let offer = flow.pendingMove else { return "" }
        if offer.isResetToDefault {
            return L("Move \(offer.fileCount) Downloads Back to Default?")
        }
        return L("Move \(offer.fileCount) Existing Downloads?")
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.isShowingPicker) {
                SaveFolderPickerSheet(
                    initialDirectoryURL: saveFolderManager.suggestedPickerDirectoryURL,
                    onPick: { pickedURL in
                        flow.isShowingPicker = false
                        handlePick(pickedURL, forceSwitchSharedTarget: false)
                    },
                    onCancel: {
                        flow.isShowingPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .confirmationDialog(
                moveDialogTitle,
                isPresented: Binding(
                    get: { flow.pendingMove != nil },
                    set: { if !$0 { dismissMoveOffer() } }
                ),
                titleVisibility: .visible
            ) {
                if let offer = flow.pendingMove {
                    let moveLabel = offer.isResetToDefault
                        ? L("Move \(offer.fileCount) Files")
                        : L("Move \(offer.fileCount) Files to \(offer.destinationName)")
                    Button(moveLabel) {
                        let source = offer.sourceDir
                        flow.pendingMove = nil
                        Task { @MainActor in
                            _ = await saveFolderManager.moveExistingFiles(from: source)
                            onFolderUpdated?()
                        }
                    }
                    Button(L("Leave in Previous Folder"), role: .cancel) {
                        dismissMoveOffer()
                    }
                }
            } message: {
                if let offer = flow.pendingMove {
                    if offer.isResetToDefault {
                        Text(L("Files left in the previous folder remain safe in iOS Files."))
                    } else {
                        Text(L("Move existing files once so everything lives in \(offer.destinationName). Left-behind files remain untouched in their previous location."))
                    }
                }
            }
            .confirmationDialog(
                L("Different Folder Selected"),
                isPresented: Binding(
                    get: { pendingMismatch != nil },
                    set: { if !$0 { pendingMismatch = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let mismatch = pendingMismatch {
                    Button(L("Switch All Instances to \"\(mismatch.pickedName)\"")) {
                        let url = mismatch.pickedURL
                        pendingMismatch = nil
                        handlePick(url, forceSwitchSharedTarget: true)
                    }
                    Button(L("Pick \"\(mismatch.expectedName)\" Instead")) {
                        pendingMismatch = nil
                        flow.isShowingPicker = true
                    }
                    Button(L("Cancel"), role: .cancel) {
                        pendingMismatch = nil
                    }
                }
            } message: {
                if let mismatch = pendingMismatch {
                    Text(L("Another LiveContainer instance uses \"\(mismatch.expectedName)\". Pick the same folder to share one library, or switch all instances to \"\(mismatch.pickedName)\"."))
                }
            }
            .alert(
                L("Could Not Link Folder"),
                isPresented: Binding(
                    get: { rejectedErrorMessage != nil },
                    set: { if !$0 { rejectedErrorMessage = nil } }
                )
            ) {
                Button(L("OK"), role: .cancel) {
                    rejectedErrorMessage = nil
                }
            } message: {
                Text(rejectedErrorMessage ?? "")
            }
    }

    private func handlePick(_ url: URL, forceSwitchSharedTarget: Bool) {
        let outcome = saveFolderManager.adoptPickedFolder(url, forceSwitchSharedTarget: forceSwitchSharedTarget)
        switch outcome {
        case .linkedExistingSharedFolder:
            onFolderUpdated?()
        case .activated(let folderName, let offerMoveFrom, let count):
            onFolderUpdated?()
            if let source = offerMoveFrom, count > 0 {
                flow.pendingMove = SaveFolderFlowState.PendingMove(
                    sourceDir: source,
                    fileCount: count,
                    destinationName: folderName,
                    isResetToDefault: false
                )
            }
        case .confirmSwitchFromExpected(let pickedURL, let pickedName, let expectedName):
            pendingMismatch = PendingMismatchConfirmation(
                pickedURL: pickedURL,
                pickedName: pickedName,
                expectedName: expectedName
            )
        case .rejected(let message):
            rejectedErrorMessage = message
        }
    }

    private func dismissMoveOffer() {
        flow.pendingMove = nil
        saveFolderManager.dismissPendingMoveOffer()
        onFolderUpdated?()
    }
}

private struct SaveFolderPickerBoolAdapterModifier: ViewModifier {
    @Binding var isPresented: Bool
    var onFolderUpdated: (() -> Void)?
    @State private var pendingMove: SaveFolderFlowState.PendingMove?

    func body(content: Content) -> some View {
        content.modifier(
            SaveFolderPickerFlowModifier(
                flow: Binding(
                    get: { SaveFolderFlowState(isShowingPicker: isPresented, pendingMove: pendingMove) },
                    set: {
                        isPresented = $0.isShowingPicker
                        pendingMove = $0.pendingMove
                    }
                ),
                onFolderUpdated: onFolderUpdated
            )
        )
    }
}

extension View {
    func saveFolderPickerFlow(
        _ flow: Binding<SaveFolderFlowState>,
        onFolderUpdated: (() -> Void)? = nil
    ) -> some View {
        modifier(SaveFolderPickerFlowModifier(flow: flow, onFolderUpdated: onFolderUpdated))
    }

    func saveFolderPickerFlow(
        isPresented: Binding<Bool>,
        onFolderUpdated: (() -> Void)? = nil
    ) -> some View {
        modifier(SaveFolderPickerBoolAdapterModifier(isPresented: isPresented, onFolderUpdated: onFolderUpdated))
    }
}
