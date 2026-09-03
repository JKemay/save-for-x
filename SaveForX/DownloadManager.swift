import Foundation
import Photos

enum DownloadState: Equatable {
    case idle            // enqueued, not started by the user yet
    case waiting         // user started it, waiting for a concurrency slot
    case resolving
    case downloading(Double?)      // nil = length unknown, so indeterminate
    case saving
    case finished
    case failed(String)
    case cancelled

    /// True while the job is queued for a slot or actively working. Waiting
    /// counts as active too so the row keeps showing a spinner rather than
    /// looking idle while it sits behind the concurrency limit.
    var isActive: Bool {
        switch self {
        case .waiting, .resolving, .downloading, .saving:
            return true
        case .idle, .finished, .failed, .cancelled:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .waiting: return "Waiting…"
        case .resolving: return "Finding video…"
        case .downloading(let fraction):
            if let fraction {
                return "Downloading… \(Int((fraction * 100).rounded()))%"
            } else {
                return "Downloading…"
            }
        case .saving: return "Saving to Photos…"
        case .finished: return "Saved to Photos"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .waiting: return "clock"
        case .resolving: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .saving: return "square.and.arrow.down"
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    /// The known download fraction, for the UI's determinate progress bar.
    /// Nil whenever we're not downloading, or the length is unknown.
    var downloadFraction: Double? {
        if case .downloading(.some(let fraction)) = self {
            return fraction
        }
        return nil
    }
}

struct DownloadJob: Identifiable, Equatable {
    let id: UUID
    let postURL: URL
    var state: DownloadState
}

struct BatchEnqueueResult {
    let added: Int
    let duplicates: Int
    let invalid: Int

    /// Short one-line feedback for the UI, e.g. "Added 3 links · 1 duplicate · 2 not X post links". Return nil when nothing at all was parsed.
    var message: String? {
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added) link\(added == 1 ? "" : "s")") }
        if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s")") }
        if invalid > 0 { parts.append("\(invalid) not X post link\(invalid == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var resolverEndpoint: String

    let maxConcurrentDownloads = 3

    private let resolverEndpointKey = "resolverEndpoint"
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // Photos permission must be requested once for the whole app: several
    // shared links starting concurrently must not produce five separate
    // system prompts, so every job awaits this one cached authorization task.
    private var photoAuthorizationTask: Task<Bool, Never>?

    init() {
        resolverEndpoint = UserDefaults.standard.string(forKey: resolverEndpointKey)
            ?? "https://resolver.saveforx.example/v1/resolve"
    }

    var activeCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    var hasStartableJobs: Bool {
        jobs.contains { isStartable($0.state) }
    }

    var hasCompletedJobs: Bool {
        jobs.contains { isTerminal($0.state) }
    }

    var summary: String? {
        guard !jobs.isEmpty else { return nil }

        let downloading = activeRunningCount
        let waiting = jobs.filter { $0.state == .waiting }.count
        let saved = jobs.filter { $0.state == .finished }.count
        let failed = jobs.filter {
            if case .failed = $0.state { return true }
            return false
        }.count

        var parts: [String] = []
        if downloading > 0 { parts.append("\(downloading) downloading") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if saved > 0 { parts.append("\(saved) saved") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var activeRunningCount: Int {
        jobs.filter {
            switch $0.state {
            case .resolving, .downloading, .saving: return true
            default: return false
            }
        }.count
    }

    private func isStartable(_ state: DownloadState) -> Bool {
        switch state {
        case .idle, .failed, .cancelled: return true
        default: return false
        }
    }

    private func isTerminal(_ state: DownloadState) -> Bool {
        switch state {
        case .finished, .failed, .cancelled: return true
        default: return false
        }
    }

    @discardableResult
    func enqueue(postURL: URL) -> Bool {
        // Canonicalize before the duplicate check (and store the canonical
        // form on the job) so tracking-parameter variants of the same post,
        // e.g. `…/status/123?s=46` vs `…/status/123`, dedupe correctly.
        let canonicalURL = postURL.canonicalXPostURL

        // Dedupe: a link already in flight (or already saved) for this same
        // post shouldn't spawn a second job. A failed or cancelled job for
        // the same URL doesn't block a fresh attempt though.
        let isDuplicate = jobs.contains { job in
            guard job.postURL == canonicalURL else { return false }
            switch job.state {
            case .failed, .cancelled: return false
            default: return true
            }
        }
        guard !isDuplicate else { return false }

        let job = DownloadJob(id: UUID(), postURL: canonicalURL, state: .idle)
        jobs.append(job)
        start(job.id)
        return true
    }

    /// Lets a user paste a block of text containing several X post links at
    /// once and have them all queued (and download concurrently through the
    /// existing queue) instead of sharing them one at a time.
    @discardableResult
    func enqueue(pastedText: String) -> BatchEnqueueResult {
        let tokens = pastedText
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map(Self.trimLinkPunctuation)
            .filter { !$0.isEmpty }

        var added = 0
        var duplicates = 0
        var invalid = 0
        var seenCanonical: Set<URL> = []

        for token in tokens {
            guard let url = URL(string: token), url.isXPostURL else {
                if looksLikeLink(token) {
                    invalid += 1
                }
                continue
            }

            let canonical = url.canonicalXPostURL
            guard seenCanonical.insert(canonical).inserted else {
                duplicates += 1
                continue
            }

            if enqueue(postURL: url) {
                added += 1
            } else {
                duplicates += 1
            }
        }

        return BatchEnqueueResult(added: added, duplicates: duplicates, invalid: invalid)
    }

    /// A token counts as an intended link only if it looks like one; a plain
    /// word from a pasted sentence shouldn't be reported as an invalid link.
    private func looksLikeLink(_ token: String) -> Bool {
        let lowered = token.lowercased()
        return lowered.contains("://")
            || lowered.hasPrefix("x.com")
            || lowered.hasPrefix("twitter.com")
            || lowered.hasPrefix("www.")
    }

    /// Trim punctuation that commonly rides along with a pasted link:
    /// brackets/quotes from both ends, and trailing sentence punctuation
    /// (`.` `,` `;` `!`) from the end only — never from inside the URL.
    private static func trimLinkPunctuation(_ token: String) -> String {
        let wrapping = CharacterSet(charactersIn: "<>()[]\"'")
        let trailingOnly = CharacterSet(charactersIn: ".,;!")

        var slice = Substring(token)
        while let first = slice.unicodeScalars.first, wrapping.contains(first) {
            slice = slice.dropFirst()
        }
        while let last = slice.unicodeScalars.last, wrapping.contains(last) || trailingOnly.contains(last) {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    func start(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              isStartable(jobs[index].state) else { return }
        jobs[index].state = .waiting
        pump()
    }

    func startAll() {
        for job in jobs where isStartable(job.state) {
            start(job.id)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()

        if let index = jobs.firstIndex(where: { $0.id == id }) {
            switch jobs[index].state {
            case .idle, .waiting:
                jobs[index].state = .cancelled
            default:
                break
            }
        }
        pump()
    }

    func remove(_ id: UUID) {
        cancel(id)
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }

    func clearCompleted() {
        jobs.removeAll { isTerminal($0.state) }
    }

    private func pump() {
        while activeRunningCount < maxConcurrentDownloads,
              let next = jobs.first(where: { $0.state == .waiting }) {
            run(next.id)
        }
    }

    private func run(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .resolving
        tasks[id] = Task { [weak self] in
            await self?.perform(id)
        }
    }

    private func perform(_ id: UUID) async {
        defer {
            tasks[id] = nil
            pump()
        }

        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let postURL = job.postURL

        do {
            guard let endpoint = URL(string: resolverEndpoint),
                  endpoint.scheme == "https" || endpoint.scheme == "http" else {
                throw SaveForXError.invalidResolverEndpoint
            }

            UserDefaults.standard.set(resolverEndpoint, forKey: resolverEndpointKey)

            try Task.checkCancellation()
            let resolved = try await ResolverClient(endpoint: endpoint).resolve(postURL: postURL)

            // The resolver endpoint is whatever the user typed in, so nothing it
            // returns is trusted: an arbitrary scheme here would let it point at
            // file:// or similar rather than at a video to fetch.
            guard let downloadScheme = resolved.downloadURL.scheme?.lowercased(),
                  downloadScheme == "https" || downloadScheme == "http" else {
                throw SaveForXError.invalidResolverResponse
            }

            try Task.checkCancellation()
            setState(.downloading(nil), for: id)
            // The plain `download(from:)` reports nothing until it finishes, so
            // progress needs a per-task delegate instead.
            let progressDelegate = DownloadProgressDelegate { [weak self] fraction in
                Task { @MainActor in self?.updateProgress(fraction, for: id) }
            }
            let (temporaryURL, _) = try await URLSession.shared.download(
                from: resolved.downloadURL,
                delegate: progressDelegate
            )

            // Stage each job's file in its own subdirectory (named for the
            // job's id) so two concurrent downloads never collide over the
            // same staged filename.
            let stagingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let photoURL = stagingDirectory.appendingPathComponent(Self.safeFilename(resolved.filename))
            // Remove the whole staged directory whether or not the save
            // succeeds; it used to be left behind on every failure.
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }

            try FileManager.default.copyItem(at: temporaryURL, to: photoURL)

            try Task.checkCancellation()
            setState(.saving, for: id)
            try await saveVideoToPhotos(at: photoURL)
            setState(.finished, for: id)
        } catch is CancellationError {
            setState(.cancelled, for: id)
        } catch {
            if Task.isCancelled {
                setState(.cancelled, for: id)
            } else {
                setState(.failed(error.localizedDescription), for: id)
            }
        }
    }

    private func setState(_ state: DownloadState, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    /// Only writes while the job is still `.downloading`: a late progress
    /// callback arriving after cancellation or failure must not resurrect a
    /// finished job into a downloading state.
    private func updateProgress(_ fraction: Double?, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // Only while still downloading: a late callback arriving after a
        // cancel or failure must not resurrect a finished job.
        guard case .downloading(let current) = jobs[index].state else { return }
        // Hops onto the main actor aren't ordered, so an older callback can
        // land after a newer one; ignore anything that walks the bar backwards.
        if let fraction, let current, fraction < current { return }
        jobs[index].state = .downloading(fraction)
    }

    /// Reduce a resolver-supplied name to a single safe path component.
    ///
    /// `appendingPathComponent` happily accepts "../" segments, so passing the
    /// resolver's string straight through let it choose a path outside the
    /// temporary directory.
    static func safeFilename(_ proposed: String?) -> String {
        let fallback = "x-video.mp4"
        guard let proposed, !proposed.isEmpty else { return fallback }

        // Keep only the last component, then allow a conservative character set.
        let base = proposed.split(separator: "/").last.map(String.init) ?? ""
        let kept = base.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        let cleaned = String(kept).trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !cleaned.isEmpty, cleaned.count <= 128 else { return fallback }
        // Photos needs a video extension to import the file.
        return cleaned.lowercased().hasSuffix(".mp4") ? cleaned : cleaned + ".mp4"
    }

    private func saveVideoToPhotos(at fileURL: URL) async throws {
        let authorized = await photoAuthorization()
        guard authorized else {
            throw SaveForXError.photoPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }
    }

    /// Every concurrent job awaits this same task instead of calling
    /// `PHPhotoLibrary.requestAuthorization` itself, so downloading five
    /// shared links at once triggers one system prompt, not five.
    private func photoAuthorization() async -> Bool {
        if let existing = photoAuthorizationTask {
            return await existing.value
        }

        let task = Task<Bool, Never> {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return authorization == .authorized || authorization == .limited
        }
        photoAuthorizationTask = task
        return await task.value
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double?) -> Void
    private var lastReportedPercent: Int = -1

    init(onProgress: @escaping (Double?) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Servers that send no Content-Length report -1 here; the bar stays
        // indeterminate rather than showing a bogus percentage.
        guard totalBytesExpectedToWrite > 0 else {
            onProgress(nil)
            return
        }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        // Publish only on whole-percent changes: this fires many times a
        // second per task, and three concurrent downloads would otherwise
        // rerender the whole list constantly.
        let percent = Int((fraction * 100).rounded())
        guard percent != lastReportedPercent else { return }
        lastReportedPercent = percent
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Required by the protocol; the async download(from:delegate:) API
        // takes ownership of the finished file itself.
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
