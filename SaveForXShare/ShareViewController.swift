import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            finishWithError()
            return
        }

        let supportedTypes = [UTType.url.identifier, UTType.text.identifier]
        guard let type = supportedTypes.first(where: provider.hasItemConformingToTypeIdentifier) else {
            finishWithError()
            return
        }

        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    self?.finishWithError()
                    return
                }

                let sharedURL: URL?
                if let url = item as? URL {
                    sharedURL = url
                } else if let text = item as? String {
                    sharedURL = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    sharedURL = nil
                }

                guard let sharedURL, sharedURL.isXPostURL else {
                    self?.finishWithError()
                    return
                }

                var components = URLComponents()
                components.scheme = "saveforx"
                components.host = "share"
                components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]

                guard let appURL = components.url else {
                    self?.finishWithError()
                    return
                }

                self?.extensionContext?.open(appURL) { opened in
                    if !opened {
                        self?.finishWithError()
                    } else {
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
        }
    }

    private func finishWithError() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "SaveForXShare",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Share an X post link to Save for X."]
        ))
    }
}

private extension URL {
    var isXPostURL: Bool {
        guard let host = host?.lowercased() else { return false }
        return ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host)
    }
}
