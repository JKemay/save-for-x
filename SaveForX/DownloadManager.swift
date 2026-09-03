import Foundation
import Photos

/// Codable is synthesized automatically for this enum (SE-0295 lets an enum
/// with associated values conform to Codable as long as every associated
/// value is Codable too), so the persisted queue can round-trip a job's
/// state without any hand-written encode/decode here.
enum DownloadState: Equatable, Codable {
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

struct DownloadJob: Identifiable, Equatable, Codable {
    let id: UUID
    let postURL: URL
    var state: DownloadState
    /// Where the resolved video is staged, once resolving succeeds. Nil
    /// until then. Persisted (unlike the old in-memory-only staging path)
    /// so a relaunched app can find — or look for — the file without
    /// re-resolving, and so the background downloader's delegate can move
    /// the finished transfer into place even if it runs before the rest of
    /// this job's in-memory state exists.
    var destination: URL?
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

/// Where everything that must outlive app termination lives: the system may
/// purge `temporaryDirectory` while the app isn't running (and a background
/// transfer can easily outlast that), but Application Support is preserved
/// across launches, so staged files and the persisted queue both go here.
private enum PersistentStorage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SaveForX", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Per-job staging subdirectories live under here, named for the job's
    /// id, so concurrent jobs never collide over the same staged filename.
    static let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
    static let queueFile = root.appendingPathComponent("queue.json")
    static let destinationsFile = root.appendingPathComponent("downloader-destinations.json")
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var resolverEndpoint: String

    let maxConcurrentDownloads = 3

    private let resolverEndpointKey = "resolverEndpoint"
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private let downloader = BackgroundDownloader()

    // Photos permission must be requested once for the whole app: several
    // shared links starting concurrently must not produce five separate
    // system prompts, so every job awaits this one cached authorization task.
    private var photoAuthorizationTask: Task<Bool, Never>?

    init() {
        resolverEndpoint = UserDefaults.standard.string(forKey: resolverEndpointKey)
            ?? "https://resolver.saveforx.example/v1/resolve"
        jobs = Self.loadPersistedJobs()

        downloader.events = self
        // Instantiate the background session now rather than lazily on the
        // first download: if the system relaunched this process to service
        // background-transfer events, the session's delegate has to exist
        // immediately to receive them.
        downloader.activate()

        // Reconcile the persisted queue against reality (still-running
        // transfers, files that finished staging with nothing left to
        // receive them, genuinely interrupted jobs) once the session can
        // report its outstanding tasks.
        Task { @MainActor [weak self] in
            await self?.reconcileAfterLaunch()
        }
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

        let job = DownloadJob(id: UUID(), postURL: canonicalURL, state: .idle, destination: nil)
        jobs.append(job)
        saveQueue()
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
        setState(.waiting, for: id)
        pump()
    }

