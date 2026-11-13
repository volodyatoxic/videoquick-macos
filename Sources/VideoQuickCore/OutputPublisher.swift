import Foundation
import Darwin

public enum OutputPublisher {
    public static func publish(temporary: URL, source: URL, bitrate: Bitrate, edited: Bool) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let temporaryParent = temporary.deletingLastPathComponent()
        let privateName = temporaryParent.lastPathComponent
        let privateChild = privateName.hasPrefix(".videoquick-") && UUID(uuidString: String(privateName.dropFirst(".videoquick-".count))) != nil && temporaryParent.deletingLastPathComponent().resolvingSymlinksInPath() == parent.resolvingSymlinksInPath()
        guard (temporaryParent.resolvingSymlinksInPath() == parent.resolvingSymlinksInPath() || privateChild), temporary.standardizedFileURL != source.standardizedFileURL else { throw VideoQuickError("Небезопасный путь результата.") }
        let stem = source.deletingPathExtension().lastPathComponent + (edited ? "_edit" : "") + "_\(bitrate.rawValue)mbps"
        for index in 1...100_000 {
            let name = stem + (index == 1 ? "" : "_\(index)")
            let output = parent.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
            if renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 { return output }
            let code = errno
            if code != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Не удалось сохранить копию: \(String(cString: strerror(code)))"]) }
        }
        throw VideoQuickError("Слишком много файлов с одинаковым именем.")
    }
}
