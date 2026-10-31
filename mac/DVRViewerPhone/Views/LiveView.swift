import DVRKit
import SwiftUI

/// 單一頻道即時影像。直放時影像在上、控制在下；橫放時影像全螢幕，點一下顯示／隱藏控制。
/// 影像下方空間足夠時（例如 iPhone Duo 外螢幕、一般 iPhone 直放），列出同一台 DVR 的其他頻道，點一下切換。
struct LiveView: View {
    let device: DeviceModel

    /// 目前顯示的頻道（可從下方清單切換）
    @State private var channelID: String
    @State private var size: CGSize = .zero

    init(device: DeviceModel, channelID: String) {
        self.device = device
        _channelID = State(initialValue: channelID)
    }

    @State private var controller = LiveTileController()
    @AppStorage("phone.live.mainStream") private var mainStream = false
    @AppStorage("phone.live.audio") private var audioOn = false
    @State private var showControls = true
    /// 畫面在最上層（推入回放頁時停止即時串流）
    @State private var visible = false
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase

    private var landscape: Bool { vSize == .compact }
    /// 影像（16:9）與控制列之外還剩約 160 pt 以上，才顯示頻道清單
    private var showChannelList: Bool {
        !landscape && size.height - (size.width - 32) * 9 / 16 - 80 > 160 && device.channels.count > 1
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
                            controls
                                .padding(12)
                                .glassEffect(in: .rect(cornerRadius: 20))
                                .padding()
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
                VStack(spacing: 0) {
                    video
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal)
                        .layoutPriority(1)   // 下方清單不可擠壓影像
                    controls.padding()
                    if showChannelList {
                        channelList
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .navigationTitle(device.displayName(channelID))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: audioOn, initial: true) { _, on in controller.setAudio(on) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: PhoneRoute.playback(CameraRef(deviceID: device.id, channelID: channelID))) {
                    Label("錄影回放", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .task(id: StreamKey(channelID: channelID, main: mainStream, conn: ObjectIdentifier(device.connection),
                            ready: device.webStreaming != nil, visible: visible && scenePhase != .background)) {
            guard visible, scenePhase != .background, device.webStreaming != nil else { return }  // 等待偵測完成（WebSocket 或私有協定）
            await controller.run(connection: device.connection, channelID: channelID, mainStream: mainStream)
        }
        .onAppear { visible = true; UIApplication.shared.isIdleTimerDisabled = true }   // 看影像時不自動鎖定
        .onDisappear { visible = false; UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var video: some View {
        ZStack {
            VideoSurface(renderer: controller.renderer)
            overlay
        }
    }

    @ViewBuilder private var overlay: some View {
        if device.webStreaming == nil {
            status("偵測影像傳輸方式…", spinning: true)
        } else {
            switch controller.phase {
            case .idle, .connecting: status("連線中…", spinning: true)
            case .reconnecting(let why): status("重新連線：\(why)", spinning: true)
            case .playing: EmptyView()
            }
        }
    }

    private func status(_ text: String, spinning: Bool) -> some View {
        VStack(spacing: 8) {
            if spinning { ProgressView().tint(.white) }
            Text(text).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("畫質", selection: $mainStream) {
                Text("流暢").tag(false)
                Text("高畫質").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Spacer()

            if let t = controller.lastFrameTime {
                Text(t, format: .dateTime.hour().minute().second())
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                audioOn.toggle()
            } label: {
                Image(systemName: audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(controller.audioUnsupported)
            .accessibilityLabel(audioOn ? "關閉聲音" : "開啟聲音")
        }
    }

    /// 同一台 DVR 的頻道（只顯示名稱，不播影像，不額外佔用頻寬與連線）
    private var channelList: some View {
        List {
            Section {
                ForEach(device.orderedChannels, id: \.id) { ch in
                    let on = device.isOnline(ch.id)
                    let current = ch.id == channelID
                    Button {
                        if !current { channelID = ch.id }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: current ? "play.circle.fill" : (on ? "video" : "video.slash"))
                                .foregroundStyle(current ? Color.accentColor : .secondary)
                                .frame(width: 24)
                            Text(device.displayName(ch.id))
                                .foregroundStyle(current ? Color.accentColor : (on ? .primary : .secondary))
                                .fontWeight(current ? .semibold : .regular)
                            Spacer()
                            Text(on ? "頻道 \(ch.index + 1)" : "離線").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!on)
                    .listRowBackground(current ? Color.accentColor.opacity(0.12) : nil)
                }
            } header: {
                Text("\(device.config.name)・切換頻道")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private struct StreamKey: Hashable {
        let channelID: String
        let main: Bool
        let conn: ObjectIdentifier
        let ready: Bool
        let visible: Bool
    }
}
