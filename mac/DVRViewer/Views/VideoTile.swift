import SwiftUI

/// 單一攝影機畫面：串流、狀態、名稱、截圖、數位縮放
struct VideoTile: View {
    @Environment(AppStore.self) private var store
    let ref: CameraRef
    let device: DeviceModel
    var mainStream: Bool
    var aspect: VideoAspect

    @State private var controller = LiveTileController()
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var hovering = false

    private struct StreamKey: Hashable {
        let ref: CameraRef
        let main: Bool
        let conn: ObjectIdentifier
        let ready: Bool
    }

    var body: some View {
        GeometryReader { geo in
            VideoSurface(renderer: controller.renderer, aspect: aspect)
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .gesture(magnify.simultaneously(with: drag(geo.size)))
        }
        .background(Color.black)
        .overlay(alignment: .center) { statusOverlay }
        .overlay(alignment: .bottomLeading) { nameBar }
        .overlay(alignment: .topTrailing) { if hovering { tileButtons } }
        .onHover { hovering = $0 }
        .onChange(of: audioOn, initial: true) { _, on in controller.setAudio(on) }
        .onChange(of: store.volume, initial: true) { _, v in controller.setVolume(v) }
        .onAppear {
            controller.onAudioUnsupported = { [ref] in
                if store.audioRef == ref { store.audioRef = nil }
                store.showToast("此頻道沒有聲音")
            }
        }
        .task(id: StreamKey(ref: ref, main: mainStream, conn: ObjectIdentifier(device.connection), ready: device.webStreaming != nil)) {
            guard device.webStreaming != nil else { return }  // 等待偵測完成（WebSocket 或私有協定）
            await controller.run(connection: device.connection, channelID: ref.channelID, mainStream: mainStream)
        }
    }

    // MARK: - 疊加資訊

    @ViewBuilder private var statusOverlay: some View {
        if !device.isOnline(ref.channelID) && device.status == .online {
            badge("頻道離線", "video.slash")
        } else {
            switch controller.phase {
            case .connecting, .idle:
                ProgressView().controlSize(.small).padding(10).glassEffect(.regular, in: .circle)
            case .reconnecting(let why):
                VStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("重新連線中").font(.caption)
                    Text(why).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            case .playing:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    private var nameBar: some View {
        HStack(spacing: 6) {
            Text(device.displayName(ref.channelID)).fontWeight(.medium)
            if audioOn { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.yellow) }
            if mainStream { Text("主").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
            if let t = controller.lastFrameTime {
                Text(t, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            }
            if zoom > 1.01 { Text(String(format: "%.1f×", zoom)).foregroundStyle(.yellow) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(6)
        .allowsHitTesting(false)
    }

    private var tileButtons: some View {
        GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
            if zoom > 1.01 {
                iconButton("arrow.down.right.and.arrow.up.left", "重設縮放") { resetZoom() }
            }
            iconButton(audioOn ? "speaker.wave.2.fill" : "speaker.slash", audioOn ? "關閉聲音" : "開啟聲音（同時只有一個畫面出聲）") {
                toggleAudio()
            }
            iconButton("camera", "截圖") {
                store.saveSnapshot(controller.renderer.lastPixelBuffer, name: device.displayName(ref.channelID),
                                   time: controller.renderer.lastTime)
            }
        }
        }
        .padding(6)
    }

    private var audioOn: Bool { store.audioRef == ref }

    private func toggleAudio() {
        if audioOn { store.audioRef = nil; return }
        store.audioRef = ref
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(help)
    }

    // MARK: - 數位縮放（觸控板捏合；放大後可拖曳平移）

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in zoom = min(max(baseZoom * v.magnification, 1), 8) }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard zoom > 1.01 else { return }
                let maxX = size.width * (zoom - 1) / 2, maxY = size.height * (zoom - 1) / 2
                pan = CGSize(width: min(max(basePan.width + v.translation.width, -maxX), maxX),
                             height: min(max(basePan.height + v.translation.height, -maxY), maxY))
            }
            .onEnded { _ in basePan = pan }
    }

    private func resetZoom() {
        withAnimation(.snappy) { zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero }
    }
}

/// 獨立攝影機視窗：可移到第二螢幕、可設為置頂
struct CameraWindowView: View {
    @Environment(AppStore.self) private var store
    let ref: CameraRef
    @State private var floating = false
    @State private var mainStream = false
    @State private var aspect: VideoAspect = .fit

    var body: some View {
        Group {
            if let dev = store.device(ref.deviceID) {
                VideoTile(ref: ref, device: dev, mainStream: mainStream, aspect: aspect)
                    .navigationTitle(dev.displayName(ref.channelID))
            } else {
                ContentUnavailableView("找不到設備", systemImage: "video.slash")
            }
        }
        .background(WindowLevelSetter(floating: floating))
        .toolbar {
            ToolbarItemGroup {
                Picker("串流", selection: $mainStream) {
                    Text("子串流").tag(false)
                    Text("主串流").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("比例", selection: $aspect) {
                    ForEach(VideoAspect.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $floating) { Label("置頂", systemImage: floating ? "pin.fill" : "pin") }
                    .help("讓此視窗保持在最上層")
            }
        }
    }
}

/// 設定所在 NSWindow 的層級（置頂小視窗）
struct WindowLevelSetter: NSViewRepresentable {
    var floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            v.window?.level = floating ? .floating : .normal
            v.window?.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }
}
