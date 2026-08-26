import Foundation
import Photos

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var statusIsError = false
    @Published var resolverEndpoint: String

    private let resolverEndpointKey = "resolverEndpoint"

    init() {
        resolverEndpoint = UserDefaults.standard.string(forKey: resolverEndpointKey)
            ?? "https://resolver.saveforx.example/v1/resolve"
    }

    var statusIcon: String {
        if isDownloading { return "arrow.down.circle" }
        return statusIsError ? "exclamationmark.triangle" : "checkmark.circle"
    }

    func download(postURL: URL) async {
        isDownloading = true
        statusMessage = "Finding the best available video…"
        statusIsError = false

        do {
            guard let endpoint = URL(string: resolverEndpoint),
                  endpoint.scheme == "https" || endpoint.scheme == "http" else {
                throw SaveForXError.invalidResolverEndpoint
            }

            UserDefaults.standard.set(resolverEndpoint, forKey: resolverEndpointKey)
            let resolved = try await ResolverClient(endpoint: endpoint).resolve(postURL: postURL)
            statusMessage = "Downloading video…"
            let (temporaryURL, _) = try await URLSession.shared.download(from: resolved.downloadURL)
            let filename = resolved.filename ?? "x-video.mp4"
            let photoURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: photoURL)
            try FileManager.default.copyItem(at: temporaryURL, to: photoURL)
            try await saveVideoToPhotos(at: photoURL)
            try? FileManager.default.removeItem(at: photoURL)
            statusMessage = "Saved to Photos."
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }

        isDownloading = false
    }

    private func saveVideoToPhotos(at fileURL: URL) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SaveForXError.photoPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }
}

struct ResolvedVideo: Decodable {
    let downloadURL: URL
    let filename: String?

    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case filename
    }
}

struct ResolverClient {
    let endpoint: URL

    func resolve(postURL: URL) async throws -> ResolvedVideo {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": postURL.absoluteString])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SaveForXError.resolverUnavailable
        }

        do {
            return try JSONDecoder().decode(ResolvedVideo.self, from: data)
        } catch {
            throw SaveForXError.invalidResolverResponse
        }
    }
}

enum SaveForXError: LocalizedError {
    case photoPermissionDenied
    case invalidResolverEndpoint
    case resolverUnavailable
    case invalidResolverResponse

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied:
            return "Photos permission is needed to save the video."
        case .invalidResolverEndpoint:
            return "Enter a valid resolver URL in the app."
        case .resolverUnavailable:
            return "The video resolver is unavailable right now."
        case .invalidResolverResponse:
            return "The resolver returned an invalid response."
        }
    }
}
