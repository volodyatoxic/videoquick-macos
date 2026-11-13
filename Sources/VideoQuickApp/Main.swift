import AppKit
import SwiftUI
import Darwin
import VideoQuickCore

@main enum VideoQuickMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: AppModel.supportDirectory, withIntermediateDirectories: true)
        let descriptor = open(AppModel.supportDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.volodyatoxic.VideoQuick").first?.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let delegate = AppDelegate(); application.delegate = delegate
        application.run()
        close(descriptor)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var receivedExternalOpen = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu(); NSApp.applicationIconImage = NSImage(systemSymbolName: "video", accessibilityDescription: "VideoQuick")
        let consumed = AppModel.shared.consumePendingRequests()
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if LaunchPresentation.startup(isDefaultLaunch: isDefault, receivedExternalOpen: receivedExternalOpen, consumedFinderRequest: consumed) == .history {
            AppModel.shared.showHistory()
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) { receivedExternalOpen = true; AppModel.shared.handle(urls) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { AppModel.shared.reopen(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.queue.hasWork else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Остановить обработку и выйти?"; alert.informativeText = "Незавершённые задания будут отменены. Оригиналы и готовые копии сохранятся."
        alert.addButton(withTitle: "Продолжить работу"); alert.addButton(withTitle: "Остановить и выйти")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        AppModel.shared.queue.cancelAll(); return .terminateNow
    }
    @objc private func openFiles() { let files = AppModel.shared.chooseFiles(); AppModel.shared.showEditor(files) }
    @objc private func setupFinder() { AppModel.shared.configureFinder() }
    @objc private func openHistory() { AppModel.shared.showHistory() }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu(); appItem.submenu = app
        app.addItem(withTitle: "О VideoQuick", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(NSMenuItem.separator())
        let setup = app.addItem(withTitle: "Настроить меню Finder…", action: #selector(setupFinder), keyEquivalent: ","); setup.target = self
        app.addItem(NSMenuItem.separator()); app.addItem(withTitle: "Завершить VideoQuick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let fileItem = NSMenuItem(); let file = NSMenu(title: "Файл"); fileItem.submenu = file
        let historyItem = file.addItem(withTitle: "Последние действия", action: #selector(openHistory), keyEquivalent: ""); historyItem.target = self
        let openItem = file.addItem(withTitle: "Открыть видео…", action: #selector(openFiles), keyEquivalent: "o"); openItem.target = self; main.addItem(fileItem)
        file.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Правка"); editItem.submenu = edit
        for (title, selector, key) in [("Отменить", #selector(EditorScrubWindow.undo(_:)), "z"), ("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        let redo = NSMenuItem(title: "Повторить", action: #selector(EditorScrubWindow.redo(_:)), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        main.addItem(editItem); NSApp.mainMenu = main
    }
}
