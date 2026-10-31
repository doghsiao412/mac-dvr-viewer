import DVRKit
import SwiftUI

/// iPhone 畫面之間的導覽目標
enum PhoneRoute: Hashable {
    case live(CameraRef)
    case playback(CameraRef)
}

/// 一台 DVR 的 4 分割即時影像：左右滑動換頁，點一下放大，長按可進入錄影回放。
/// 只有目前這一頁、且畫面在最上層時才連線，避免浪費頻寬與 DVR 連線數。
struct ChannelGridView: View {
    let device: DeviceModel
    @State private var page = 0
    @State private var visible = false

    private var pages: [[DVRChannel]] {
        let chs = device.orderedChannels
        return stride(from: 0, to: chs.count, by: 4).map { Array(chs[$0..<min($0 + 4, chs.count)]) }
    }

    var body: some View {
        Group {
            if device.channels.isEmpty {
                emptyState
            } else {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, chs in
                        GridPage(device: device, channels: chs, active: visible && page == i)
                            .padding(.horizontal, 8)
                            .padding(.bottom, pages.count > 1 ? 36 : 0)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
            }
        }
        .navigationTitle(device.config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if pages.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(page + 1)／\(pages.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    @ViewBuilder private var emptyState: some View {
        switch device.status {
        case .online:
            ContentUnavailableView("沒有頻道", systemImage: "video.slash")
        case .error(let e):
            ContentUnavailableView {
                Label("無法連線", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e)
            } actions: {
                Button("重新連線") { device.reconnect() }
            }
        default:
            ProgressView("連線中…")
        }
    }
}

/// 一頁 2×2，依可用空間縮放成 16:9 格子
private struct GridPage: View {
    let device: DeviceModel
    let channels: [DVRChannel]
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let w = min((geo.size.width - spacing) / 2, ((geo.size.height - spacing) / 2) * 16 / 9)
            let h = w * 9 / 16
            VStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<2, id: \.self) { col in
                            let i = row * 2 + col
                            if i < channels.count {
                                GridTile(device: device, channel: channels[i], active: active)
                                    .frame(width: w, height: h)
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: w, height: h)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GridTile: View {
    let device: DeviceModel
    let channel: DVRChannel
    let active: Bool
    @State private var controller = LiveTileController()

    private var ref: CameraRef { CameraRef(deviceID: device.id, channelID: channel.id) }
    private var online: Bool { device.isOnline(channel.id) }

    var body: some View {
        NavigationLink(value: PhoneRoute.live(ref)) {
            ZStack(alignment: .bottomLeading) {
                VideoSurface(renderer: controller.renderer, aspect: .fill)
                overlay.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(device.displayName(channel.id))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black, radius: 2)
                    .padding(6)
            }
            .background(.black)
            .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!online)
        .contextMenu {
            NavigationLink(value: PhoneRoute.live(ref)) { Label("放大觀看", systemImage: "arrow.up.left.and.arrow.down.right") }
            NavigationLink(value: PhoneRoute.playback(ref)) { Label("錄影回放", systemImage: "clock.arrow.circlepath") }
        }
        .task(id: Key(active: active && online, ready: device.webStreaming != nil, conn: ObjectIdentifier(device.connection))) {
            guard active, online, device.webStreaming != nil else { return }
            await controller.run(connection: device.connection, channelID: channel.id, mainStream: false)
        }
    }

    @ViewBuilder private var overlay: some View {
        if !online {
            Label("離線", systemImage: "video.slash").font(.caption).foregroundStyle(.white.opacity(0.7))
        } else {
            switch controller.phase {
            case .playing: EmptyView()
            case .reconnecting: ProgressView().tint(.white.opacity(0.7))
            case .idle, .connecting: ProgressView().tint(.white.opacity(0.7))
            }
        }
    }

    private struct Key: Hashable {
        let active: Bool
        let ready: Bool
        let conn: ObjectIdentifier
    }
}
