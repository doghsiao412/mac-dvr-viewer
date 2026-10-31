import DVRKit
import SwiftUI

/// iPhone 畫面之間的導覽目標
enum PhoneRoute: Hashable {
    case live(CameraRef)
    case playback(CameraRef)
}

/// 一台 DVR 的分割即時影像：左右滑動換頁，點一下放大，長按可進入錄影回放。
/// 分割數預設依螢幕大小自動決定（格子寬度至少約 180 pt 時盡量多放），也可手動選擇。
/// 只有目前這一頁、且畫面在最上層時才連線，避免浪費頻寬與 DVR 連線數。
struct ChannelGridView: View {
    let device: DeviceModel
    @State private var page = 0
    @State private var visible = false
    /// 0 = 自動；其他為每頁格數
    @AppStorage("phone.grid.capacity") private var capacity = 0
    @Environment(\.scenePhase) private var scenePhase

    private static let spacing: CGFloat = 4
    /// 不顯示底部頁碼點（右上角已有「1／2」），空間全部給畫面
    private static let dotsHeight: CGFloat = 0
    private static let capacities = [1, 4, 6, 9, 16]

    var body: some View {
        Group {
            if device.channels.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let chs = device.orderedChannels
                    let area = CGSize(width: geo.size.width - 8, height: geo.size.height)
                    let g = Self.layout(for: area, total: chs.count, capacity: capacity)
                    let per = g.cols * g.rows
                    let pages = stride(from: 0, to: chs.count, by: per).map { Array(chs[$0..<min($0 + per, chs.count)]) }
                    TabView(selection: $page) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { i, list in
                            GridPage(device: device, channels: list, cols: g.cols, rows: g.rows,
                                     active: visible && page == i && scenePhase != .background)
                                .padding(.horizontal, 4)
                                .padding(.bottom, pages.count > 1 ? Self.dotsHeight : 0)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: pages.count) { _, n in page = min(page, max(n - 1, 0)) }
                    .toolbar {
                        if pages.count > 1 {
                            ToolbarItem(placement: .topBarTrailing) {
                                Text("\(min(page, pages.count - 1) + 1)／\(pages.count)")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(device.config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("分割", selection: $capacity) {
                        Text("自動（依螢幕大小）").tag(0)
                        ForEach(Self.capacities, id: \.self) { n in
                            Text(n == 1 ? "單一畫面" : "\(n) 分割").tag(n)
                        }
                    }
                } label: {
                    Label("分割", systemImage: "square.grid.2x2")
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    /// 決定欄數與列數：
    /// - 自動：在格子寬度 ≥ 180 pt 的前提下，一頁放最多頻道（不超過 16、不超過頻道總數），同數量時選格子較大的
    /// - 指定格數：找出放得下該數量、格子最大的欄列組合
    static func layout(for size: CGSize, total: Int, capacity: Int) -> (cols: Int, rows: Int) {
        func tileWidth(_ c: Int, _ r: Int, paging: Bool) -> CGFloat {
            let h = size.height - (paging ? dotsHeight : 0)
            let byW = (size.width - CGFloat(c - 1) * spacing) / CGFloat(c)
            let byH = (h - CGFloat(r - 1) * spacing) / CGFloat(r) * 16 / 9
            return max(min(byW, byH), 0)
        }
        var best = (cols: 2, rows: 2, shown: 0, w: CGFloat(0))
        for c in 1...5 {
            for r in 1...5 {
                let cap = c * r
                if capacity > 0 {
                    // 指定格數：欄列剛好容納（不多出一整排空格）
                    guard cap >= capacity, cap - capacity < min(c, r) else { continue }
                    let w = tileWidth(c, r, paging: total > capacity)
                    if w > best.w { best = (c, r, capacity, w) }
                } else {
                    guard cap <= 16 else { continue }
                    let w = tileWidth(c, r, paging: total > cap)
                    let shown = min(cap, total)
                    guard w >= 180 || (c == 1 && r == 1) else { continue }
                    // 頻道數相同時，不要多出用不到的格子；其次選格子較大的
                    if shown > best.shown || (shown == best.shown && (cap < best.cols * best.rows || (cap == best.cols * best.rows && w > best.w))) {
                        best = (c, r, shown, w)
                    }
                }
            }
        }
        return (best.cols, best.rows)
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

/// 一頁 cols×rows，依可用空間縮放成 16:9 格子
private struct GridPage: View {
    let device: DeviceModel
    let channels: [DVRChannel]
    let cols: Int
    let rows: Int
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let w = min((geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols),
                        ((geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)) * 16 / 9)
            let h = w * 9 / 16
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<cols, id: \.self) { col in
                            let i = row * cols + col
                            if i < channels.count {
                                // 以頻道 ID 識別格子：版面改變（例如摺疊／展開）後，同一位置換成別的頻道時重建播放器，
                                // 否則會留著前一個頻道的影像、只換名稱
                                GridTile(device: device, channel: channels[i], active: active)
                                    .id(channels[i].id)
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
        .task(id: Key(channelID: channel.id, active: active && online, ready: device.webStreaming != nil, conn: ObjectIdentifier(device.connection))) {
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
            case .reconnecting(let why) where why.contains("序號不符"):
                // 影像服務 Port 指向另一台 DVR：提示修正設定（不顯示別台的畫面）
                Label("影像服務 Port 設定錯誤", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.yellow).multilineTextAlignment(.center).padding(4)
            case .reconnecting: ProgressView().tint(.white.opacity(0.7))
            case .idle, .connecting: ProgressView().tint(.white.opacity(0.7))
            }
        }
    }

    private struct Key: Hashable {
        let channelID: String
        let active: Bool
        let ready: Bool
        let conn: ObjectIdentifier
    }
}
