import DVRKit
import SwiftUI

struct PlaybackView: View {
    @Environment(AppStore.self) private var store
    @State private var controller = PlaybackController()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var ranges: [DVRConnection.RecordRange] = []
    @State private var loadingRanges = false
    @State private var rangeError: String?
    @State private var zoom: Double = 1
    @State private var mainStream = false
    @State private var aspect: VideoAspect = .fit

    private let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]

    private struct QueryKey: Hashable { let ref: CameraRef?; let day: Date; let conn: ObjectIdentifier? }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            video
            Divider()
            controls
        }
        .task(id: QueryKey(ref: store.playbackRef, day: day,
                           conn: store.playbackRef.flatMap { store.device($0.deviceID) }.map { ObjectIdentifier($0.connection) })) {
            await loadRanges()
        }
        .onDisappear { controller.stop() }
    }

    // MARK: - 上方：頻道與日期

    private var header: some View {
        HStack(spacing: 12) {
            if let ref = store.playbackRef {
                Label(store.name(of: ref), systemImage: "video").font(.headline)
                if let dev = store.device(ref.deviceID) {
                    Text(dev.config.name).foregroundStyle(.secondary)
                }
            } else {
                Text("請在左側選擇要回放的頻道").foregroundStyle(.secondary)
            }
            Spacer()
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("前一天")
            DatePicker("日期", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0) }),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 120)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("後一天")
                .disabled(day >= Calendar.current.startOfDay(for: Date()))
            Button("今天") { day = Calendar.current.startOfDay(for: Date()) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 影像

    private var video: some View {
        VideoSurface(renderer: controller.renderer, aspect: aspect)
            .background(Color.black)
            .overlay { videoStatus }
            .overlay(alignment: .bottomLeading) {
                if let t = controller.currentTime {
                    Text(t, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .contextMenu {
                Picker("畫面比例", selection: $aspect) { ForEach(VideoAspect.allCases) { Text($0.title).tag($0) } }
                Button("截圖") { snapshot() }
            }
    }

    @ViewBuilder private var videoStatus: some View {
        if store.playbackRef == nil {
            EmptyView()
        } else if loadingRanges {
            ProgressView("查詢錄影中…").tint(.white).foregroundStyle(.white)
        } else if let e = rangeError {
            message("查詢錄影失敗", e, "exclamationmark.triangle")
        } else if ranges.isEmpty {
            message("這一天沒有錄影", "請選擇其他日期", "calendar.badge.exclamationmark")
        } else {
            switch controller.phase {
            case .loading: ProgressView().tint(.white)
            case .ended: message("播放結束", "點選時間軸繼續播放其他時段", "stop.circle")
            case .failed(let e): message("播放錯誤", e, "exclamationmark.triangle")
            case .idle: message("點選時間軸開始播放", "", "hand.tap")
            default: EmptyView()
            }
        }
    }

    private func message(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.caption).multilineTextAlignment(.center) }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 下方：時間軸與控制

    private var controls: some View {
        VStack(spacing: 6) {
            RecordTimeline(day: day, ranges: ranges, current: controller.currentTime, zoom: $zoom) { t in
                startOrSeek(t)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            HStack(spacing: 14) {
                legend
                Spacer()
                Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .help("倒退 10 秒").keyboardShortcut(.leftArrow, modifiers: [])
                Button { togglePlay() } label: {
                    Image(systemName: controller.isPaused || controller.phase == .idle || controller.phase == .ended ? "play.fill" : "pause.fill")
                        .frame(width: 22)
                }
                .help("播放／暫停（空白鍵）")
                .keyboardShortcut(.space, modifiers: [])
                Button { controller.skip(10) } label: { Image(systemName: "goforward.10") }
                    .help("前進 10 秒").keyboardShortcut(.rightArrow, modifiers: [])
                Button { controller.step() } label: { Image(systemName: "forward.frame") }
                    .help("逐格（.）").keyboardShortcut(".", modifiers: [])
                Picker("倍速", selection: Binding(get: { controller.speed }, set: { controller.setSpeed($0) })) {
                    ForEach(speeds, id: \.self) { s in Text(s == 0.5 ? "0.5×" : "\(Int(s))×").tag(s) }
                }
                .frame(width: 90)
                .help("播放速度（>4× 只顯示關鍵幀）")
                Spacer()
                Picker("串流", selection: $mainStream) {
                    Text("子串流").tag(false)
                    Text("主串流").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .onChange(of: mainStream) { _, _ in if let t = controller.currentTime { startOrSeek(t, reopen: true) } }
                HStack(spacing: 4) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...48).frame(width: 100)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
                .help("時間軸縮放")
                Button { snapshot() } label: { Image(systemName: "camera") }.help("截圖")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .disabled(store.playbackRef == nil || ranges.isEmpty)
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(Array(Set(ranges.map { $0.type.uppercased() })).sorted(), id: \.self) { t in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(RecordTimeline.color(t)).frame(width: 10, height: 8)
                    Text(Self.typeName(t)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func typeName(_ t: String) -> String {
        switch t {
        case "SCHEDULE": return "排程"
        case "MOTION": return "移動偵測"
        case "SENSOR": return "感應器"
        case "MANUAL": return "手動"
        case "INTELLIGENT": return "智慧偵測"
        case "POS": return "POS"
        default: return t
        }
    }

    // MARK: - 動作

    private func shiftDay(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = n }
    }

    private func loadRanges() async {
        controller.stop()
        ranges = []
        rangeError = nil
        guard let ref = store.playbackRef, let dev = store.device(ref.deviceID) else { return }
        loadingRanges = true
        defer { loadingRanges = false }
        do {
            let r = try await dev.connection.recordRanges(channelId: ref.channelID, day: day)
            guard !Task.isCancelled else { return }
            ranges = r
            // 自動從當日第一段錄影開始（今天則從 10 分鐘前開始）
            if let first = r.first {
                var start = first.start
                if Calendar.current.isDateInToday(day), let last = r.last {
                    start = max(first.start, min(last.end, Date()).addingTimeInterval(-600))
                }
                startOrSeek(start)
            }
        } catch {
            if !Task.isCancelled { rangeError = DeviceModel.describe(error) }
        }
    }

    private func startOrSeek(_ t: Date, reopen: Bool = false) {
        guard let ref = store.playbackRef, let dev = store.device(ref.deviceID) else { return }
        // 點到沒有錄影的空白處：跳到下一段錄影的開頭
        var target = t
        if !ranges.contains(where: { $0.start <= t && t < $0.end }), let next = ranges.first(where: { $0.start > t }) {
            target = next.start
        }
        if reopen { controller.stop() }
        controller.open(connection: dev.connection, channelID: ref.channelID, mainStream: mainStream, at: target)
    }

    private func togglePlay() {
        switch controller.phase {
        case .idle, .ended, .failed:
            if let t = controller.currentTime ?? ranges.first?.start { startOrSeek(t) }
        default:
            controller.togglePause()
        }
    }

    private func snapshot() {
        guard let ref = store.playbackRef else { return }
        store.saveSnapshot(controller.renderer.lastPixelBuffer, name: store.name(of: ref) + "-回放",
                           time: controller.renderer.lastTime)
    }
}
