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
                    router.handle(url)
                }
        }
    }
}

final class AppRouter: ObservableObject {
    @Published var pendingPostURL: URL?

    func handle(_ url: URL) {
        guard url.scheme == "saveforx",
              url.host == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedLink = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let postURL = URL(string: encodedLink),
              postURL.isXPostURL else {
            return
        }

        pendingPostURL = postURL
    }
}

extension URL {
    var isXPostURL: Bool {
        guard let host = host?.lowercased() else { return false }
        return ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host)
    }
}
