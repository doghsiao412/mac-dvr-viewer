import DVRKit
import SwiftUI

/// 單一頻道錄影回放。直放：影像在上、時間軸與控制在下；橫放：影像全螢幕，點一下顯示／隱藏控制。
struct PlaybackView: View {
    let device: DeviceModel
    let channelID: String

    @State private var controller = PlaybackController()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var ranges: [DVRConnection.RecordRange] = []
    @State private var loadingRanges = false
    @State private var rangeError: String?
    @State private var nearby: (before: Date?, after: Date?) = (nil, nil)
    @State private var zoom: Double = 6   // 預設顯示 4 小時
    @State private var events: [DVRConnection.RecordEvent] = []
    @State private var loadingEvents = false
    @State private var sheet: SheetKind?
    @State private var showControls = true
    @AppStorage("phone.playback.mainStream") private var mainStream = false
    /// 已載入錄影範圍的日期（同一天重新載入時，從原本播放的時間接著播）
    @State private var loadedDay: Date?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var vSize

    private let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]
    private var landscape: Bool { vSize == .compact }
    /// 畫面大小（判斷寬螢幕，例如 iPhone Duo 展開）
    @State private var size: CGSize = .zero
    /// 寬螢幕但不是一般手機橫放：影像放最大，控制項併成兩列
    private var wide: Bool { !landscape && size.width > size.height * 1.15 }
    /// 直放時影像與控制項之外還剩約 110 pt 以上（約 2 筆事件）（例如 iPhone Duo 外螢幕），事件清單直接列在下方
    private var inlineEvents: Bool {
        !landscape && !wide && size.height - (size.width - 32) * 9 / 16 - 230 > 110
    }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    enum SheetKind: String, Identifiable {
        case events, export
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if landscape {
                ZStack {
                    Color.black.ignoresSafeArea()
                    video
                    if showControls {
                        VStack {
                            Spacer()
                            VStack(spacing: 6) {
                                timeline
                                transport
                            }
                            .padding(12)
                            .glassEffect(in: .rect(cornerRadius: 20))
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { withAnimation { showControls.toggle() } }
                .toolbarVisibility(showControls ? .visible : .hidden, for: .navigationBar)
                .statusBarHidden(!showControls)
                .persistentSystemOverlays(.hidden)
            } else if wide {
                VStack(spacing: 8) {
                    video
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                        .clipShape(.rect(cornerRadius: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    timeline
                    HStack(spacing: 8) {
                        dayBar.frame(maxWidth: 300)
                        Spacer()
                        skipBack
                        playButton
                        skipForward
                        Spacer()
                        HStack(spacing: 4) {
                            timeText.font(.headline.monospacedDigit())
                            speedMenu
                            audioButton
                        }
                        .frame(maxWidth: 300, alignment: .trailing)
                    }
                    .disabled(ranges.isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            } else {
                VStack(spacing: 8) {
                    video
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal)
                        .layoutPriority(1)   // 下方清單不可擠壓影像
                    timeline.padding(.horizontal)
                    transport.padding(.horizontal)
                    HStack(spacing: 0) {
                        dayControls
                        Spacer()
                        timeText.font(.headline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal)
                    if inlineEvents {
                        eventList
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .navigationTitle(device.displayName(channelID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !inlineEvents {
                    Button { sheet = .events } label: { Label("事件", systemImage: "list.bullet.rectangle") }
                }
                Button { sheet = .export } label: { Label("下載", systemImage: "square.and.arrow.down") }
                    .disabled(ranges.isEmpty)
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .events:
                EventsSheet(events: events, loading: loadingEvents, current: controller.currentTime) { e in
                    // 事件錄影從開頭播；日誌事件（連續錄影中）提早 3 秒
                    startOrSeek(e.source == .log ? e.start.addingTimeInterval(-3) : e.start, snap: false)
                }
            case .export:
                ExportSheet(device: device, channelID: channelID,
                            initialStart: controller.currentTime ?? ranges.first?.start ?? day,
                            mainStream: mainStream)
            }
        }
        .task(id: QueryKey(day: day, conn: ObjectIdentifier(device.connection), online: device.status == .online)) {
            await loadRanges()
        }
        .task(id: QueryKey(day: day, conn: ObjectIdentifier(device.connection), online: device.status == .online)) {
            await loadEvents()
        }
        .onChange(of: scenePhase) { _, phase in
            // 切到背景：停止播放（保留目前時間），回到前景重新連線後接著播
            if phase == .background { controller.stop() }
        }
        .onChange(of: mainStream) { _, _ in
            if let t = controller.currentTime { startOrSeek(t, reopen: true, snap: false) }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 畫面

    private var video: some View {
        ZStack {
            VideoSurface(renderer: controller.renderer)
            overlay
        }
    }

    @ViewBuilder private var overlay: some View {
        if loadingRanges {
            status { ProgressView().tint(.white); Text("查詢錄影…") }
        } else if let rangeError {
            status {
                Image(systemName: "exclamationmark.triangle")
                Text(rangeError)
                Button("重試") { Task { await loadRanges() } }.buttonStyle(.bordered).tint(.white)
            }
        } else if device.status != .online && ranges.isEmpty {
            status { ProgressView().tint(.white); Text("連線中…") }
        } else if ranges.isEmpty {
            status {
                Image(systemName: "film.stack")
                Text("這天沒有錄影")
                HStack {
                    if let b = nearby.before {
                        Button { day = b } label: { Text("← \(b, format: .dateTime.month().day())") }
                    }
                    if let a = nearby.after {
                        Button { day = a } label: { Text("\(a, format: .dateTime.month().day()) →") }
                    }
                }
                .buttonStyle(.bordered).tint(.white)
            }
        } else {
            switch controller.phase {
            case .loading: status { ProgressView().tint(.white) }
            case .ended: status { Image(systemName: "checkmark.circle"); Text("播放結束") }
            case .failed(let e): status { Image(systemName: "exclamationmark.triangle"); Text(e) }
            default: EmptyView()
            }
        }
    }

    private func status<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) { content() }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding()
    }

    /// 直接列在畫面下方的事件清單（點一下跳到該時間）
    private var eventList: some View {
        List {
            Section {
                if events.isEmpty {
                    Text(loadingEvents ? "查詢事件…" : "這天沒有事件（全天連續錄影時 DVR 不會另外切出事件）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { e in
                        Button {
                            startOrSeek(e.source == .log ? e.start.addingTimeInterval(-3) : e.start, snap: false)
                        } label: {
                            EventRow(event: e, current: controller.currentTime)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("事件（\(events.count)）")
                    if loadingEvents { ProgressView().controlSize(.mini) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private var timeText: some View {
        Group {
            if let t = controller.currentTime {
                Text(t, format: .dateTime.hour().minute().second())
            } else {
                Text("--:--:--")
            }
        }
        .font(.title2.monospacedDigit().weight(.semibold))
    }

    private var timeline: some View {
        PhoneTimeline(day: day, ranges: ranges, current: controller.currentTime,
                      markers: events.filter { $0.source == .log }.map(\.start), zoom: $zoom) { t in
            startOrSeek(t)
        }
    }

    private var transport: some View {
        HStack {
            speedMenu
            Spacer()
            skipBack
            Spacer()
            playButton
            Spacer()
            skipForward
            Spacer()
            audioButton
        }
        .disabled(ranges.isEmpty)
    }

    private var speedMenu: some View {
        Menu {
            Picker("速度", selection: Binding(get: { controller.speed }, set: { controller.setSpeed($0) })) {
                ForEach(speeds, id: \.self) { Text(Self.speedText($0)).tag($0) }
            }
            Picker("畫質", selection: $mainStream) {
                Text("流暢").tag(false)
                Text("高畫質").tag(true)
            }
        } label: {
            Text(Self.speedText(controller.speed))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    private var skipBack: some View {
        Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2).frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("倒退 10 秒")
    }

    private var skipForward: some View {
        Button { controller.skip(10) } label: { Image(systemName: "goforward.10").font(.title2).frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("前進 10 秒")
    }

    private var playButton: some View {
        Button { togglePlay() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.title)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(playing ? "暫停" : "播放")
    }

    private var audioButton: some View {
        Button { controller.setAudio(!controller.audioOn) } label: {
            Image(systemName: controller.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(controller.audioOn ? "關閉聲音" : "開啟聲音")
    }

    private var dayBar: some View {
        HStack {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("前一天")
            Spacer()
            DatePicker("日期", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0) }),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden()
            Spacer()
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }
                .disabled(isToday)
                .accessibilityLabel("後一天")
        }
    }

    /// 精簡的日期切換（直放時與時間放同一列）
    private var dayControls: some View {
        HStack(spacing: 0) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 36, minHeight: 44) }
                .accessibilityLabel("前一天")
            DatePicker("日期", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0) }),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden()
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 36, minHeight: 44) }
                .disabled(isToday)
                .accessibilityLabel("後一天")
        }
    }

    private var playing: Bool {
        switch controller.phase {
        case .playing, .loading: return true
        default: return false
        }
    }

    private static func speedText(_ s: Double) -> String { s == 0.5 ? "0.5×" : "\(Int(s))×" }

    // MARK: - 動作

    private func shiftDay(_ d: Int) {
        if let n = Calendar.current.date(byAdding: .day, value: d, to: day) { day = n }
    }

    private func loadRanges() async {
        let resumeAt = loadedDay == day ? controller.currentTime : nil
        controller.stop()
        ranges = []
        rangeError = nil
        nearby = (nil, nil)
        guard device.status == .online else { return }
        loadingRanges = true
        defer { loadingRanges = false }
        do {
            let r = try await device.connection.recordRanges(channelId: channelID, day: day)
            guard !Task.isCancelled else { return }
            ranges = r
            loadedDay = day
            if let resumeAt, !r.isEmpty {
                startOrSeek(resumeAt, snap: false)
                return
            }
            if r.isEmpty {
                nearby = (try? await device.connection.nearestRecordingDays(channelId: channelID, around: day)) ?? (nil, nil)
                return
            }
            // 從當日第一段錄影開始（今天則從 10 分鐘前開始）
            var start = r[0].start
            if isToday, let last = r.last {
                start = max(r[0].start, min(last.end, Date()).addingTimeInterval(-600))
            }
            startOrSeek(start)
        } catch {
            if !Task.isCancelled { rangeError = DeviceModel.describe(error) }
        }
    }

    private func loadEvents() async {
        events = []
        guard device.status == .online else { return }
        loadingEvents = true
        defer { loadingEvents = false }
        let ev = await device.connection.events(channelIds: [channelID], day: day)
        guard !Task.isCancelled else { return }
        events = ev.sorted { $0.start < $1.start }
    }

    private func startOrSeek(_ t: Date, reopen: Bool = false, snap: Bool = true) {
        // 點到沒有錄影的空白處：跳到下一段錄影的開頭
        var target = t
        if snap, !ranges.contains(where: { $0.start <= t && t < $0.end }), let next = ranges.first(where: { $0.start > t }) {
            target = next.start
        }
        if reopen { controller.stop() }
        controller.open(connection: device.connection, channelID: channelID, mainStream: mainStream, at: target)
    }

    private func togglePlay() {
        switch controller.phase {
        case .idle, .ended, .failed:
            if let t = controller.currentTime ?? ranges.first?.start { startOrSeek(t) }
        default:
            controller.togglePause()
        }
    }

    private struct QueryKey: Hashable {
        let day: Date
        let conn: ObjectIdentifier
        let online: Bool
    }
}
