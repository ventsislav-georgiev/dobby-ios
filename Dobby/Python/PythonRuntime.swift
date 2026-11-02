import Foundation

/// Embedded CPython for the a4k lanes (#482), the Apple counterpart of Android's Chaquopy
/// `PythonRuntime.java`. scripts/copy-python.sh puts Python.framework, the standard library and
/// the a4k tree into the bundle at build time; this starts the interpreter once and calls the
/// three functions of `dobby_apple.py` (search, subs, download), one JSON string in, one out.
///
/// The framework is dlopen'd, not linked: a build without the a4k tree (CI checks out this repo
/// alone) carries no Python, `shared` is nil and nothing else changes. That is also why the C API
/// is reached through dlsym with PEP 741's opaque `PyInitConfig` calls (Python 3.14), so no
/// header and no struct layout is compiled in.
///
/// Threading: never call on the main thread (#169: the scheme tasks answer on main, Python
/// works on a background queue). Any background thread may call; the GIL serialises them.
final class PythonRuntime {
    /// nil when this build has no Python or it failed to start (the reason is logged once).
    static let shared: PythonRuntime? = PythonRuntime()

    /// Wall time of dlopen plus interpreter start, for the cold-start figure.
    let startSeconds: Double

    private typealias Obj = OpaquePointer
    private let ensureGIL: @convention(c) () -> Int32
    private let releaseGIL: @convention(c) (Int32) -> Void
    private let importModule: @convention(c) (UnsafePointer<CChar>) -> Obj?
    private let getAttr: @convention(c) (Obj, UnsafePointer<CChar>) -> Obj?
    private let fromString: @convention(c) (UnsafePointer<CChar>) -> Obj?
    private let callOneArg: @convention(c) (Obj, Obj) -> Obj?
    private let asUTF8: @convention(c) (Obj) -> UnsafePointer<CChar>?
    private let decRef: @convention(c) (Obj?) -> Void
    private let printError: @convention(c) () -> Void

    private init?() {
        let started = Date()
        let bundle = Bundle.main
        guard let frameworks = bundle.privateFrameworksURL,
              let resources = bundle.resourceURL,
              let executable = bundle.executablePath else { return nil }
        let python = resources.appendingPathComponent("python")
        guard FileManager.default.fileExists(atPath: python.appendingPathComponent("app/dobby_apple.py").path) else {
            NSLog("PythonRuntime: this build carries no Python (scripts/copy-python.sh found no a4k tree)")
            return nil
        }
        let framework = frameworks.appendingPathComponent("Python.framework")
        guard let handle = dlopen(framework.appendingPathComponent("Python").path, RTLD_NOW | RTLD_GLOBAL) else {
            NSLog("PythonRuntime: dlopen failed: %@", String(cString: dlerror()))
            return nil
        }
        func fn<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }

        guard let create: @convention(c) () -> Obj? = fn("PyInitConfig_Create"),
              let setStr: @convention(c) (Obj, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = fn("PyInitConfig_SetStr"),
              let setInt: @convention(c) (Obj, UnsafePointer<CChar>, Int64) -> Int32 = fn("PyInitConfig_SetInt"),
              let getError: @convention(c) (Obj, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Int32 = fn("PyInitConfig_GetError"),
              let initialize: @convention(c) (Obj) -> Int32 = fn("Py_InitializeFromInitConfig"),
              let free: @convention(c) (Obj) -> Void = fn("PyInitConfig_Free"),
              let saveThread: @convention(c) () -> OpaquePointer? = fn("PyEval_SaveThread"),
              let ensureGIL: @convention(c) () -> Int32 = fn("PyGILState_Ensure"),
              let releaseGIL: @convention(c) (Int32) -> Void = fn("PyGILState_Release"),
              let importModule: @convention(c) (UnsafePointer<CChar>) -> Obj? = fn("PyImport_ImportModule"),
              let getAttr: @convention(c) (Obj, UnsafePointer<CChar>) -> Obj? = fn("PyObject_GetAttrString"),
              let fromString: @convention(c) (UnsafePointer<CChar>) -> Obj? = fn("PyUnicode_FromString"),
              let callOneArg: @convention(c) (Obj, Obj) -> Obj? = fn("PyObject_CallOneArg"),
              let asUTF8: @convention(c) (Obj) -> UnsafePointer<CChar>? = fn("PyUnicode_AsUTF8"),
              let decRef: @convention(c) (Obj?) -> Void = fn("Py_DecRef"),
              let printError: @convention(c) () -> Void = fn("PyErr_Print"),
              let runString: @convention(c) (UnsafePointer<CChar>) -> Int32 = fn("PyRun_SimpleString"),
              let config = create() else {
            NSLog("PythonRuntime: Python.framework lacks the 3.14 C API this needs")
            return nil
        }
        defer { free(config) }
        #if os(macOS)
        let home = framework.appendingPathComponent("Versions/Current").resolvingSymlinksInPath().path
        #else
        let home = python.path  // utils.sh installs the stdlib at python/lib/python3.x on iOS
        #endif
        // `executable` is load-bearing on iOS: the import system resolves each binary module's
        // .fwork stub against dirname(sys.executable), the bundle root. The environment is
        // ignored so nothing outside the app can redirect the interpreter, the bundle is never
        // written to (it is signed), and the app keeps its own signal handlers and stdio modes.
        let strings = [("home", home), ("executable", executable)]
        let ints: [(String, Int64)] = [("use_environment", 0), ("write_bytecode", 0), ("user_site_directory", 0),
                                       ("install_signal_handlers", 0), ("configure_c_stdio", 0)]
        let configured = strings.allSatisfy { setStr(config, $0.0, $0.1) == 0 } && ints.allSatisfy { setInt(config, $0.0, $0.1) == 0 }
        guard configured, initialize(config) == 0 else {
            var message: UnsafePointer<CChar>?
            _ = getError(config, &message)
            NSLog("PythonRuntime: start failed: %@", message.map { String(cString: $0) } ?? "unknown")
            return nil
        }
        // The a4k tree and its packages go first on sys.path (`pythonpath_env` is ignored once the
        // environment is). A JSON array of strings is a valid Python list literal, quotes escaped.
        let paths = ["app", "app_packages"].map { python.appendingPathComponent($0).path }
        guard let literal = try? JSONSerialization.data(withJSONObject: paths, options: .withoutEscapingSlashes),
              runString("import sys; sys.path[:0] = " + String(decoding: literal, as: UTF8.self)) == 0 else {
            NSLog("PythonRuntime: sys.path setup failed")
            return nil
        }
        _ = saveThread()  // hand the GIL back; every call takes it with PyGILState_Ensure
        (self.ensureGIL, self.releaseGIL, self.importModule, self.getAttr) = (ensureGIL, releaseGIL, importModule, getAttr)
        (self.fromString, self.callOneArg, self.asUTF8, self.decRef, self.printError) = (fromString, callOneArg, asUTF8, decRef, printError)
        startSeconds = Date().timeIntervalSince(started)
    }

    /// `dobby_apple.<function>(json)`. nil when Python raised; the traceback goes to stderr.
    func call(_ function: String, _ json: String) -> String? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let gil = ensureGIL()
        defer { releaseGIL(gil) }
        guard let module = importModule("dobby_apple") else { printError(); return nil }
        defer { decRef(module) }
        guard let callable = getAttr(module, function) else { printError(); return nil }
        defer { decRef(callable) }
        guard let argument = fromString(json) else { printError(); return nil }
        defer { decRef(argument) }
        guard let result = callOneArg(callable, argument) else { printError(); return nil }
        defer { decRef(result) }
        guard let utf8 = asUTF8(result) else { printError(); return nil }
        return String(cString: utf8)
    }
}

