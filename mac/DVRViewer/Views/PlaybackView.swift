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
    /// 事件清單（移動偵測等），對象為目前所有格子的攝影機
    @State private var events: [EventListView.Item] = []
    @State private var loadingEvents = false
    @State private var eventLogDenied = false
    @State private var showEvents = false
    /// 時間軸上標記的下載範圍（起點／終點）
    @State private var markIn: Date?
    @State private var markOut: Date?

    private let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]

    private struct QueryKey: Hashable { let ref: CameraRef?; let day: Date; let conn: ObjectIdentifier?; let grid: [CameraRef?] }
    private struct StartKey: Equatable { let grid: [CameraRef?]; let day: Date }
    private struct EventKey: Hashable { let grid: [CameraRef?]; let day: Date; let conns: [ObjectIdentifier] }

    /// 標記的範圍（起點與終點都有時）
    private var markedRange: ClosedRange<Date>? {
        guard let a = markIn, let b = markOut, a != b else { return nil }
        return min(a, b)...max(a, b)
    }

    var body: some View {
        layoutBody
        .task(id: QueryKey(ref: store.playbackRef, day: day,
                           conn: store.playbackRef.flatMap { store.device($0.deviceID) }.map { ObjectIdentifier($0.connection) },
                           grid: store.playbackGrid)) {
            await loadRanges()
        }
        .task(id: EventKey(grid: store.playbackGrid, day: day,
                           conns: store.playbackGrid.compactMap { $0.flatMap { store.device($0.deviceID) }.map { ObjectIdentifier($0.connection) } })) {
            await loadEvents()
        }
        .onChange(of: day) { markIn = nil; markOut = nil }
        .onChange(of: store.playbackFocus, initial: true) { _, i in controller.setFocus(store.playbackLayout == 1 ? 0 : i) }
        .onDisappear { controller.stop() }
        .onChange(of: store.volume, initial: true) { _, v in controller.setVolume(v) }
        .sheet(isPresented: $showExport) {
            if let ref = store.playbackRef {
                ExportSheet(ref: ref,
                            suggestedStart: markedRange?.lowerBound ?? controller.currentTime ?? ranges.first?.start ?? day,
                            suggestedEnd: markedRange?.upperBound,
                            ranges: ranges)
            }
        }
    }

    /// 標題列與時間軸放在畫面上下方，不遮住影像（1 分割、4 分割相同）。
    private var layoutBody: some View {
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
            RecordTimeline(day: day, ranges: ranges, current: controller.currentTime, zoom: $zoom,
                           markIn: markIn, markOut: markOut,
                           markers: events.filter { $0.ref == store.playbackRef && $0.event.source == .log }.map(\.event.start),
                           onSelect: { a, b in markIn = a; markOut = b }) { t in
                startOrSeek(t)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // 左右兩側等寬，中間的播放鍵因此正好落在面板（與時間軸）正中央
            HStack(spacing: 16) {
                HStack(spacing: 14) {
                    timeInfo
                    Divider().frame(height: 28)
                    playbackOptions
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                transport.fixedSize()

                ViewThatFits(in: .horizontal) {
                    toolButtons(labels: true)
                    toolButtons(labels: false)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // 隱藏的快捷鍵（I／O 標記起點、終點）
            .background {
                Group {
                    Button("") { setMark(in: true) }.keyboardShortcut("i", modifiers: [])
                    Button("") { setMark(in: false) }.keyboardShortcut("o", modifiers: [])
                }
                .opacity(0).accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .disabled(store.playbackRef == nil || ranges.isEmpty)
        }
    }

    /// 左側：目前時間與圖例／標記範圍
    private var timeInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let t = controller.currentTime {
                Text(t, format: .dateTime.hour().minute().second())
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(t, format: .dateTime.year().month().day())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if markIn != nil || markOut != nil {
                markSummary
            } else {
                legend
            }
        }
        .frame(minWidth: 120, alignment: .leading)
        .fixedSize()
    }

    /// 左側：逐格、聲音、倍速
    private var playbackOptions: some View {
        HStack(spacing: 12) {
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
            Menu {
                ForEach(speeds, id: \.self) { s in
                    Button(Self.speedText(s)) { controller.setSpeed(s) }
                }
            } label: {
                Text(Self.speedText(controller.speed)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("播放速度（>4× 只顯示關鍵幀）")
        }
        .fixedSize()
    }

    private static func speedText(_ s: Double) -> String {
        s == 0.5 ? "0.5×" : "\(Int(s))×"
    }

    /// 中間：倒退、播放、前進（左右對稱）
    private var transport: some View {
        HStack(spacing: 20) {
            Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2) }
                .help("倒退 10 秒").keyboardShortcut(.leftArrow, modifiers: [])
            Button { togglePlay() } label: {
                Image(systemName: controller.isPaused || controller.phase == .idle || controller.phase == .ended ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .help("播放／暫停（空白鍵）")
            .keyboardShortcut(.space, modifiers: [])
            Button { controller.skip(10) } label: { Image(systemName: "goforward.10").font(.title2) }
                .help("前進 10 秒").keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    /// 右側：時間軸縮放、事件、標記、截圖、下載（空間不足時只顯示圖示）
    private func toolButtons(labels: Bool) -> some View {
        HStack(spacing: labels ? 14 : 10) {
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
            Divider().frame(height: 20)
            Button { showEvents.toggle() } label: { toolLabel("事件", "list.bullet.rectangle", labels) }
                .help("移動偵測等事件清單（E）")
                .keyboardShortcut("e", modifiers: [])
                .popover(isPresented: $showEvents, arrowEdge: .top) {
                    EventListView(items: events, loading: loadingEvents,
                                  multiCamera: store.playbackLayout > 1,
                                  logDenied: eventLogDenied,
                                  name: { store.name(of: $0) },
                                  current: controller.currentTime,
                                  onPick: { pickEvent($0) })
                }
            Menu {
                Button("設為起點（I）") { setMark(in: true) }
                Button("設為終點（O）") { setMark(in: false) }
                Divider()
                Button("清除標記") { markIn = nil; markOut = nil }
                    .disabled(markIn == nil && markOut == nil)
            } label: {
                toolLabel("標記", "bracket.square.left.fill", labels)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("標記下載範圍：播放到開頭按 I、到結尾按 O；或按住 Shift 在時間軸上拖曳")
            Button { snapshot() } label: { toolLabel("截圖", "camera", labels) }
                .help("截圖")
            Button { showExport = true } label: { toolLabel("下載", "arrow.down.circle", labels) }
                .help("下載錄影（⌘D）")
                .keyboardShortcut("d", modifiers: [.command])
        }
        .fixedSize()
    }

    @ViewBuilder private func toolLabel(_ title: String, _ symbol: String, _ withText: Bool) -> some View {
        if withText {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        } else {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
    }

    /// 標記的下載範圍
    private var markSummary: some View {
        HStack(spacing: 4) {
            Image(systemName: "bracket.square.left.fill").foregroundStyle(RecordTimeline.markColor)
            Group {
                if let r = markedRange {
                    Text("\(r.lowerBound.formatted(.dateTime.hour().minute().second()))–\(r.upperBound.formatted(.dateTime.hour().minute().second()))（\(EventListView.duration(r.upperBound.timeIntervalSince(r.lowerBound)))）")
                } else if let a = markIn {
                    Text("起點 \(a.formatted(.dateTime.hour().minute().second()))，再按 O 設終點")
                } else if let b = markOut {
                    Text("終點 \(b.formatted(.dateTime.hour().minute().second()))，再按 I 設起點")
                }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Button { markIn = nil; markOut = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("清除標記")
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

    private func setMark(in isIn: Bool) {
        guard let t = controller.currentTime else { return }
        if isIn { markIn = t } else { markOut = t }
    }

    /// 查詢目前各格攝影機在這一天的事件
    private func loadEvents() async {
        let refs = Array(Set(store.playbackGrid.compactMap { $0 }))
        events = []
        guard !refs.isEmpty else { return }
        loadingEvents = true
        defer { loadingEvents = false }
        var out: [EventListView.Item] = []
        var denied = false
        for (devID, group) in Dictionary(grouping: refs, by: \.deviceID) {
            guard let dev = store.device(devID) else { continue }
            let ev = await dev.connection.events(channelIds: group.map(\.channelID), day: day)
            guard !Task.isCancelled else { return }
            if await dev.connection.alarmLogDenied { denied = true }
            out += ev.map { EventListView.Item(ref: CameraRef(deviceID: devID, channelID: $0.channelId), event: $0) }
        }
        events = out.sorted { $0.event.start < $1.event.start }
        eventLogDenied = denied
    }

    /// 點事件：選取該攝影機的格子並跳到事件時間
    private func pickEvent(_ item: EventListView.Item) {
        if store.playbackLayout > 1, let i = store.playbackSlots.firstIndex(of: item.ref) {
            store.focusPlayback(i)
        }
        // 事件錄影從開頭播；日誌事件（連續錄影中）提早 3 秒
        let t = item.event.source == .log ? item.event.start.addingTimeInterval(-3) : item.event.start
        startOrSeek(t, snap: false)
    }

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

    private func startOrSeek(_ t: Date, reopen: Bool = false, snap: Bool = true) {
        // 點到沒有錄影的空白處：跳到下一段錄影的開頭
        var target = t
        if snap, !ranges.contains(where: { $0.start <= t && t < $0.end }), let next = ranges.first(where: { $0.start > t }) {
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
