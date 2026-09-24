import Cocoa

guard acquireSingleInstanceLock() else {
    fputs("QuickMemo is already running.\n", stderr)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
