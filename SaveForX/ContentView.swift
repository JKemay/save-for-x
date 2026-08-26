import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloadManager: DownloadManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.blue)

                Text("Save for X")
                    .font(.largeTitle.bold())

                if let postURL = router.pendingPostURL {
                    VStack(spacing: 12) {
                        Text("Ready to save")
                            .font(.headline)
                        Text(postURL.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Button {
                            Task {
                                await downloadManager.download(postURL: postURL)
                            }
                        } label: {
                            Label("Download video", systemImage: "arrow.down.to.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloadManager.isDownloading)
                    }
                    .padding()
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text("Share an X post to this app to download its public video to Photos.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolver endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("https://…/v1/resolve", text: $downloadManager.resolverEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    Text("Use your deployed service, or your Mac's LAN address for local testing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let status = downloadManager.statusMessage {
                    Label(status, systemImage: downloadManager.statusIcon)
                        .font(.footnote)
                        .foregroundStyle(downloadManager.statusIsError ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Save for X")
        }
    }
}
