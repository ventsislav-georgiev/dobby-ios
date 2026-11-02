import Foundation

/// Embedded CPython for the a4k lanes (#482), the Apple counterpart of Android's Chaquopy
/// `PythonRuntime.java`. scripts/copy-python.sh puts Python.framework, the standard library and
/// the a4k tree into the bundle at build time; this starts the interpreter once and calls the
/// functions of `dobby_apple.py` (search, search_partial, subs, download), one JSON string in, one
/// out. The a4k lanes (Dobby/Web/A4kLane.swift, #483) are the callers.
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
    /// The first touch STARTS the interpreter (0.1 to 0.6 s): never from the main thread.
    static let shared: PythonRuntime? = PythonRuntime()

    /// #483: this bundle carries the a4k tree. A file check that starts nothing, so the main thread
    /// may ask it (the window.Dobby.a4k literal is built there).
    static var bundled: Bool {
        Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(appGlue).path) } ?? false
    }

    private static let appGlue = "python/app/dobby_apple.py"

    /// #483: pays the start off the main thread before the page's first a4k call, and runs `failed`
    /// on main when the interpreter would not start, so the advertised flag can be taken back.
    static func warmUp(failed: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            if shared == nil { DispatchQueue.main.async(execute: failed) }
        }
    }

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
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent(Self.appGlue).path) else {
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
