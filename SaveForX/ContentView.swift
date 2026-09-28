import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var pastedLinks: String = ""
    @State private var addFeedback: String?

    var body: some View {
        NavigationStack {
            // One sectioned List rather than a List nested in a ScrollView:
            // nesting two scroll views forced the queue into a fixed-height
            // window and made the scroll gestures compete.
            List {
                addLinksSection
                queueSection
                resolverEndpointSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Save for X")
        }
    }

    private var addLinksSection: some View {
        Section {
            TextField("Paste one or more X post links", text: $pastedLinks, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack(spacing: 12) {
                Button {
                    if let text = UIPasteboard.general.string {
                        pastedLinks = pastedLinks.isEmpty ? text : pastedLinks + "\n" + text
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    let result = downloadManager.enqueue(pastedText: pastedLinks)
                    addFeedback = result.message
                    // Only clear the field when something was queued, so a
                    // typo stays on screen to be fixed rather than vanishing.
                    if result.added > 0 {
                        pastedLinks = ""
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedLinks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let addFeedback {
                Text(addFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Add links")
        } footer: {
            Text("Paste several links at once — one per line, or separated by spaces or commas. Up to \(downloadManager.maxConcurrentDownloads) download at the same time; the rest wait their turn.")
        }
    }

    private var queueSection: some View {
        Section {
            if downloadManager.jobs.isEmpty {
                Text("Share an X post to this app, or paste links above, to download their public videos to Photos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(downloadManager.jobs) { job in
                    jobRow(job)
                        .swipeActions {
                            Button(role: .destructive) {
                                downloadManager.remove(job.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }

                HStack(spacing: 12) {
                    Button {
                        downloadManager.startAll()
                    } label: {
                        Label("Download all", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!downloadManager.hasStartableJobs)

                    Button {
                        downloadManager.clearCompleted()
                    } label: {
                        Label("Clear completed", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!downloadManager.hasCompletedJobs)
                }
            }
        } header: {
            HStack {
                Text("Queue")
                Spacer()
                if let summary = downloadManager.summary {
                    Text(summary)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(spacing: 12) {
            if job.state.isActive && job.state.downloadFraction == nil {
                ProgressView()
            } else {
                Image(systemName: job.state.icon)
                    .foregroundStyle(isFailed(job.state) ? .red : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(job.postURL.absoluteString)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let fraction = job.state.downloadFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }

                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(isFailed(job.state) ? .red : .secondary)
            }

            Spacer()

            switch job.state {
            case .idle:
                Button {
                    downloadManager.start(job.id)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
            case .waiting, .resolving, .downloading, .saving:
                Button {
                    downloadManager.cancel(job.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            case .failed, .cancelled:
                Button {
                    downloadManager.start(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            case .finished:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private func isFailed(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var resolverEndpointSection: some View {
        Section {
            TextField("https://…/v1/resolve", text: $downloadManager.resolverEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("Resolver endpoint")
        } footer: {
            Text("Use your deployed service, or your Mac's LAN address for local testing.")
        }
    }
}
