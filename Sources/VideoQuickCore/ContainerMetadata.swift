import Foundation

/// Preserves the original static movie user-data atom. No sample offsets are
/// changed: this is only allowed when the writer's moov follows all media data.
enum ContainerMetadata {
    struct Atom { let type: String; let start: UInt64; let size: UInt64; let header: UInt64; var end: UInt64 { start + size } }
    static func atoms(_ handle: FileHandle, start: UInt64, end: UInt64) throws -> [Atom] {
        var cursor = start, result: [Atom] = []
        while cursor < end {
            guard end - cursor >= 8 else { throw VideoQuickError("Повреждён блок контейнера.") }
            try handle.seek(toOffset: cursor)
            guard let bytes = try handle.read(upToCount: 16), bytes.count >= 8 else { throw VideoQuickError("Не удалось прочитать контейнер.") }
            let short = number(bytes.prefix(4))
            let header: UInt64 = short == 1 ? 16 : 8
            let size = short == 0 ? end - cursor : short == 1 && bytes.count == 16 ? number(bytes[8..<16]) : short
            guard size >= header, size <= end - cursor else { throw VideoQuickError("Некорректный размер блока контейнера.") }
            result.append(Atom(type: String(decoding: bytes[4..<8], as: UTF8.self), start: cursor, size: size, header: header))
            cursor += size
        }
        return result
    }
    static func number<T: Collection>(_ bytes: T) -> UInt64 where T.Element == UInt8 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func read(_ handle: FileHandle, atom: Atom) throws -> Data {
        guard atom.size <= 128 * 1024 * 1024 else { throw VideoQuickError("Слишком большой блок метаданных для безопасного переноса.") }
        try handle.seek(toOffset: atom.start)
        guard let data = try handle.read(upToCount: Int(atom.size)), data.count == Int(atom.size) else { throw VideoQuickError("Не удалось прочитать метаданные.") }
        return data
    }
    static func preserve(from source: URL, to output: URL) throws {
        let original = try FileHandle(forReadingFrom: source)
        defer { try? original.close() }
        let sourceEnd = try original.seekToEnd()
        guard let sourceMoov = try atoms(original, start: 0, end: sourceEnd).first(where: { $0.type == "moov" }) else { throw VideoQuickError("В исходнике нет movie-блока.") }
        let metadata = try atoms(original, start: sourceMoov.start + sourceMoov.header, end: sourceMoov.end).filter { $0.type == "udta" || $0.type == "meta" }
        guard !metadata.isEmpty else { return }
        let target = try FileHandle(forUpdating: output)
        defer { try? target.close() }
        let targetEnd = try target.seekToEnd()
        let top = try atoms(target, start: 0, end: targetEnd)
        guard let moov = top.first(where: { $0.type == "moov" }), moov.end == targetEnd, top.filter({ $0.type == "mdat" }).allSatisfy({ $0.end <= moov.start }) else { throw VideoQuickError("Расположение метаданных не позволяет безопасно сохранить их без изменения видео.") }
        let children = try atoms(target, start: moov.start + moov.header, end: moov.end)
        var payload = Data()
        for child in children where child.type != "udta" && child.type != "meta" { payload += try read(target, atom: child) }
        for atom in metadata { payload += try read(original, atom: atom) }
        guard payload.count < Int(UInt32.max) - 8 else { throw VideoQuickError("Слишком большой movie-блок.") }
        var length = UInt32(payload.count + 8).bigEndian
        var replacement = withUnsafeBytes(of: &length) { Data($0) }
        replacement += Data("moov".utf8); replacement += payload
        try target.seek(toOffset: moov.start); try target.write(contentsOf: replacement); try target.truncate(atOffset: moov.start + UInt64(replacement.count)); try target.synchronize()
    }
    static func validateTimeEdits(source: URL) throws {
        let file = try FileHandle(forReadingFrom: source); defer { try? file.close() }
        let end = try file.seekToEnd()
        guard let moov = try atoms(file, start: 0, end: end).first(where: { $0.type == "moov" }) else { throw VideoQuickError("В исходнике нет movie-блока.") }
        for atom in try atoms(file, start: moov.start + moov.header, end: moov.end) where atom.type == "udta" {
            if try atoms(file, start: atom.start + atom.header, end: atom.end).contains(where: { $0.type == "chpl" }) {
                throw VideoQuickError("Видео содержит главы. Обрезка и удаление фрагментов пока не поддерживаются для сохранения их времён.")
            }
        }
    }
}
