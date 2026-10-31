import DVRKit
import SwiftUI

/// 移動偵測等事件清單：點一下跳到該時間播放
struct EventsSheet: View {
    let events: [DVRConnection.RecordEvent]
    let loading: Bool
    let current: Date?
    let onPick: (DVRConnection.RecordEvent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typeFilter: String?

    private var types: [String] { Array(Set(events.map(\.type))).sorted() }
    private var shown: [DVRConnection.RecordEvent] {
        guard let typeFilter else { return events }
        return events.filter { $0.type == typeFilter }
    }

    var body: some View {
        NavigationStack {
            List(shown) { e in
                Button {
                    onPick(e)
                    dismiss()
                } label: {
                    row(e)
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if loading && events.isEmpty {
                    ProgressView("查詢事件…")
                } else if events.isEmpty {
                    ContentUnavailableView("這天沒有事件", systemImage: "figure.walk.motion",
                                           description: Text("事件來自 DVR 的移動偵測等錄影區段；全天連續錄影時 DVR 不會另外切出事件。"))
                }
            }
            .navigationTitle("事件（\(shown.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                if types.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("類型", selection: $typeFilter) {
                                Text("全部").tag(String?.none)
                                ForEach(types, id: \.self) { Text(TimelineStyle.typeName($0)).tag(String?.some($0)) }
                            }
                        } label: {
                            Label("篩選", systemImage: typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ e: DVRConnection.RecordEvent) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(TimelineStyle.color(e.type)).frame(width: 4, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.start, format: .dateTime.hour().minute().second())
                    .font(.body.monospacedDigit().weight(isCurrent(e) ? .bold : .regular))
                Text(TimelineStyle.typeName(e.type)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let end = e.end {
                Text(Self.duration(end.timeIntervalSince(e.start))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if isCurrent(e) {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(TimelineStyle.playhead)
            }
        }
        .contentShape(.rect)
    }

    private func isCurrent(_ e: DVRConnection.RecordEvent) -> Bool {
        guard let current, let end = e.end else { return false }
        return e.start <= current && current < end
    }

    static func duration(_ s: TimeInterval) -> String {
        let n = Int(s.rounded())
        return n >= 60 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n) 秒"
    }
}
