import AppKit

/// Handles quitting.
///
/// Without this the process simply died: a re-analysis in flight left two
/// folders on disk and only an in-memory note of which replaced which, so the
/// next launch had to reconstruct the relationship by guesswork. Quitting now
/// settles that decision first, and says so when a run is still going.
final class ChordAdminAppDelegate: NSObject, NSApplicationDelegate {

    /// Registered by the window once it exists. Weak so the delegate never keeps
    /// a manager alive past its window.
    weak var jobManager: JobManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.keepWindowOnScreen() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        keepWindowOnScreen()
    }

    /// A saved oversized window must not put search or the title bar off screen.
    private func keepWindowOnScreen() {
        for window in NSApplication.shared.windows where window.isVisible {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let constrained = Self.constrainedFrame(window.frame, visible: screen.visibleFrame)
            if constrained != window.frame { window.setFrame(constrained, display: true) }
        }
    }

    static func constrainedFrame(_ frame: CGRect, visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        return CGRect(x: max(visible.minX, min(frame.minX, visible.maxX - width)),
                      y: max(visible.minY, min(frame.minY, visible.maxY - height)),
                      width: width, height: height)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let jobManager else { return .terminateNow }

        if jobManager.isBusy, !confirmQuitDuringRun(jobManager) {
            return .terminateCancel
        }

        // Roll the supersede decision forward and stand down any stage still
        // recorded as running, so what is on disk already reflects reality.
        jobManager.cancelRun()
        jobManager.settleForTermination()
        // Log appends are queued off the main thread; let them land before the
        // process goes away, or the tail of a run is missing from logs.txt.
        LocalFileStore.flushLogs()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalAnalysisRuntime.shared.shutdown()
    }

    /// True when the user still wants to quit. Named as what is actually lost:
    /// a download in progress is minutes of work, not an abstraction.
    private func confirmQuitDuringRun(_ jobManager: JobManager) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An analysis is still running."
        alert.informativeText = jobManager.runningSongID != nil
            ? "Quitting stops it. Downloaded audio and finished stages are kept, so starting it again picks up where it left off."
            : "Quitting stops the local analysis. The existing chart and saved sections are kept."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