    func startAll() {
        for job in jobs where isStartable(job.state) {
            start(job.id)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        // Also cancels the URLSession task, if any: once a job has reached
        // `.downloading`, `perform(_:)` has already returned, so cancelling
        // the resolver-phase `Task` above no longer has anything to stop.
        downloader.cancel(jobID: id)

        if let index = jobs.firstIndex(where: { $0.id == id }) {
            switch jobs[index].state {
            case .idle, .waiting:
                setState(.cancelled, for: id)
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
        saveQueue()
    }

    func clearCompleted() {
        jobs.removeAll { isTerminal($0.state) }
        saveQueue()
    }

    private func pump() {
        while activeRunningCount < maxConcurrentDownloads,
              let next = jobs.first(where: { $0.state == .waiting }) {
            run(next.id)
        }
    }

    private func run(_ id: UUID) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        setState(.resolving, for: id)
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

        // Tracks whether this attempt created a staging directory, so a
        // failure here (before the transfer is handed off) can clean it up;
        // once the download is handed to `downloader`, the directory must
        // survive this function returning; it's removed later by whichever
        // of `downloadFinished`/`downloadFailed`/reconciliation ends the job.
        var createdStagingDirectory: URL?

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

            // Stage each job's file in its own subdirectory (named for the
            // job's id) so two concurrent downloads never collide over the
            // same staged filename. This now lives under Application Support
            // rather than `temporaryDirectory`: the system can purge tmp
            // while the app isn't running, and a background transfer must
            // leave a file that's still there whenever the app next runs.
            let stagingDirectory = PersistentStorage.stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            createdStagingDirectory = stagingDirectory
            let photoURL = stagingDirectory.appendingPathComponent(Self.safeFilename(resolved.filename))

            try Task.checkCancellation()
            // Hand the transfer to the background session and return without
            // awaiting it: the bytes now move on a system daemon, so this
            // job stays `.downloading(nil)` and progress/completion arrive
            // later through `BackgroundDownloaderDelegate`, which is what
            // lets the transfer survive the app being suspended or even
            // terminated.
            beginDownloading(id, destination: photoURL)
            downloader.start(jobID: id, from: resolved.downloadURL, to: photoURL)
        } catch is CancellationError {
            if let createdStagingDirectory { try? FileManager.default.removeItem(at: createdStagingDirectory) }
            setState(.cancelled, for: id)
        } catch {
            if let createdStagingDirectory { try? FileManager.default.removeItem(at: createdStagingDirectory) }
            if Task.isCancelled {
                setState(.cancelled, for: id)
            } else {
                setState(.failed(error.localizedDescription), for: id)
            }
        }
    }

    /// Records the staged destination and moves the job into `.downloading`
    /// in one write, so `saveQueue()` only fires once for the transition.
    private func beginDownloading(_ id: UUID, destination: URL) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].destination = destination
        jobs[index].state = .downloading(nil)
        saveQueue()
    }

    private func setState(_ state: DownloadState, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        saveQueue()
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
        saveQueue()
    }

    /// Removes a job's staging subdirectory (see `PersistentStorage`) once
    /// it's been saved or has failed; the old behavior of never leaving
    /// staged files behind, now against Application Support instead of tmp.
    private func cleanupStaging(for id: UUID) {
        let directory = PersistentStorage.stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Shared by the normal `downloadFinished` path and launch reconciliation:
    /// saves the staged file to Photos, resolves the job to `.finished` or
    /// `.failed`, cleans up its staging directory either way, and frees the
    /// concurrency slot.
    private func finishSaving(_ id: UUID, at fileURL: URL) async {
        do {
            try await saveVideoToPhotos(at: fileURL)
            setState(.finished, for: id)
        } catch {
            setState(.failed(error.localizedDescription), for: id)
        }
        cleanupStaging(for: id)
        pump()
    }

    /// Reconciles the persisted queue against reality after a fresh launch —
    /// a normal cold start, or a relaunch the system triggered to service
    /// the background session:
    /// - a job that was `.resolving`/`.downloading` with a matching task
    ///   still running is put back to `.downloading(nil)`; progress resumes
    ///   via callbacks.
    /// - a job that was `.downloading` with no task but a staged file
    ///   already at its destination is moved to `.saving` and finished.
    /// - a job that was `.resolving`/`.downloading` with neither a task nor
    ///   a file was genuinely interrupted (e.g. the process was killed
    ///   outright) and is marked `.failed` so the retry button offers it.
    /// - `.saving` re-attempts the Photos save if the file is present, else
    ///   the same failure.
    /// - `.waiting`/`.idle` jobs are left as-is for `pump()` to pick up.
    private func reconcileAfterLaunch() async {
        let runningIDs = await downloader.runningJobIDs()

        for job in jobs {
            switch job.state {
            case .resolving, .downloading:
                if runningIDs.contains(job.id) {
                    setState(.downloading(nil), for: job.id)
                } else if let destination = job.destination,
                          FileManager.default.fileExists(atPath: destination.path) {
                    setState(.saving, for: job.id)
                    Task { [weak self] in await self?.finishSaving(job.id, at: destination) }
                } else {
                    setState(.failed(SaveForXError.downloadInterrupted.localizedDescription), for: job.id)
                }
            case .saving:
                if let destination = job.destination,
                   FileManager.default.fileExists(atPath: destination.path) {
                    Task { [weak self] in await self?.finishSaving(job.id, at: destination) }
                } else {
                    setState(.failed(SaveForXError.downloadInterrupted.localizedDescription), for: job.id)
                }
            case .waiting, .idle, .finished, .failed, .cancelled:
                continue
            }
        }

        pump()
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

    /// Bridges to SwiftUI's `.backgroundTask(.urlSession(...))`: awaits the
    /// background session's finish-events callback so the app is kept alive
    /// long enough for pending transfer events to be delivered, then lets
    /// the scene modifier return and the system suspend the app again.
    func awaitBackgroundSessionEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            downloader.awaitFinishedEvents { continuation.resume() }
        }
    }

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: PersistentStorage.queueFile, options: .atomic)
    }

    private static func loadPersistedJobs() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: PersistentStorage.queueFile) else { return [] }
        return (try? JSONDecoder().decode([DownloadJob].self, from: data)) ?? []
    }
}

