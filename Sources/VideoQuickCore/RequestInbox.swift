import Foundation
import Darwin

public enum RequestInbox {
    public static let extensionID = "com.volodyatoxic.VideoQuick.Finder"
    public static var extensionDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/VideoQuickRequests") }
    public static var hostDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(extensionID)/Data/Library/Caches/VideoQuickRequests") }
    public struct Received { public let request: ConversionRequest; public let fileURL: URL }
    public static func write(_ request: ConversionRequest, directory: URL) throws -> URL {
        try request.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(request.id.uuidString + ".json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var components = URLComponents(); components.scheme = "videoquick"; components.host = "request"; components.path = "/\(request.id.uuidString)"; components.queryItems = [URLQueryItem(name: "file", value: file.absoluteString)]
        return components.url!
    }
    public static func read(_ command: URL, directory: URL) throws -> Received {
        guard command.scheme == "videoquick", command.host == "request", let components = URLComponents(url: command, resolvingAgainstBaseURL: false), let value = components.queryItems?.first(where: { $0.name == "file" })?.value, let file = URL(string: value), file.isFileURL, let id = UUID(uuidString: command.lastPathComponent), UUID(uuidString: file.deletingPathExtension().lastPathComponent) == id, file.pathExtension == "json" else { throw VideoQuickError("Некорректная команда Finder.") }
        let allowed = directory.resolvingSymlinksInPath().standardizedFileURL
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.deletingLastPathComponent() == allowed else { throw VideoQuickError("Запрос находится вне контейнера расширения.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 8 * 1024 * 1024, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VideoQuickError("Небезопасный файл запроса.") }
        let request = try JSONDecoder().decode(ConversionRequest.self, from: Data(contentsOf: file))
        guard request.id == id else { throw VideoQuickError("Идентификаторы запроса не совпадают.") }
        try request.validate()
        return Received(request: request, fileURL: file)
    }
    public static func command(for file: URL) -> URL? {
        guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
        var components = URLComponents(); components.scheme = "videoquick"; components.host = "request"; components.path = "/\(id.uuidString)"; components.queryItems = [URLQueryItem(name: "file", value: file.absoluteString)]; return components.url
    }
    public static func pending(directory: URL) throws -> [Received] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        return files.compactMap { file -> Received? in
            guard file.pathExtension == "json", let command = command(for: file) else { return nil }
            return try? read(command, directory: directory)
        }.sorted {
            let first = $0.request.createdAt ?? (try? $0.fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let second = $1.request.createdAt ?? (try? $1.fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return first == second ? $0.request.id.uuidString < $1.request.id.uuidString : first < second
        }
    }
}