#if DEBUG
/// The #482 spike, run instead of the app when DOBBY_PYTHON_SPIKE is set (PythonSpikeHook.c):
/// one full search and one subtitle search with no credentials, three subs.sab.bz downloads
/// (the RAR route), counts to stdout, then exit. Debug builds only.
@_cdecl("dobby_python_spike")
func dobbyPythonSpike() {
    func log(_ line: String) { print("PYSPIKE " + line); fflush(stdout) }
    func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    func parse(_ text: String?) -> [String: Any] {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }
    func tally(_ rows: [[String]], _ key: (([String]) -> String)) -> String {
        Dictionary(grouping: rows, by: key).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
    }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { done.signal() }
        let launched = Date()
        guard let py = PythonRuntime.shared else { log("FAIL no interpreter"); return }
        log(String(format: "interpreter start %.3fs", py.startSeconds))
        var t = Date()
        let info = parse(py.call("info", "{}"))
        log(String(format: "ready %.3fs (imports %.3fs) python=%@ openssl=%@", Date().timeIntervalSince(launched),
                   Date().timeIntervalSince(t), "\(info["version"] ?? "?")", "\(info["openssl"] ?? "?")"))

        t = Date()
        let search = parse(py.call("search", json(["type": "movie", "imdb": "tt0063350", "title": "Night of the Living Dead",
                                                   "year": "1968", "timeout": 40])))
        let searchRows = search["rows"] as? [[String]] ?? []
        log(String(format: "search %.1fs providers=%@ rows=%d by provider: %@", Date().timeIntervalSince(t),
                   "\(search["providers"] ?? "?")", searchRows.count, tally(searchRows) { $0.count > 4 ? $0[4] : "?" }))

        let profile = NSTemporaryDirectory() + "a4k-subs-spike"
        // No credentials: OpenSubtitles, subdl and subsource stay off (SubtitlesLane.settingsJson).
        let settings = ["general.timeout": "20", "general.results_limit": "200", "general.auto_search": "false",
                        "general.auto_download": "false", "bsplayer.enabled": "false", "podnadpisi.enabled": "true",
                        "addic7ed.enabled": "true", "subssabbz.enabled": "true", "subsunacs.enabled": "true",
                        "opensubtitles.enabled": "false", "subdl.enabled": "false", "subsource.enabled": "false"]
        t = Date()
        let subs = parse(py.call("subs", json(["profileDir": profile, "settings": settings, "type": "movie", "imdb": "tt0133093",
                                               "title": "The Matrix", "year": "1999", "filename": "", "languages": "bg,en"])))
        let subRows = subs["rows"] as? [[String]] ?? []
        log(String(format: "subs %.1fs rows=%d by service/lang: %@", Date().timeIntervalSince(t), subRows.count,
                   tally(subRows) { "\($0[0])/\($0[1])" }))

        for row in subRows.filter({ $0[0] == "subssabbz" }).prefix(3) {
            let result = parse(py.call("download", json(["profileDir": profile, "settings": settings,
                                                         "serviceName": row[0], "actionArgs": row[3]])))
            let file = result["file"] as? String ?? ""
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
            log("download subssabbz bytes=\(size) file=\((file as NSString).lastPathComponent) error=\(result["error"] ?? "")")
        }
    }
    done.wait()
    exit(0)
}
#endif