extension DownloadManager: BackgroundDownloaderDelegate {
    func downloadProgressed(jobID: UUID, fraction: Double?) {
        updateProgress(fraction, for: jobID)
    }

    /// The file is already at its destination by the time this fires (see
    /// `BackgroundDownloader.urlSession(_:downloadTask:didFinishDownloadingTo:)`).
    func downloadFinished(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), let destination = job.destination else {
            pump()
            return
        }
        setState(.saving, for: jobID)
        Task { [weak self] in
            await self?.finishSaving(jobID, at: destination)
        }
    }

    func downloadFailed(jobID: UUID, error: Error, cancelled: Bool) {
        setState(cancelled ? .cancelled : .failed(error.localizedDescription), for: jobID)
        cleanupStaging(for: jobID)
        pump()
    }
}

/// Events a `BackgroundDownloader` reports back to whoever owns its jobs.
/// Marked `@MainActor` so every requirement is main-actor-isolated: the
/// downloader's delegate callbacks arrive on a background queue and must
/// hop over before calling any of these, and `DownloadManager` — already a
/// main-actor type — can then conform without any extra isolation dance.
@MainActor
protocol BackgroundDownloaderDelegate: AnyObject {
    func downloadProgressed(jobID: UUID, fraction: Double?)
    /// The file is already at its destination when this fires.
    func downloadFinished(jobID: UUID)
    func downloadFailed(jobID: UUID, error: Error, cancelled: Bool)
}

/// Downloads files through a background `URLSession` so transfers keep
/// moving while the app is suspended, and — per Apple's background-transfer
/// design — even survive the app being terminated by the system; a relaunch
/// simply reconnects to the same session rather than starting a new one.
///
/// Unlike the old `ProgressiveDownloader`, this can't bridge the transfer to
/// a single `async` call: a `CheckedContinuation` lives only as long as the
/// process that created it, and the whole point here is to outlive that
/// process. So `start` fires the task and returns immediately, and results
/// arrive later through `events`, which may be a delegate object in an
/// entirely new process from the one that called `start`.
final class BackgroundDownloader: NSObject, @unchecked Sendable {
    /// com.saveforx.app.downloads — the background session's identifier.
    /// Shared as a constant (rather than a string literal in two places) so
    /// the session's own config and the app's `.backgroundTask(.urlSession(...))`
    /// registration can't drift apart.
    static let sessionIdentifier = "com.saveforx.app.downloads"

    /// Every call hops to the main actor before touching this, since
    /// delegate callbacks below arrive on the session's own background
    /// delegate queue and `events` is main-actor-isolated state.
    weak var events: BackgroundDownloaderDelegate?

    // `destinations`, `lastPercent`, `moveErrors`, and `backgroundCompletionHandler`
    // are all touched both from callers on the main actor (`start`,
    // `awaitFinishedEvents`) and from delegate callbacks on the session's
    // own background queue, so every access goes through this lock.
    private let lock = NSLock()

