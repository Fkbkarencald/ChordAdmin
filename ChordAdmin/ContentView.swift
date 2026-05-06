//
//  ContentView.swift
//  ChordAdmin
//
//  Created by Frankie Benjamin on 6/5/2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var jobManager = JobManager()
    @State private var urlInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("ChordAdmin")
                .font(.title)
                .bold()

            // URL input + Start button
            HStack {
                TextField("YouTube URL", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(jobManager.isRunning)

                Button("Start") {
                    Task { await jobManager.startJob(url: urlInput) }
                }
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || jobManager.isRunning)
                .buttonStyle(.borderedProminent)
            }

            // Status + paths + error
            if let job = jobManager.currentJob {
                HStack(spacing: 8) {
                    Text("Status:")
                        .fontWeight(.semibold)
                    StatusBadge(status: job.status)
                }

                if let errorMsg = job.errorMessage {
                    Text(errorMsg)
                        .foregroundColor(.red)
                        .font(.callout)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let origPath = job.originalAudioPath {
                    PathRow(label: "Original audio:", path: origPath, playable: true)
                }

                if let wavPath = job.analysisWavPath {
                    PathRow(label: "Analysis WAV:", path: wavPath, playable: true)
                }
            }

            // Log output
            HStack {
                Text("Log output")
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jobManager.logOutput, forType: .string)
                } label: {
                    Label("Copy Logs", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .disabled(jobManager.logOutput.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(jobManager.logOutput.isEmpty ? "(no output yet)" : jobManager.logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3))
                )
                .onChange(of: jobManager.logOutput) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - Sub-views

private struct StatusBadge: View {
    let status: JobStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color(for: status).opacity(0.15))
            .foregroundColor(color(for: status))
            .clipShape(Capsule())
    }

    private func color(for status: JobStatus) -> Color {
        switch status {
        case .pending:       return .gray
        case .checkingTools: return .blue
        case .downloading:   return .orange
        case .converting:    return .purple
        case .completed:     return .green
        case .failed:        return .red
        }
    }
}

private struct PathRow: View {
    let label: String
    let path: String
    var playable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                if playable {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        Label("Play", systemImage: "play.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview {
    ContentView()
}
