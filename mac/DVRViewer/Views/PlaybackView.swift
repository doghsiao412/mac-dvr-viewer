import DVRKit
import SwiftUI

struct PlaybackView: View {
    @Environment(AppStore.self) private var store
    @State private var controller = MultiPlaybackController()
    /// 上次開始播放的格子組合與日期：只換選取的格子時不重新播放
    @State private var lastStart: StartKey?
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var ranges: [DVRConnection.RecordRange] = []
    @State private var loadingRanges = false
    @State private var rangeError: String?
    @State private var nearby: (before: Date?, after: Date?) = (nil, nil)
    @State private var zoom: Double = 6  // 預設顯示 4 小時
    /// 回放固定使用主串流（錄影本身即主串流；實測主子串流幀率相同）
    private let mainStream = true
    @State private var aspect: VideoAspect = .fit
    @State private var showExport = false

    private let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]

    private struct QueryKey: Hashable { let ref: CameraRef?; let day: Date; let conn: ObjectIdentifier?; let grid: [CameraRef?] }
    private struct StartKey: Equatable { let grid: [CameraRef?]; let day: Date }

    var body: some View {
        layoutBody
        .task(id: QueryKey(ref: store.playbackRef, day: day,
                           conn: store.playbackRef.flatMap { store.device($0.deviceID) }.map { ObjectIdentifier($0.connection) },
                           grid: store.playbackGrid)) {
            await loadRanges()
        }
        .onChange(of: store.playbackFocus, initial: true) { _, i in controller.setFocus(store.playbackLayout == 1 ? 0 : i) }
        .onDisappear { controller.stop() }
        .onChange(of: store.volume, initial: true) { _, v in controller.setVolume(v) }
        .sheet(isPresented: $showExport) {
            if let ref = store.playbackRef {
                ExportSheet(ref: ref,
                            suggestedStart: controller.currentTime ?? ranges.first?.start ?? day,
                            ranges: ranges)
            }
        }
    }

    /// 1 分割：影像滿版，上下為浮動玻璃面板。
    /// 4 分割：標題列與時間軸放在畫面上下方，不遮住任何一格。
    @ViewBuilder private var layoutBody: some View {
        if store.playbackLayout == 1 {
            video
                .overlay(alignment: .top) {
                    header
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 12).padding(.horizontal, 16)
                }
                .overlay(alignment: .bottom) {
                    controls
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
                .background(Color.black)
        } else {
            VStack(spacing: 8) {
                header
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 16).padding(.top, 8)
                video
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                controls
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            // 外框跟隨淺色／深色模式；只有影像區是黑底
            .background(Color(nsColor: .windowBackgroundColor))
        }
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
                .buttonStyle(.borderless)
                .help("前一天")
            DatePicker("日期", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0) }),
                       displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 120)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("後一天")
                .disabled(day >= Calendar.current.startOfDay(for: Date()))
            Button("今天") { day = Calendar.current.startOfDay(for: Date()) }
                .buttonStyle(.glass)
        }
    }

    // MARK: - 影像

    @ViewBuilder private var video: some View {
        if store.playbackLayout == 1 {
            VideoSurface(renderer: controller.renderer, aspect: aspect)
                .background(Color.black)
                .overlay { videoStatus }
                .contextMenu {
                    Picker("畫面比例", selection: $aspect) { ForEach(VideoAspect.allCases) { Text($0.title).tag($0) } }
                    Button("截圖") { snapshot() }
                }
        } else {
            // 4 分割同步回放：點格子選取（時間軸、聲音、截圖以選取的格子為準）
            GeometryReader { geo in
                let w = (geo.size.width - 2) / 2, h = (geo.size.height - 2) / 2
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(0..<2, id: \.self) { r in
                        GridRow {
                            ForEach(0..<2, id: \.self) { c in
                                playbackTile(r * 2 + c).frame(width: w, height: h)
                            }
                        }
                    }
                }
            }
            .background(Color.black)
            .overlay { videoStatus }
        }
    }

    private func playbackTile(_ i: Int) -> some View {
        let ref = store.playbackSlots[i]
        let sub = controller.subs[i]
        return ZStack {
            if let ref {
                VideoSurface(renderer: sub.renderer, aspect: aspect)
                    .overlay(alignment: .bottomLeading) {
                        Text(store.name(of: ref)).font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule).padding(6)
                    }
                    .overlay {
                        if sub.phase == .loading { ProgressView().controlSize(.small).padding(10).glassEffect(.regular, in: .circle) }
                    }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus.viewfinder").font(.title2)
                    Text("選取此格後，點選左側頻道").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
            }
        }
        .overlay {
            Rectangle().strokeBorder(store.playbackFocus == i ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focusPlayback(i) }
        .contextMenu {
            if ref != nil {
                Button("截圖") { store.focusPlayback(i); snapshot() }
                Button("從畫面移除") { store.playbackSlots[i] = nil }
            }
        }
    }

    @ViewBuilder private var videoStatus: some View {
        if store.playbackRef == nil {
            EmptyView()
        } else if loadingRanges {
            ProgressView("查詢錄影中…")
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else if let e = rangeError {
            message("查詢錄影失敗", e, "exclamationmark.triangle")
        } else if ranges.isEmpty {
            noRecordingView
        } else if store.playbackLayout == 1 {
            switch controller.phase {
            case .loading: ProgressView().padding(14).glassEffect(.regular, in: .circle)
            case .ended: message("播放結束", "點選時間軸繼續播放其他時段", "stop.circle")
            case .failed(let e): message("播放錯誤", e, "exclamationmark.triangle")
            case .idle: message("點選時間軸開始播放", "", "hand.tap")
            default: EmptyView()
            }
        }
    }

    /// 當天無錄影：提示並提供前後最接近、有錄影的日期
    private var noRecordingView: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark").font(.title)
            Text("DVR 在這一天沒有此攝影機的錄影").font(.headline)
            Text(day, format: .dateTime.year().month().day().weekday())
                .font(.caption).foregroundStyle(.secondary)
            if nearby.before != nil || nearby.after != nil {
                HStack(spacing: 10) {
                    if let b = nearby.before {
                        Button { day = b } label: {
                            Label { Text(b, format: .dateTime.month().day()) } icon: { Image(systemName: "chevron.left") }
                        }
                        .help("前往前一個有錄影的日期")
                    }
                    if let a = nearby.after {
                        Button { day = a } label: {
                            Label { Text(a, format: .dateTime.month().day()) } icon: { Image(systemName: "chevron.right") }
                        }
                        .labelStyle(.titleAndIcon)
                        .environment(\.layoutDirection, .rightToLeft)
                        .help("前往下一個有錄影的日期")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                Text("最接近且有錄影的日期").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("這台攝影機目前在 DVR 上沒有任何錄影").font(.caption)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func message(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title)
            Text(title).font(.headline)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - 下方：時間軸與控制

    private var controls: some View {
        VStack(spacing: 4) {
            RecordTimeline(day: day, ranges: ranges, current: controller.currentTime, zoom: $zoom) { t in
                startOrSeek(t)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if let t = controller.currentTime {
                        Text(t, format: .dateTime.hour().minute().second())
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text(t, format: .dateTime.year().month().day())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    legend
                }
                .frame(minWidth: 120, alignment: .leading)
                Spacer()
                Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .help("倒退 10 秒").keyboardShortcut(.leftArrow, modifiers: [])
                Button { togglePlay() } label: {
                    Image(systemName: controller.isPaused || controller.phase == .idle || controller.phase == .ended ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .help("播放／暫停（空白鍵）")
                .keyboardShortcut(.space, modifiers: [])
                Button { controller.skip(10) } label: { Image(systemName: "goforward.10") }
                    .help("前進 10 秒").keyboardShortcut(.rightArrow, modifiers: [])
                Button { controller.step() } label: { Image(systemName: "forward.frame") }
                    .help("逐格（.）").keyboardShortcut(".", modifiers: [])
                Button { togglePlaybackAudio() } label: {
                    Image(systemName: controller.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                        .frame(width: 20)
                }
                .help(controller.audioOn ? "關閉聲音" : "開啟聲音（只在 1× 播放時輸出）")
                if controller.audioOn {
                    Slider(value: Binding(get: { store.volume }, set: { store.volume = $0 }), in: 0...1)
                        .frame(width: 70)
                        .help("音量")
                }
                Picker("倍速", selection: Binding(get: { controller.speed }, set: { controller.setSpeed($0) })) {
                    ForEach(speeds, id: \.self) { s in Text(s == 0.5 ? "0.5×" : "\(Int(s))×").tag(s) }
                }
                .frame(width: 90)
                .help("播放速度（>4× 只顯示關鍵幀）")
                Spacer()
                HStack(spacing: 6) {
                    Button { zoomBy(1 / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("縮小時間軸（⌘－）")
                        .keyboardShortcut("-", modifiers: [.command])
                        .disabled(zoom <= RecordTimeline.zoomRange.lowerBound)
                    Menu(RecordTimeline.spanText(zoom: zoom)) {
                        ForEach([(1.0, "24 小時"), (2, "12 小時"), (6, "4 小時"), (24, "1 小時"), (96, "15 分鐘"), (288, "5 分鐘"), (1440, "1 分鐘")], id: \.0) { z, label in
                            Button(label) { zoom = z }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("時間軸顯示範圍")
                    Button { zoomBy(2) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("放大時間軸（⌘＋）")
                        .keyboardShortcut("=", modifiers: [.command])
                        .disabled(zoom >= RecordTimeline.zoomRange.upperBound)
                }
                Button { snapshot() } label: { Label("截圖", systemImage: "camera") }
                    .labelStyle(.titleAndIcon)
                    .help("截圖")
                Button { showExport = true } label: { Label("下載", systemImage: "arrow.down.circle") }
                    .labelStyle(.titleAndIcon)
                    .help("下載錄影（⌘D）")
                    .keyboardShortcut("d", modifiers: [.command])
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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

    private func togglePlaybackAudio() {
        controller.setAudio(!controller.audioOn)
    }

    private func zoomBy(_ f: Double) {
        withAnimation(.snappy(duration: 0.2)) {
            zoom = min(max(zoom * f, RecordTimeline.zoomRange.lowerBound), RecordTimeline.zoomRange.upperBound)
        }
    }

    private func shiftDay(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = n }
    }

    private func loadRanges() async {
        let key = StartKey(grid: store.playbackGrid, day: day)
        // 只換選取的格子（同一組頻道、同一天）：重新查錄影範圍，不重新播放
        let restart = key != lastStart
        // 同一天內換格子裡的頻道：從目前播放的時間接著播
        let resumeAt = restart && lastStart?.day == day ? controller.currentTime : nil
        if restart { controller.stop() }
        ranges = []
        rangeError = nil
        nearby = (nil, nil)
        guard let ref = store.playbackRef, let dev = store.device(ref.deviceID) else { return }
        loadingRanges = true
        defer { loadingRanges = false }
        do {
            let r = try await dev.connection.recordRanges(channelId: ref.channelID, day: day)
            guard !Task.isCancelled else { return }
            ranges = r
            if r.isEmpty {
                nearby = (try? await dev.connection.nearestRecordingDays(channelId: ref.channelID, around: day)) ?? (nil, nil)
            }
            guard restart else { return }
            lastStart = key
            if let resumeAt { startOrSeek(resumeAt); return }
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
        // 點到沒有錄影的空白處：跳到下一段錄影的開頭
        var target = t
        if !ranges.contains(where: { $0.start <= t && t < $0.end }), let next = ranges.first(where: { $0.start > t }) {
            target = next.start
        }
        if reopen { controller.stop() }
        let sources = store.playbackGrid.map { r -> (conn: DVRConnection, channelID: String)? in
            guard let r, let dev = store.device(r.deviceID) else { return nil }
            return (dev.connection, r.channelID)
        }
        guard sources.contains(where: { $0 != nil }) else { return }
        lastStart = StartKey(grid: store.playbackGrid, day: day)
        controller.open(sources, focus: store.playbackLayout == 1 ? 0 : store.playbackFocus, mainStream: mainStream, at: target)
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
