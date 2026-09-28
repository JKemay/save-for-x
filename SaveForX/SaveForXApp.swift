import SwiftUI

@main
struct SaveForXApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var downloadManager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(downloadManager)
                .onOpenURL { url in
                    if let post = router.postURL(from: url) {
                        downloadManager.enqueue(postURL: post)
                    }
                }
                #if DEBUG
                .task { enqueueLaunchArgumentLinks() }
                #endif
        }
        // Lets the system relaunch (or wake) the app to service the
        // background download session: the closure just awaits pending
        // session events (see DownloadManager.awaitBackgroundSessionEvents)
        // and returning ends the background task, letting iOS suspend the
        // app again.
        .backgroundTask(.urlSession(BackgroundDownloader.sessionIdentifier)) {
            await downloadManager.awaitBackgroundSessionEvents()
        }
    }

    #if DEBUG
    /// Queue links passed on the command line, so the download queue can be
    /// driven from a script without the Share Sheet:
    ///
    ///     xcrun simctl launch <device> com.saveforx.app -enqueueLinks "url1,url2"
    ///
    /// Reuses the same parsing and validation the paste field uses, and is
    /// compiled out of release builds entirely.
    private func enqueueLaunchArgumentLinks() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-enqueueLinks"),
              arguments.index(after: flag) < arguments.endIndex else {
            return
        }
        downloadManager.enqueue(pastedText: arguments[arguments.index(after: flag)])
    }
    #endif
}

final class AppRouter: ObservableObject {
    /// Validate a `saveforx://share?url=…` link and return the X post URL it
    /// carries, or nil if it isn't one. Doesn't store any state itself so
    /// every share can be queued independently rather than replacing the
    /// last one.
    func postURL(from url: URL) -> URL? {
        guard url.scheme == "saveforx",
              url.host == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedLink = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let postURL = URL(string: encodedLink),
              postURL.isXPostURL else {
            return nil
        }

        return postURL
    }
}

extension URL {
    /// Accepts only an https link to a specific post.
    ///
    /// Host alone is not enough: a profile or homepage link would be accepted
    /// here and then rejected by the resolver, which reads to the user as the
    /// app failing rather than as the wrong link being shared. This matches the
    /// share extension's own check so the rejection happens as early as possible.
    var isXPostURL: Bool {
        guard scheme?.lowercased() == "https",
              let host = host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host) else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1] == "status" else { return false }
        return !parts[2].isEmpty && parts[2].allSatisfy { $0.isNumber }
    }

    /// Strip tracking query items and the fragment so the same post shared as
    /// `…/status/123?s=46&t=abc` and `…/status/123` are recognized as one job.
    var canonicalXPostURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.scheme = scheme
        components.host = host?.lowercased()
        components.path = path.lowercased()
        components.query = nil
        components.fragment = nil
        return components.url ?? self
    }
}
