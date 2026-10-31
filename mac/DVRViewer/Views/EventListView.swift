import DVRKit
import SwiftUI

/// 移動偵測等事件清單（回放頁「事件」按鈕的彈出面板）
///
/// 事件來源：DVR 錄影區段中非排程的類型（移動偵測錄影時每次移動一段），
/// 以及帳號有日誌權限時的系統日誌警報。點一下跳到該時間播放。
struct EventListView: View {
    struct Item: Identifiable, Hashable {
        let ref: CameraRef
        let event: DVRConnection.RecordEvent
        var id: String { ref.deviceID.uuidString + event.id }
    }

    let items: [Item]
    let loading: Bool
    /// 是否有多支攝影機（4 分割）：列出攝影機名稱與篩選
    let multiCamera: Bool
    /// 有任何一台 DVR 的帳號沒有日誌權限
    let logDenied: Bool
    let name: (CameraRef) -> String
    let current: Date?
    let onPick: (Item) -> Void

    @State private var typeFilter: String?
    @State private var cameraFilter: CameraRef?

    private var types: [String] { Array(Set(items.map(\.event.type))).sorted() }
    private var cameras: [CameraRef] {
        var seen = Set<CameraRef>()
        return items.map(\.ref).filter { seen.insert($0).inserted }
    }

    private var shown: [Item] {
        items.filter { (typeFilter == nil || $0.event.type == typeFilter) && (cameraFilter == nil || $0.ref == cameraFilter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("事件").font(.headline)
                if !items.isEmpty {
                    Text("\(shown.count) 筆").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                if types.count > 1 {
                    Picker("類型", selection: $typeFilter) {
                        Text("全部類型").tag(String?.none)
                        ForEach(types, id: \.self) { Text(PlaybackView.typeName($0)).tag(String?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
                if multiCamera && cameras.count > 1 {
                    Picker("攝影機", selection: $cameraFilter) {
                        Text("全部攝影機").tag(CameraRef?.none)
                        ForEach(cameras, id: \.self) { Text(name($0)).tag(CameraRef?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            .padding(12)
            Divider()

            if loading && items.isEmpty {
                ProgressView("查詢事件中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                empty
            } else {
                ScrollViewReader { proxy in
                    List(shown) { item in
                        row(item)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(item) }
                            .listRowBackground(isCurrent(item) ? Color.accentColor.opacity(0.15) : Color.clear)
                            .id(item.id)
                    }
                    .listStyle(.plain)
                    .onAppear {
                        // 捲到目前播放時間附近
                        if let c = current, let near = shown.last(where: { $0.event.start <= c }) ?? shown.first {
                            proxy.scrollTo(near.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 440)
    }

    private func isCurrent(_ item: Item) -> Bool {
        guard let c = current else { return false }
        let e = item.event
        return e.start <= c && c <= (e.end ?? e.start.addingTimeInterval(30))
    }

    private func row(_ item: Item) -> some View {
        let e = item.event
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(RecordTimeline.color(e.type)).frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.start, format: .dateTime.hour().minute().second())
                    .font(.body.monospacedDigit().weight(.medium))
                HStack(spacing: 6) {
                    Text(PlaybackView.typeName(e.type))
                    if let end = e.end {
                        Text(Self.duration(end.timeIntervalSince(e.start)))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if multiCamera {
                Text(name(item.ref)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.walk.motion").font(.largeTitle).foregroundStyle(.secondary)
            Text("這一天沒有事件").font(.headline)
            Text(logDenied
                 ? "這台 DVR 若是全天排程錄影，移動偵測不會另外切成事件。可在 DVR 的錄影設定改為「移動偵測錄影」，或使用有「日誌」權限的帳號登入，即可在這裡列出移動事件。"
                 : "這台 DVR 若是全天排程錄影，移動偵測不會另外切成事件。可在 DVR 的錄影設定改為「移動偵測錄影」。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func duration(_ s: TimeInterval) -> String {
        let n = Int(s.rounded())
        return n >= 60 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n) 秒"
    }
}
