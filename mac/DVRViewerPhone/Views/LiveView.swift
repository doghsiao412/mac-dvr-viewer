import DVRKit
import SwiftUI

/// 單一頻道即時影像。直放時影像在上、控制在下；橫放時影像全螢幕，點一下顯示／隱藏控制。
struct LiveView: View {
    let device: DeviceModel
    let channelID: String

    @State private var controller = LiveTileController()
    @AppStorage("phone.live.mainStream") private var mainStream = false
    @AppStorage("phone.live.audio") private var audioOn = false
    @State private var showControls = true
    /// 畫面在最上層（推入回放頁時停止即時串流）
    @State private var visible = false
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.scenePhase) private var scenePhase

    private var landscape: Bool { vSize == .compact }

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
                    controls.padding()
                    Spacer()
                }
            }
        }
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

    private struct StreamKey: Hashable {
        let channelID: String
        let main: Bool
        let conn: ObjectIdentifier
        let ready: Bool
        let visible: Bool
    }
}
