// #637: the core package links and its runtime starts on macOS: create an isolate, tear it down.
// No network and no core call; the app itself does not reference the package yet.
import YtCore

var isolate: OpaquePointer?
var thread: OpaquePointer?
let created = graal_create_isolate(nil, &isolate, &thread)
guard created == 0, thread != nil else {
    fatalError("FAIL: graal_create_isolate returned \(created) (#637)")
}
let torn = graal_tear_down_isolate(thread)
guard torn == 0 else { fatalError("FAIL: graal_tear_down_isolate returned \(torn) (#637)") }
print("PASS: core package links and creates an isolate (#637)")
