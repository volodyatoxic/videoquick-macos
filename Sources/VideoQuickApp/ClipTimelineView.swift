import SwiftUI
import VideoQuickCore

struct ClipTimelineView: View {
    @ObservedObject var document: EditorDocument
    private let selectionColor = Color(red: 1, green: 2.0 / 3, blue: 0)
    @State private var trimBase: ClipEdit?
    @State private var trimMap: TimelineDisplayLayout?
    @State private var previousX: Double?

    var body: some View {
        GeometryReader { geometry in
            if let timeline = document.timeline {
                let layout = TimelineDisplayLayout(sourceDuration: timeline.sourceDuration, viewportWidth: max(1, Double(geometry.size.width)), clips: timeline.clips, frameDuration: timeline.frameDuration, zoom: document.timelineZoom)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { strip(timeline, layout: layout) }
                        .background(TimelineScrollRegion(document: document, layout: layout, following: previousX == nil && trimBase == nil))
                        .onChange(of: document.playheadClip?.id) { _, _ in follow(proxy) }
                        .onChange(of: document.sourcePlayhead) { _, _ in if !document.playing { follow(proxy) } }
                        .onChange(of: document.playing) { _, playing in if playing { follow(proxy) } }
                }
            }
        }
    }
    private func follow(_ proxy: ScrollViewProxy) {
        guard document.timelineZoom == 1, previousX == nil, trimBase == nil, let id = document.playheadClip?.id else { return }
        proxy.scrollTo(id, anchor: .center)
    }
    private func strip(_ timeline: ClipTimeline, layout: TimelineDisplayLayout) -> some View {
        let saving = document.saveState
        return HStack(spacing: 0) {
            ForEach(layout.items) { item in
                if let id = item.clipID, let index = timeline.clips.firstIndex(where: { $0.id == id }) {
                    segment(timeline.clips[index], index: index, item: item, timeline: timeline, layout: layout, saving: saving).id(id)
                } else {
                    filmstrip(item, timeline: timeline).saturation(0).opacity(saving.isActive ? 0.1 : 0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).frame(width: item.width, height: 48).allowsHitTesting(false)
                }
            }
        }
        .frame(width: layout.contentWidth, height: 48, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if !saving.isActive {
                Capsule().fill(.red).frame(width: 2.5, height: 32)
                    .offset(x: markerOffset(layout, timeline: timeline), y: 8).allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "sourceTimeline").contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sourceTimeline"))
            .onChanged { value in
                guard !saving.isActive else { return }
                let x = min(layout.contentWidth, max(0, Double(value.location.x)))
                let forward = x >= (previousX ?? markerPosition(layout)); previousX = x
                document.scrubSource(to: layout.sourceTime(atX: x, movingForward: forward), movingForward: forward)
            }.onEnded { _ in previousX = nil })
        .accessibilityElement(children: .contain).accessibilityLabel("Таймлайн")
        .accessibilityValue(saving.isActive ? "Сохранение \(Int(saving.progress * 100))%" : "\(document.sourcePlayhead.formatted(.number.precision(.fractionLength(2)))) с")
        .accessibilityAdjustableAction { direction in
            guard !saving.isActive else { return }
            switch direction {
            case .increment: document.stepPlayhead(frames: 1)
            case .decrement: document.stepPlayhead(frames: -1)
            @unknown default: break
            }
        }
        .contextMenu {
            Button { document.split() } label: { Label("Разрезать видео", systemImage: "scissors") }
                .accessibilityLabel("Разрезать у плейхеда").disabled(saving.isActive || !document.canSplitAtPlayhead)
            Button { document.deleteAtPlayhead() } label: { Label("Удалить фрагмент", systemImage: "trash") }
                .accessibilityLabel("Удалить фрагмент у плейхеда").disabled(saving.isActive || timeline.clips.count <= 1 || document.clipAtPlayhead == nil)
        }
    }
    private func segment(_ clip: ClipEdit, index: Int, item: TimelineDisplayLayout.Item, timeline: ClipTimeline, layout: TimelineDisplayLayout, saving: EditorSaveState) -> some View {
        let selected = timeline.selectedID == clip.id
        let framed = selected && !saving.isActive
        let pictureWidth = framed ? item.innerEnd - item.innerStart : item.width
        let pictureHeight = framed ? 39.0 : 44.0
        return ZStack {
            if framed { RoundedRectangle(cornerRadius: 12).fill(selectionColor) }
            filmstrip(item, timeline: timeline, width: pictureWidth, height: pictureHeight).saturation(saving.isActive ? 0 : 1)
                .opacity(saving.isActive ? 0.1 : 1)
                .overlay(alignment: .leading) {
                    if saving.isActive {
                        filmstrip(item, timeline: timeline, width: pictureWidth, height: pictureHeight)
                            .mask(alignment: .leading) { Rectangle().frame(width: pictureWidth * saving.fraction(for: clip.id, in: timeline)) }.allowsHitTesting(false)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: framed ? 2 : 12)).allowsHitTesting(false)
            if !framed {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
            }
            if framed {
                HStack(spacing: 0) {
                    handle(left: true, clip: clip, timeline: timeline, layout: layout)
                    Spacer(minLength: 0)
                    handle(left: false, clip: clip, timeline: timeline, layout: layout)
                }
            }
        }
        .frame(width: item.width, height: 48).contentShape(Rectangle())
        .accessibilityElement(children: .ignore).accessibilityLabel("Фрагмент \(index + 1)")
        .accessibilityValue("\(clip.start.formatted(.number.precision(.fractionLength(2))))–\(clip.end.formatted(.number.precision(.fractionLength(2)))) с")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !saving.isActive { document.selectClip(clip.id, seek: true) } }
    }
    private func filmstrip(_ item: TimelineDisplayLayout.Item, timeline: ClipTimeline, width: Double? = nil, height: Double = 44) -> some View {
        let width = width ?? item.width
        let count = max(1, Int(ceil(width / 45)))
        return LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { tile in
                Group {
                    if let image = document.thumbnail(at: item.range.start + item.range.duration * (Double(tile) + 0.5) / Double(count)) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else { Rectangle().fill(.quaternary) }
                }.frame(width: width / Double(count), height: height).clipped()
            }
        }.frame(width: width, height: height).accessibilityHidden(true)
    }
    private func markerPosition(_ layout: TimelineDisplayLayout) -> Double {
        layout.x(at: document.sourcePlayhead, preferredClip: document.boundaryPreviewClipID ?? document.playheadClip?.id)
    }
    private func markerOffset(_ layout: TimelineDisplayLayout, timeline: ClipTimeline) -> Double {
        let x = markerPosition(layout)
        if let selected = layout.item(for: timeline.selectedID), x >= selected.innerStart, x <= selected.innerEnd {
            return min(selected.innerEnd - 2.5, max(selected.innerStart, x - 1.25))
        }
        return x - 1.25
    }
    private func handle(left: Bool, clip: ClipEdit, timeline: ClipTimeline, layout: TimelineDisplayLayout) -> some View {
        Capsule().fill(Color(white: 0.12)).frame(width: 2.5, height: 14)
            .frame(width: layout.item(for: clip.id)?.inset ?? 5.5, height: 48)
            .contentShape(Rectangle().inset(by: -2))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sourceTimeline"))
                .onChanged { value in
                    if trimBase == nil { trimBase = clip; trimMap = layout; document.beginTrim() }
                    guard let base = trimBase, let map = trimMap, let baseItem = map.item(for: base.id) else { return }
                    document.selectClip(clip.id)
                    let edgeX = (left ? baseItem.innerStart : baseItem.innerEnd) + Double(value.translation.width)
                    let proposed = map.sourceTime(atX: edgeX, trimming: true)
                    let limits = timeline.selectedLimits
                    if left {
                        let start = map.snappedTrimTime(proposed, playhead: document.sourcePlayhead, clip: base.id, limits: limits.lowerBound...max(limits.lowerBound, base.end - timeline.frameDuration))
                        document.trim(start: start, end: base.end)
                    } else {
                        let end = map.snappedTrimTime(proposed, playhead: document.sourcePlayhead, clip: base.id, limits: min(limits.upperBound, base.start + timeline.frameDuration)...limits.upperBound)
                        document.trim(start: base.start, end: end)
                    }
                }.onEnded { _ in trimBase = nil; trimMap = nil; document.endEditGesture() })
    }
}
