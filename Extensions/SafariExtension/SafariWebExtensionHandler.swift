import SafariServices
import WorkTimerCore

/// Receives native messages from the extension, validates them and enqueues them in the App Group inbox.
/// The app drains the inbox; this handler never touches the main ledger.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let raw = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var ok = false
        if let raw, let obs = BrowserMessage.parse(raw) {
            do {
                let dir = try SnapshotStore.sharedDirectory()
                let inbox = try BrowserInbox(path: dir.appendingPathComponent("browser-inbox.sqlite").path)
                try inbox.enqueue(obs)
                ok = true
            } catch {
                NSLog("WorkTimer Safari inbox failed: %@", error.localizedDescription)
            }
        }
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: ["ok": ok]]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
