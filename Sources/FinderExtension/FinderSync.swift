import Cocoa
import FinderSync
import VideoQuickCore
import Darwin

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) } ?? FileManager.default.homeDirectoryForCurrentUser
        FIFinderSyncController.default().directoryURLs = [home, URL(fileURLWithPath: "/Volumes")]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems, let files = FIFinderSyncController.default().selectedItemURLs(), !files.isEmpty, files.allSatisfy({ ["mov", "mp4"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }) else { return nil }
        let menu = NSMenu()
        let convert = NSMenuItem(title: "Конвертировать", action: nil, keyEquivalent: "")
        let presets = NSMenu()
        for bitrate in Bitrate.allCases {
            let item = NSMenuItem(title: bitrate.label, action: #selector(convertFiles(_:)), keyEquivalent: "")
            item.target = self; item.tag = bitrate.rawValue; item.representedObject = files; presets.addItem(item)
        }
        convert.submenu = presets; menu.addItem(convert)
        let edit = NSMenuItem(title: "Изменить…", action: #selector(editFiles(_:)), keyEquivalent: "")
        edit.target = self; edit.representedObject = files; menu.addItem(edit)
        return menu
    }
    @objc private func convertFiles(_ sender: NSMenuItem) { guard let files = FIFinderSyncController.default().selectedItemURLs(), let bitrate = Bitrate(rawValue: sender.tag) else { return }; send(ConversionRequest(action: .convert, files: files, bitrate: bitrate)) }
    @objc private func editFiles(_ sender: NSMenuItem) { guard let files = FIFinderSyncController.default().selectedItemURLs() else { return }; send(ConversionRequest(action: .edit, files: files)) }
    private func send(_ request: ConversionRequest) {
        do {
            let url = try RequestInbox.write(request, directory: RequestInbox.extensionDirectory)
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } catch { NSSound.beep() }
    }
}
