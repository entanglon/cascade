import AppKit

final class TerminationHandler: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // TDLibKit's C++ core does not have a graceful Swift-side shutdown hook.
        // Calling exit(0) triggers C++ destructors and LLVM profiling while the 
        // background receive thread is still running, causing an EXC_BAD_ACCESS.
        // _exit(0) instantly kills the process at the kernel level, bypassing 
        // the teardown race safely.
        _exit(0)
    }
}