    // Job -> staged destination, persisted to disk. `didFinishDownloadingTo`
    // must move the file synchronously before it returns — the system
    // deletes the temporary file as soon as that method does — and it may
    // run in a freshly relaunched process where none of DownloadManager's
    // in-memory job state exists yet, so this can't be an in-memory-only
    // dictionary the way the old transfer bookkeeping was.
    private var destinations: [String: URL]

    // Progress throttle state, keyed by job id rather than task identifier:
    // task identifiers aren't stable across a relaunch, but the job id
    // (stored in `taskDescription`) is.
    private var lastPercent: [String: Int] = [:]

    // A move failure inside `didFinishDownloadingTo` has to be remembered
    // and reported once `didCompleteWithError` fires right after it — the
    // same problem the old `Transfer.moveResult` solved.
    private var moveErrors: [String: Error] = [:]

    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override init() {
        destinations = Self.loadDestinations()
        super.init()
    }

    /// Forces the background session — and so its delegate — to exist. Must
    /// be called during app launch rather than left to lazy creation on the
    /// first download: when the system relaunches the app to service
    /// pending background-transfer events, the delegate has to already be
    /// in place to receive them.
    func activate() {
        _ = session
    }

    func start(jobID: UUID, from url: URL, to destination: URL) {
        setDestination(destination, for: jobID)
        let task = session.downloadTask(with: url)
        // How a relaunched app re-associates a system task with its job.
        task.taskDescription = jobID.uuidString
        task.resume()
    }

    func cancel(jobID: UUID) {
        Task {
            let tasks = await session.allTasks
            tasks.first { $0.taskDescription == jobID.uuidString }?.cancel()
        }
    }

    func runningJobIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init) })
    }

    /// Stashes the handler `urlSessionDidFinishEvents` should call. Used to
    /// bridge into SwiftUI's `.backgroundTask(.urlSession(...))`, whose
    /// closure is expected to keep awaiting until pending session events
    /// have actually been delivered.
    func awaitFinishedEvents(_ handler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = handler
        lock.unlock()
    }

    private func setDestination(_ url: URL, for jobID: UUID) {
        lock.lock()
        destinations[jobID.uuidString] = url
        let snapshot = destinations
        lock.unlock()
        Self.persistDestinations(snapshot)
    }

    private func destination(for jobID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return destinations[jobID.uuidString]
    }

    private func clearDestination(for jobID: UUID) {
        lock.lock()
        destinations[jobID.uuidString] = nil
        let snapshot = destinations
        lock.unlock()
        Self.persistDestinations(snapshot)
    }

    private static func loadDestinations() -> [String: URL] {
        guard let data = try? Data(contentsOf: PersistentStorage.destinationsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: URL].self, from: data)) ?? [:]
    }

    private static func persistDestinations(_ destinations: [String: URL]) {
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        try? data.write(to: PersistentStorage.destinationsFile, options: .atomic)
    }

    private func jobID(for task: URLSessionTask) -> UUID? {
        task.taskDescription.flatMap(UUID.init)
    }
}

