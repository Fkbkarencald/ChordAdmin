import SwiftUI

struct LocalAnalysisStatusView: View {
    @ObservedObject var runtime = LocalAnalysisRuntime.shared
    @ObservedObject var environment: EnvironmentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(runtime.label, systemImage: "desktopcomputer")
                .scaledFont(size: 15, weight: .semibold, relativeTo: .headline)
            Text("Beat detection, chord analysis and chart preparation run on this Mac. Internet is used for TheStageBee and obtaining new recordings.")
                .scaledFont(size: 12, relativeTo: .body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = runtime.lastFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .scaledFont(size: 12, relativeTo: .body).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let tools = environment.tools {
                ForEach(tools.statuses) { status in
                    HStack {
                        Image(systemName: status.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(status.isAvailable ? .green : .orange)
                        Text(status.tool.rawValue)
                        Spacer()
                        Text(status.version ?? "Unavailable").foregroundStyle(.secondary).lineLimit(1)
                    }.scaledFont(size: 11, relativeTo: .caption)
                }
            }
            HStack {
                Button("Check local analysis") { Task { _ = await runtime.recover(); await environment.refresh() } }
                    .disabled(runtime.state == .starting)
                if let log = runtime.logURL {
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                }
            }
            Text("Already downloaded songs can be analysed without an internet connection. Publishing and reviewing cloud imports still need TheStageBee.")
                .scaledFont(size: 10.5, relativeTo: .caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 360)
    }
}
