/// No-op debug logger for DEC 2026 synchronized output.
///
/// Upstream's ``Terminal`` and ``TerminalView`` sprinkle `SyncDebug.log`
/// calls through the sync-output path. The type is not shipped in the
/// upstream repository (it lives in Miguel's local harness), so we provide
/// a stub that compiles away to nothing in release builds.
enum SyncDebug {
    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        // Uncomment the line below to see sync output timing in the console:
        // print("[SyncDebug] \(message())")
        #endif
    }
}
