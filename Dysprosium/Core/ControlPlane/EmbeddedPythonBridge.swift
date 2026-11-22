import Foundation
import Darwin

public struct RuntimeProbeSummary: Sendable, Equatable {
    public var isLiveContainerGuest: Bool
    public var cpythonAvailable: Bool
    public var cpythonVersion: String?
    public var ffmpegAvailable: Bool
    public var quickJSAvailable: Bool
    public var silentAudioActive: Bool
}

/// Self-contained `dlopen` CPython C-API bridge executing on a dedicated 8 MB stack `NSThread`.
/// Avoids compile-time `PythonKit` lock-in so Dysprosium compiles and runs its native Swift
/// transport engines immediately, lighting up `yt-dlp` automatically once `Python.xcframework`
/// is present inside `Frameworks/`.
public final class EmbeddedPythonBridge: NSObject, @unchecked Sendable {
    public static let shared = EmbeddedPythonBridge()

    private typealias PyInitializeExFn = @convention(c) (Int32) -> Void
    private typealias PyEvalSaveThreadFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias PyGILStateEnsureFn = @convention(c) () -> Int32
    private typealias PyGILStateReleaseFn = @convention(c) (Int32) -> Void
    private typealias PyGetVersionFn = @convention(c) () -> UnsafePointer<CChar>?
    private typealias PyImportImportModuleFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias PyObjectGetAttrStringFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias PyUnicodeFromStringFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias PyUnicodeAsUTF8Fn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias PyTupleNewFn = @convention(c) (Int) -> UnsafeMutableRawPointer?
    private typealias PyTupleSetItemFn = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Int32
    private typealias PyObjectCallObjectFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias PyErrPrintFn = @convention(c) () -> Void
    private typealias PyDecRefFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let lock = NSLock()
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var workerThread: Thread?
    private var dylibHandle: UnsafeMutableRawPointer?
    private var isInitialized = false
    private var cachedVersion: String?

    private override init() {
        super.init()
    }

    private func ensureWorkerThreadLocked() -> Thread {
        if let existing = workerThread, !existing.isCancelled, !existing.isFinished {
            return existing
        }
        let thread = Thread(target: self, selector: #selector(threadEntry), object: nil)
        thread.name = "dev.korolov.Dysprosium.control-plane-python"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 8 * 1024 * 1024
        workerThread = thread
        thread.start()
        readySemaphore.wait()
        return thread
    }

    @objc private func threadEntry() {
        autoreleasepool {
            let rl = RunLoop.current
            rl.add(Port(), forMode: .default)
            readySemaphore.signal()
            while !Thread.current.isCancelled {
                rl.run(mode: .default, before: .distantFuture)
            }
        }
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return locatePythonDylib() != nil
    }

    public var versionString: String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedVersion
    }

    public func extractTransferPlan(url: URL, cookieFilePath: String? = nil) async throws -> ResolvedTransferPlan {
        let targetThread: Thread? = lock.withLock {
            guard locatePythonDylib() != nil else { return nil }
            return ensureWorkerThreadLocked()
        }
        guard let targetThread else {
            throw NSError(
                domain: "Dysprosium.Python",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Embedded Python runtime not installed. Direct HTTP Range & HLS streams work natively; run scripts/bootstrap_frameworks.sh to enable yt-dlp webpage extraction."
                ]
            )
        }

        let jsonString: String = try await runOnWorkerThread(targetThread) {
            try self.invokeExtractorSync(url: url.absoluteString, cookiePath: cookieFilePath ?? "")
        }