extension BackgroundDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let jobID = jobID(for: downloadTask) else { return }

        // Servers that send no Content-Length report -1 here; the bar stays
        // indeterminate rather than showing a bogus percentage.
        guard totalBytesExpectedToWrite > 0 else {
            let delegate = events
            Task { @MainActor in delegate?.downloadProgressed(jobID: jobID, fraction: nil) }
            return
        }

        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        // Publish only on whole-percent changes: this fires many times a
        // second per task, and three concurrent downloads would otherwise
        // rerender the whole list constantly.
        let percent = Int((fraction * 100).rounded())
        lock.lock()
        let unchanged = lastPercent[jobID.uuidString] == percent
        if !unchanged { lastPercent[jobID.uuidString] = percent }
        lock.unlock()
        guard !unchanged else { return }

        let delegate = events
        Task { @MainActor in delegate?.downloadProgressed(jobID: jobID, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let jobID = jobID(for: downloadTask), let destinationURL = destination(for: jobID) else { return }

        // This must happen synchronously: the temporary file is deleted as
        // soon as this method returns. It may also run in a process the
        // system just relaunched to service this session, with none of
        // DownloadManager's in-memory job state around — hence resolving
        // the destination from the on-disk map above, not an in-memory one.
        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            lock.lock()
            moveErrors[jobID.uuidString] = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobID = jobID(for: task) else { return }

        lock.lock()
        let moveError = moveErrors.removeValue(forKey: jobID.uuidString)
        lastPercent[jobID.uuidString] = nil
        lock.unlock()
        clearDestination(for: jobID)

        let delegate = events
        if let error {
            // A cancelled transfer is reported as an ordinary URLError, but the
            // queue distinguishes cancellation from failure.
            let isCancelled = (error as? URLError)?.code == .cancelled
            Task { @MainActor in delegate?.downloadFailed(jobID: jobID, error: error, cancelled: isCancelled) }
            return
        }

        if let moveError {
            Task { @MainActor in delegate?.downloadFailed(jobID: jobID, error: moveError, cancelled: false) }
            return
        }

        Task { @MainActor in delegate?.downloadFinished(jobID: jobID) }
    }
}

extension BackgroundDownloader: URLSessionDelegate {
    /// Fired once every event for this background session that was pending
    /// has been delivered to the delegate methods above — including, after
    /// a relaunch, ones that happened while the app wasn't running at all.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()

        DispatchQueue.main.async {
            handler?()
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

/// The resolver's structured error body, e.g. `{"error":"no_video","message":"…"}`.
/// `message` is optional because a non-2xx response that isn't from this
/// resolver at all (a misconfigured endpoint, an intervening proxy) may not
/// have one, or may fail to decode as this shape at all.
private struct ResolverErrorBody: Decodable {
    let error: String?
    let message: String?
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
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // The resolver endpoint is whatever the user typed into the app, so
            // its response — including this error body — is untrusted input
            // that ends up on screen. If it decodes to a usable message, sanitize
            // that message (see `sanitizeUntrustedResolverMessage`) before it's
            // ever surfaced; otherwise fall back to a message we control.
            if let body = try? JSONDecoder().decode(ResolverErrorBody.self, from: data),
               let sanitized = Self.sanitizeUntrustedResolverMessage(body.message), !sanitized.isEmpty {
                throw SaveForXError.resolverRejected(sanitized)
            }
            if (500..<600).contains(statusCode) {
                throw SaveForXError.resolverUnavailable
            }
            throw SaveForXError.invalidResolverResponse
        }

        do {
            return try JSONDecoder().decode(ResolvedVideo.self, from: data)
        } catch {
            throw SaveForXError.invalidResolverResponse
        }
    }

    /// The resolver endpoint is user-supplied, so nothing it sends back —
    /// including this error message — is trusted, and it's about to be shown
    /// directly in a job row. Strip control characters/newlines (which could
    /// otherwise be used to inject line breaks or terminal-style tricks into
    /// the UI), collapse repeated whitespace, and cap the length rather than
    /// rejecting an overlong message outright.
    private static func sanitizeUntrustedResolverMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let withoutControlCharacters = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)
        let collapsed = String(withoutControlCharacters)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let maxLength = 120
        if collapsed.count > maxLength {
            return String(collapsed.prefix(maxLength))
        }
        return collapsed
    }
}

enum SaveForXError: LocalizedError {
    case photoPermissionDenied
    case invalidResolverEndpoint
    case resolverUnavailable
    case resolverRejected(String)
    case invalidResolverResponse
    case downloadInterrupted

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied:
            return "Photos permission is needed to save the video."
        case .invalidResolverEndpoint:
            return "Enter a valid resolver URL in the app."
        case .resolverUnavailable:
            return "The video resolver is unavailable right now."
        case .resolverRejected(let message):
            return message
        case .invalidResolverResponse:
            return "The resolver returned an invalid response."
        case .downloadInterrupted:
            return "Download was interrupted."
        }
    }
}
