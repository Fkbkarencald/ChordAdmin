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

    /// True when the user still wants to quit. Named as what is actually lost:
    /// a download in progress is minutes of work, not an abstraction.
    private func confirmQuitDuringRun(_ jobManager: JobManager) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An analysis is still running."
        alert.informativeText = jobManager.runningSongID != nil
            ? "Quitting stops it. Downloaded audio and finished stages are kept, so starting it again picks up where it left off."
            : "Quitting stops the beat re-detection. The existing chart is kept."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