        guard let data = jsonString.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "Dysprosium.Python",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON payload from dysprosium_extract.py"]
            )
        }

        guard (envelope["ok"] as? Bool) == true,
              let planDict = envelope["plan"],
              let planData = try? JSONSerialization.data(withJSONObject: planDict) else {
            let reason = (envelope["error"] as? String) ?? "Extractor failed"
            throw NSError(
                domain: "Dysprosium.Python",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }

        return try JSONDecoder().decode(ResolvedTransferPlan.self, from: planData)
    }

    // MARK: - Internal C-API Execution

    private func locatePythonDylib() -> UnsafeMutableRawPointer? {
        if let dylibHandle { return dylibHandle }
        let bundle = Bundle.main
        let candidates: [String] = [
            bundle.privateFrameworksURL?.appendingPathComponent("Python.framework/Python").path,
            bundle.bundleURL.appendingPathComponent("Frameworks/Python.framework/Python").path,
        ].compactMap { $0 }

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                dylibHandle = handle
                return handle
            }
        }
        return nil
    }

    private func bootstrapInterpreterIfNeeded(handle: UnsafeMutableRawPointer) throws {
        guard !isInitialized else { return }
        let bundle = Bundle.main
        let pythonRoot = bundle.bundleURL.appendingPathComponent("python")
        let stagedDir = stageExtractorScript()
        let writablePackages = LiveContainerEnvironment.writablePythonPackagesDirectory.path
        let bundledPackages = bundle.bundleURL.appendingPathComponent("python-packages").path
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        if let execPath = bundle.executablePath {
            setenv("DYSPROSIUM_EXECUTABLE_PATH", execPath, 1)
        }
        setenv("DYSPROSIUM_CACHE_DIR", cacheDir.path, 1)

        var pythonPaths: [String] = [stagedDir.path, writablePackages, bundledPackages]
        let libRoot = pythonRoot.appendingPathComponent("lib")
        if let verFolder = (try? FileManager.default.contentsOfDirectory(atPath: libRoot.path))?
            .first(where: { $0.hasPrefix("python3.") }) {
            let stdlib = libRoot.appendingPathComponent(verFolder).path
            let dynload = libRoot.appendingPathComponent(verFolder).appendingPathComponent("lib-dynload").path
            pythonPaths.append(contentsOf: [stdlib, dynload])
            setenv("PYTHONHOME", pythonRoot.path, 1)
        }
        setenv("PYTHONPATH", pythonPaths.joined(separator: ":"), 1)

        guard let pyInit: PyInitializeExFn = loadSymbol(handle, "Py_InitializeEx"),
              let pySave: PyEvalSaveThreadFn = loadSymbol(handle, "PyEval_SaveThread") else {
            throw NSError(
                domain: "Dysprosium.Python",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Missing Py_InitializeEx symbol in Python.framework"]
            )
        }

        pyInit(0)
        if let getVer: PyGetVersionFn = loadSymbol(handle, "Py_GetVersion"),
           let cVer = getVer() {
            cachedVersion = String(cString: cVer).components(separatedBy: " ").first
        }
        _ = pySave()
        isInitialized = true
    }

    private func invokeExtractorSync(url: String, cookiePath: String) throws -> String {
        lock.lock()
        guard let handle = locatePythonDylib() else {
            lock.unlock()
            throw NSError(
                domain: "Dysprosium.Python",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Embedded Python runtime not installed. Direct HTTP Range & HLS streams work natively; run scripts/bootstrap_frameworks.sh to enable yt-dlp webpage extraction."
                ]
            )
        }
        try bootstrapInterpreterIfNeeded(handle: handle)
        lock.unlock()

        guard let gilEnsure: PyGILStateEnsureFn = loadSymbol(handle, "PyGILState_Ensure"),
              let gilRelease: PyGILStateReleaseFn = loadSymbol(handle, "PyGILState_Release"),
              let importMod: PyImportImportModuleFn = loadSymbol(handle, "PyImport_ImportModule"),
              let getAttr: PyObjectGetAttrStringFn = loadSymbol(handle, "PyObject_GetAttrString"),
              let pyStr: PyUnicodeFromStringFn = loadSymbol(handle, "PyUnicode_FromString"),
              let pyUTF8: PyUnicodeAsUTF8Fn = loadSymbol(handle, "PyUnicode_AsUTF8"),
              let tupleNew: PyTupleNewFn = loadSymbol(handle, "PyTuple_New"),
              let tupleSet: PyTupleSetItemFn = loadSymbol(handle, "PyTuple_SetItem"),
              let callObj: PyObjectCallObjectFn = loadSymbol(handle, "PyObject_CallObject"),
              let errPrint: PyErrPrintFn = loadSymbol(handle, "PyErr_Print") else {
            throw NSError(domain: "Dysprosium.Python", code: -11, userInfo: [NSLocalizedDescriptionKey: "Incomplete CPython C-API table"])
        }
        let decRef: PyDecRefFn? = loadSymbol(handle, "Py_DecRef")

        let gil = gilEnsure()
        defer { gilRelease(gil) }

        guard let module = "dysprosium_extract".withCString({ importMod($0) }) else {
            errPrint()
            throw NSError(domain: "Dysprosium.Python", code: -12, userInfo: [NSLocalizedDescriptionKey: "Failed to import dysprosium_extract"])
        }
        defer { decRef?(module) }

        guard let fn = "resolve_url".withCString({ getAttr(module, $0) }) else {
            errPrint()
            throw NSError(domain: "Dysprosium.Python", code: -13, userInfo: [NSLocalizedDescriptionKey: "Missing resolve_url entrypoint"])
        }
        defer { decRef?(fn) }

        let args = tupleNew(2)
        defer { decRef?(args) }
        let arg0 = url.withCString { pyStr($0) }
        let arg1 = cookiePath.withCString { pyStr($0) }
        _ = tupleSet(args, 0, arg0) // steals reference
        _ = tupleSet(args, 1, arg1) // steals reference

        guard let resultObj = callObj(fn, args) else {
            errPrint()
            throw NSError(domain: "Dysprosium.Python", code: -14, userInfo: [NSLocalizedDescriptionKey: "resolve_url raised Python exception"])
        }
        defer { decRef?(resultObj) }

        guard let utf8 = pyUTF8(resultObj) else {
            throw NSError(domain: "Dysprosium.Python", code: -15, userInfo: [NSLocalizedDescriptionKey: "Non-UTF8 extractor response"])
        }
        return String(cString: utf8)
    }

    private func stageExtractorScript() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DysprosiumPython", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("dysprosium_extract.py")
        if let bundled = Bundle.main.url(forResource: "dysprosium_extract", withExtension: "py") {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
        return dir
    }

    private func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private func runOnWorkerThread<T: Sendable>(
        _ thread: Thread,
        _ block: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let item = BlockRunner {
                do {
                    continuation.resume(returning: try block())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            perform(#selector(executeRunner(_:)), on: thread, with: item, waitUntilDone: false)
        }
    }

    @objc private func executeRunner(_ runner: BlockRunner) {
        runner.run()
    }
}

private final class BlockRunner: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
