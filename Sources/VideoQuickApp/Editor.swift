import SwiftUI
import AVKit
import VideoQuickCore

@MainActor final class EditorSession: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var selection: UUID?
    init(urls: [URL]) { add(urls) }
    func add(_ urls: [URL]) { documents += urls.map(EditorDocument.init); if selection == nil { selection = documents.first?.id } }
    var current: EditorDocument? { documents.first { $0.id == selection } }
}
struct EditorView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let document = session.current { EditorDocumentView(document: document, model: model).id(document.id) }
            if session.documents.count > 1 {
                Menu {
                    ForEach(session.documents) { document in Button(document.url.lastPathComponent) { session.selection = document.id } }
                } label: { Image(systemName: "square.stack") }
                    .menuStyle(.borderlessButton).fixedSize().padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12).padding(.top, 32)
            }
        }.background(.black).ignoresSafeArea(.container, edges: .top)
    }
}
struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var model: AppModel
    @State private var showError = false
    private var message: String? { document.validationError ?? document.error }
    var body: some View {
        GeometryReader { _ in
            ZStack {
                NativeCropPlayer(player: document.player, crop: document.previewCrop, editing: !document.saveState.isActive,
                    onPan: { dx, dy, width, height in document.panImage(dx: dx, dy: dy, width: width, height: height) },
                    onZoom: { document.zoomImage(factor: $0) }, onBegin: { document.beginEditGesture() }, onEnd: { document.endEditGesture() })
                if document.info == nil && document.error == nil { ProgressView() }
                VStack {
                    HStack { Spacer(minLength: 0); toolbar(); Spacer(minLength: 0) }.padding(.top, 24)
                    Spacer(minLength: 0)
                    if document.timeline != nil {
                        HStack(spacing: 10) {
                            Button { document.togglePlayback() } label: {
                                Image(systemName: document.playing ? "pause.fill" : "play.fill").font(.system(size: 20)).frame(width: 26, height: 44)
                            }.buttonStyle(.borderless)
                                .accessibilityLabel(document.playing ? "Пауза" : "Воспроизвести").disabled(document.saveState.isActive)
                            ClipTimelineView(document: document).frame(height: 48)
                        }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                }.padding(12)
            }.clipped()
        }
        .task { model.configureEditor(document); if document.info == nil { await document.load() } else { document.refreshPreview() }; model.configureEditor(document) }
        .onChange(of: document.timeline?.aspect) { _, _ in model.configureEditor(document) }
        .onChange(of: document.cropPreset) { _, _ in model.configureEditor(document) }
        .onChange(of: document.saveState.isActive) { _, _ in model.configureEditor(document) }
        .onDisappear { document.stop(); document.endEditGesture() }
    }
    private func toolbar() -> some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Формат", selection: Binding(get: { document.cropPreset }, set: { document.setPreset($0) })) {
                    ForEach(["auto", "1:1", "4:3", "16:9", "3:4", "9:16"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.inline).labelsHidden()
            } label: {
                Text(document.cropPreset).monospacedDigit()
            }
                .menuStyle(.borderlessButton).menuIndicator(.visible).frame(width: 62, height: 32).accessibilityLabel("Формат").accessibilityValue(document.cropPreset)
                .help("Соотношение сторон").disabled(document.saveState.isActive || document.info == nil)
            Divider().frame(height: 18)
            if document.hasAudio {
                Button { document.toggleMute() } label: { icon(document.mute ? "ToolbarVolumeOff" : "ToolbarVolumeOn").frame(width: 32, height: 32) }
                    .accessibilityLabel("Звук").accessibilityValue(document.mute ? "Выключен" : "Включён").help("Звук").disabled(document.saveState.isActive)
            }
            Button { document.reset() } label: { icon("ToolbarReset").frame(width: 32, height: 32) }
                .accessibilityLabel("Сбросить изменения").help("Вернуть исходное видео").disabled(!document.canReset)
            if let message {
                Button { showError.toggle() } label: { icon("ToolbarWarning").foregroundStyle(.red).frame(width: 32, height: 32) }
                    .help(message).accessibilityLabel(message).popover(isPresented: $showError) { Text(message).textSelection(.enabled).padding(12).frame(maxWidth: 320) }
            }
            if document.saveState.isActive {
                Button { document.cancelSave() } label: { icon("ToolbarCancel").frame(width: 44, height: 32) }
                    .help("Прервать сохранение").accessibilityLabel("Прервать сохранение")
            } else {
                Menu {
                    ForEach(Bitrate.allCases) { choice in
                        Button(choice.label) { document.save(in: model.queue, bitrate: choice) }
                    }
                } label: {
                    icon("ToolbarSave")
                }
                    .menuStyle(.borderlessButton).menuIndicator(.visible).frame(width: 44, height: 32).accessibilityLabel("Сохранить").help("Выбрать битрейт и сохранить")
                    .disabled(document.validationError != nil || document.info == nil)
            }
        }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
    }
    private func icon(_ name: String, size: CGFloat = 18) -> some View {
        Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
    }

}
