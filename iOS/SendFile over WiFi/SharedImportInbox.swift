import Foundation

enum SharedImportInbox {
    static let appGroup = "group.com.ao.SendFile-over-WiFi"

    @MainActor
    static func consumeIntoTemporaryDirectory() -> [URL] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return [] }
        let inbox = container.appendingPathComponent("Share Inbox", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shared Imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        return urls.compactMap { source in
            let target = destination.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
            do {
                try FileManager.default.moveItem(at: source, to: target)
                return target
            } catch {
                return nil
            }
        }
    }
}
