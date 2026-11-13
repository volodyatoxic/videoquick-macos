import AVFoundation

enum TrackAssociations {
    static func validate(_ tracks: [AVAssetTrack], hasTimeEdits: Bool) async throws {
        if hasTimeEdits && tracks.contains(where: { $0.mediaType == .timecode }) {
            throw VideoQuickError("Обрезка и вырезание видео с таймкодом пока не поддерживаются. Обычная конвертация сохраняет таймкод.")
        }
        for track in tracks {
            for type in try await track.load(.availableTrackAssociationTypes) {
                guard type == .timecode, track.mediaType == .video || track.mediaType == .audio else {
                    throw VideoQuickError("Этот вид связанных служебных дорожек пока не поддерживается без изменения метаданных.")
                }
                let targets = try await track.loadAssociatedTracks(ofType: type)
                guard targets.count == 1, targets[0].mediaType == .timecode, tracks.contains(where: { $0.trackID == targets[0].trackID }) else {
                    throw VideoQuickError("Нельзя однозначно сохранить связь с дорожкой таймкода.")
                }
            }
        }
    }
    static func copy(_ tracks: [AVAssetTrack], inputs: [CMPersistentTrackID: AVAssetWriterInput]) async throws {
        for track in tracks {
            guard let input = inputs[track.trackID] else { continue } // Explicitly muted audio.
            for type in try await track.load(.availableTrackAssociationTypes) {
                for target in try await track.loadAssociatedTracks(ofType: type) {
                    guard let targetInput = inputs[target.trackID], input.canAddTrackAssociation(withTrackOf: targetInput, type: type.rawValue) else {
                        throw VideoQuickError("Исходный контейнер не позволяет сохранить связь с таймкодом.")
                    }
                    input.addTrackAssociation(withTrackOf: targetInput, type: type.rawValue)
                }
            }
        }
    }
    static func verify(source: [AVAssetTrack], output: [AVAssetTrack]) async throws {
        guard source.count == output.count, zip(source, output).allSatisfy({ $0.mediaType == $1.mediaType }) else { throw VideoQuickError("Изменился состав дорожек при сохранении таймкода.") }
        // Writer inputs are added in this same order; IDs may be reassigned.
        let ids = Dictionary(uniqueKeysWithValues: zip(source, output).map { ($0.trackID, $1.trackID) })
        for (original, result) in zip(source, output) {
            let originalTypes = try await original.load(.availableTrackAssociationTypes)
            let resultTypes = try await result.load(.availableTrackAssociationTypes)
            guard Set(originalTypes) == Set(resultTypes) else { throw VideoQuickError("Не удалось сохранить все связи служебных дорожек.") }
            for type in originalTypes {
                let targets = try await original.loadAssociatedTracks(ofType: type)
                let mapped = targets.compactMap { ids[$0.trackID] }
                let saved = try await result.loadAssociatedTracks(ofType: type)
                guard mapped.count == targets.count, mapped.sorted() == saved.map(\.trackID).sorted() else { throw VideoQuickError("Не удалось сохранить связь с нужной дорожкой таймкода.") }
            }
            if original.mediaType == .timecode {
                let before = try await original.load(.formatDescriptions), after = try await result.load(.formatDescriptions)
                guard before.count == after.count else { throw VideoQuickError("Изменился формат таймкода.") }
                for (a, b) in zip(before, after) {
                    guard CMFormatDescriptionGetMediaSubType(a) == CMFormatDescriptionGetMediaSubType(b), CMTimeCodeFormatDescriptionGetFrameQuanta(a) == CMTimeCodeFormatDescriptionGetFrameQuanta(b), CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(a), CMTimeCodeFormatDescriptionGetFrameDuration(b)) == 0, CMTimeCodeFormatDescriptionGetTimeCodeFlags(a) == CMTimeCodeFormatDescriptionGetTimeCodeFlags(b) else { throw VideoQuickError("Изменились параметры таймкода.") }
                }
            }
        }
    }
}
