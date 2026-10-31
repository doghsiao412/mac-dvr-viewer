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
    @Environment(\.verticalSizeClass) private var vSize

    private let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]
    private var landscape: Bool { vSize == .compact }
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
            } else {
                VStack(spacing: 12) {
                    video
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal)
                    timeText
                    timeline.padding(.horizontal)
                    transport.padding(.horizontal)
                    dayBar.padding(.horizontal)
                    Spacer()
                }
            }
        }
        .navigationTitle(device.displayName(channelID))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .events } label: { Label("事件", systemImage: "list.bullet.rectangle") }
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

            Spacer()
            Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2) }
                .accessibilityLabel("倒退 10 秒")
            Spacer()
            Button { togglePlay() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.title)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(playing ? "暫停" : "播放")
            Spacer()
            Button { controller.skip(10) } label: { Image(systemName: "goforward.10").font(.title2) }
                .accessibilityLabel("前進 10 秒")
            Spacer()

            Button { controller.setAudio(!controller.audioOn) } label: {
                Image(systemName: controller.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(controller.audioOn ? "關閉聲音" : "開啟聲音")
        }
        .disabled(ranges.isEmpty)
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
