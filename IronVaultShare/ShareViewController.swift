import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private let appGroupId = "group.com.likithsai.vaultios"

    override func viewDidLoad() {
        super.viewDidLoad()
        stageIncomingFiles()
    }

    private func stageIncomingFiles() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments,
              let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let spoolDir = groupURL.appendingPathComponent("SharedImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)

        let group = DispatchGroup()

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { sourceURL, error in
                    defer { group.leave() }
                    if let src = sourceURL {
                        let dest = spoolDir.appendingPathComponent(src.lastPathComponent)
                        try? FileManager.default.copyItem(at: src, to: dest)
                    }
                }
            }
        }

        group.notify(queue: .main) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
