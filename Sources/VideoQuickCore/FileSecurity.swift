import Foundation
import Darwin

enum FileSecurity {
    static func workDirectory(source: URL, id: UUID) throws -> URL {
        let directory = source.deletingLastPathComponent().appendingPathComponent(".videoquick-\(id.uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw posix("Не удалось создать приватную рабочую папку") }
        do {
            guard let empty = acl_init(0) else { throw posix("Не удалось ограничить доступ") }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_file(directory.path, ACL_TYPE_EXTENDED, empty) == 0, chmod(directory.path, 0o700) == 0 else { throw posix("Не удалось ограничить доступ к рабочей папке") }
            return directory
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func apply(source: URL, output: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VideoQuickError("Файл принадлежит другому пользователю. Не удалось гарантировать сохранение ограничений доступа.") }
        guard copyfile(source.path, output.path, nil, copyfile_flags_t(COPYFILE_ACL)) == 0 else { throw posix("Не удалось сохранить ограничения ACL") }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        guard chmod(output.path, mode_t(mode & 0o600)) == 0 else { throw posix("Не удалось ограничить права копии") }
        let count = getxattr(source.path, "com.apple.quarantine", nil, 0, 0, 0)
        if count < 0 {
            guard errno == ENOATTR else { throw posix("Не удалось прочитать quarantine") }
        } else {
            guard count <= 1024 * 1024 else { throw VideoQuickError("Слишком большой атрибут quarantine.") }
            var data = Data(count: count)
            let read = data.withUnsafeMutableBytes { getxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            guard read == count else { throw posix("Не удалось сохранить quarantine") }
            let written = data.withUnsafeBytes { setxattr(output.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            guard written == 0 else { throw posix("Не удалось сохранить quarantine") }
        }
    }
    private static func posix(_ message: String) -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message]) }
}
