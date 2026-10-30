import SwiftUI

struct LiveGridView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            if let big = store.enlargedSlot {
                LiveSlotView(slot: big)
                    .padding(2)
            } else {
                let n = Int(Double(store.layout).squareRoot())
                let w = (geo.size.width - CGFloat(n + 1) * 2) / CGFloat(n)
                let h = (geo.size.height - CGFloat(n + 1) * 2) / CGFloat(n)
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(0..<n, id: \.self) { r in
                        GridRow {
                            ForEach(0..<n, id: \.self) { c in
                                LiveSlotView(slot: r * n + c)
                                    .frame(width: w, height: h)
                            }
                        }
                    }
                }
                .padding(2)
            }
        }
        .background(Color.black)
    }
}

/// 一個格子：有頻道 → VideoTile；沒有 → 可拖放的空格
struct LiveSlotView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let slot: Int
    @State private var dropTargeted = false

    var body: some View {
        let ref = store.slots[slot]
        ZStack {
            if let ref, let dev = store.device(ref.deviceID) {
                VideoTile(ref: ref, device: dev, mainStream: store.wantsMainStream(slot: slot),
                          aspect: store.slotAspect[slot] ?? .fit)
                    .contextMenu { menu(ref) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus.viewfinder").font(.title2)
                    Text("點選左側頻道或拖曳到這裡").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
            }
        }
        .overlay {
            Rectangle()
                .strokeBorder(dropTargeted ? Color.accentColor : (store.focusedSlot == slot && store.layout > 1 ? Color.accentColor.opacity(0.8) : .clear),
                              lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if ref != nil { store.toggleEnlarge(slot) } }
        .onTapGesture { store.focusedSlot = slot }
        .dropDestination(for: String.self) { items, _ in
            guard let t = items.first, let r = CameraRef(token: t) else { return false }
            store.assign(r, to: slot)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder
    private func menu(_ ref: CameraRef) -> some View {
        Button(store.enlargedSlot == slot ? "還原分割畫面" : "放大") { store.toggleEnlarge(slot) }
        Button("在新視窗開啟") { openWindow(id: "camera", value: ref) }
        Divider()
        Picker("串流", selection: Binding(get: { store.wantsMainStream(slot: slot) },
                                        set: { store.slotMainStream[slot] = $0 })) {
            Text("子串流（流暢）").tag(false)
            Text("主串流（高畫質）").tag(true)
        }
        Picker("畫面比例", selection: Binding(get: { store.slotAspect[slot] ?? .fit },
                                          set: { store.slotAspect[slot] = $0 })) {
            ForEach(VideoAspect.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("回放此頻道錄影") { store.playbackRef = ref; store.mode = .playback }
        Button("從畫面移除") { store.clear(slot: slot) }
    }
}
