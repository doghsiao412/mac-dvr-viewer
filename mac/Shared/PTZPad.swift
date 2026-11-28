import DVRKit
import SwiftUI

/// 雲台控制面板：按住方向／變焦／對焦鍵移動，放開即停止（DVR 網頁 PtzCtrl.js 相同做法）
struct PTZPad: View {
    let connection: DVRConnection
    let channelID: String
    var onError: (String) -> Void
    /// 自己畫玻璃底。放在已經是玻璃的地方（例如 iPhone 的工作表）時設為 false，避免玻璃疊玻璃
    var glassBackground = true

    @AppStorage("ptzSpeed") private var speed = 4.0
    @State private var presets: [(index: Int, name: String)] = []
    @State private var active: DVRConnection.PTZAction?
    @State private var queue = PTZSendQueue()

    private typealias A = DVRConnection.PTZAction
    #if os(iOS)
    private let keySize: CGFloat = 50   // 手指操作
    #else
    private let keySize: CGFloat = 32
    #endif

    var body: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow { key(.leftUp, "arrow.up.left"); key(.up, "arrow.up"); key(.rightUp, "arrow.up.right") }
                GridRow {
                    key(.left, "arrow.left")
                    Image(systemName: "video").font(.caption).foregroundStyle(.secondary).frame(width: keySize, height: keySize)
                        .accessibilityHidden(true)
                    key(.right, "arrow.right")
                }
                GridRow { key(.leftDown, "arrow.down.left"); key(.down, "arrow.down"); key(.rightDown, "arrow.down.right") }
            }
            HStack(spacing: 12) {
                // DVR 指令名稱與畫面效果相反：網頁的「放大」鍵送 ZoomOut（js/lib/PtzCtrl.js：zoomIn → ZoomOut），使用者實測確認
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        key(.zoomIn, "minus.magnifyingglass", help: "縮小（拉遠）")
                        key(.zoomOut, "plus.magnifyingglass", help: "放大（拉近）")
                    }
                    Text("變焦").font(.caption2)
                }
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        key(.near, text: "近", help: "對焦近處（讓近的東西清楚）")
                        key(.far, text: "遠", help: "對焦遠處（讓遠的東西清楚）")
                    }
                    Text("對焦").font(.caption2)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "tortoise").font(.caption2)
                Slider(value: $speed, in: 1...8, step: 1).frame(width: keySize * 3).controlSize(.mini)
                Image(systemName: "hare").font(.caption2)
            }
            .help("雲台速度 \(Int(speed))")
            if !presets.isEmpty {
                Menu {
                    ForEach(presets, id: \.index) { p in
                        Button(p.name.isEmpty ? "預置點 \(p.index)" : p.name) { goTo(p.index) }
                    }
                } label: { Label("預置點", systemImage: "mappin.and.ellipse") }
                #if os(macOS)
                .menuStyle(.button)
                #endif
                .buttonStyle(.bordered).controlSize(.small).fixedSize()   // 面板本身是玻璃：按鈕不再疊玻璃
            }
        }
        .padding(12)
        .modifier(PTZGlass(enabled: glassBackground))
        .task(id: channelID) { presets = (try? await connection.ptzPresets(channelId: channelID)) ?? [] }
        .onDisappear { if active != nil { send(.stop) } }
    }

    /// 按住送動作、放開送停止
    private func key(_ action: A, _ symbol: String? = nil, text: String? = nil, help: String? = nil) -> some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.callout.weight(.semibold)) }
            else { Text(text ?? "").font(.callout.weight(.semibold)) }
        }
        .frame(width: keySize, height: keySize)
        .background(active == action ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.08)), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .help(help ?? "")
        // 旁白：讀成按鈕；啟動時轉動約半秒後停止（按住的手勢旁白使用者做不到）
        .accessibilityElement()
        .accessibilityLabel(help ?? Self.accessibilityName(action))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            send(action)
            Task { try? await Task.sleep(for: .milliseconds(500)); send(.stop) }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard active == nil else { return }
                active = action
                send(action)
            }
            .onEnded { _ in
                guard active != nil else { return }
                active = nil
                send(.stop)
            })
    }

    private static func accessibilityName(_ a: A) -> String {
        switch a {
        case .up: return "向上"
        case .down: return "向下"
        case .left: return "向左"
        case .right: return "向右"
        case .leftUp: return "左上"
        case .leftDown: return "左下"
        case .rightUp: return "右上"
        case .rightDown: return "右下"
        case .zoomIn: return "縮小"
        case .zoomOut: return "放大"
        case .near: return "對焦近處"
        case .far: return "對焦遠處"
        case .irisOpen: return "光圈開大"
        case .irisClose: return "光圈縮小"
        case .stop: return "停止"
        }
    }

    private func send(_ action: A) {
        let s = Int(speed), conn = connection, id = channelID, report = onError
        queue.enqueue {
            do { try await conn.ptzMove(channelId: id, action: action, speed: s) }
            catch { await MainActor.run { report("雲台控制失敗：\(DeviceModel.describe(error))") } }
        }
    }

    private func goTo(_ index: Int) {
        let s = Int(speed), conn = connection, id = channelID, report = onError
        queue.enqueue {
            do { try await conn.ptzGoToPreset(channelId: id, index: index, speed: s) }
            catch { await MainActor.run { report("預置點失敗：\(DeviceModel.describe(error))") } }
        }
    }
}

/// 依序送出雲台指令（「移動」一定在「停止」之前抵達，避免放開後鏡頭繼續轉）
@MainActor
final class PTZSendQueue {
    private var last: Task<Void, Never>?

    func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let prev = last
        last = Task { await prev?.value; await op() }
    }
}

/// 雲台面板的玻璃底（加上「浮現」轉場）；enabled 為 false 時不畫
private struct PTZGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectTransition(.materialize)
        } else {
            content
        }
    }
}
