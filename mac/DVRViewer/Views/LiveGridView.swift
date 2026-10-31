import SwiftUI

struct LiveGridView: View {
    @Environment(AppStore.self) private var store
    /// 即時畫面取得焦點時才處理 Delete，避免攔截輸入框的倒退鍵
    @FocusState private var gridFocused: Bool

    var body: some View {
        GeometryReader { geo in
            if let big = store.enlargedSlot {
                LiveSlotView(slot: big)
                    .padding(2)
                    .overlay(alignment: .topLeading) {
                        Button { store.toggleEnlarge(big) } label: {
                            Image(systemName: "chevron.backward")
                                .font(.body.weight(.semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .help("返回分割畫面（也可再雙擊畫面）")
                        .padding(12)
                    }
            } else {
                let n = Int(Double(store.gridLayout).squareRoot())
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
        .overlay(alignment: .bottom) {
            if store.pageCount > 1 && store.enlargedSlot == nil { PageControl() }
        }
        // 與回放一致：影像區黑底圓角，外框跟隨淺色／深色模式
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .simultaneousGesture(TapGesture().onEnded { gridFocused = true })
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            let slot = store.enlargedSlot ?? store.focusedSlot
            guard store.isCustomLive, store.slots.indices.contains(slot), store.slots[slot] != nil else { return .ignored }
            store.clear(slot: slot)
            return .handled
        }
        .onAppear { gridFocused = true }
    }
}

/// DVR 畫面的換頁控制（頻道數超過分割數時顯示）
struct PageControl: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            Button { store.changePage(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                .help("上一頁（⌘[）")
            Text("\(store.dvrPage + 1) / \(store.pageCount)")
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(minWidth: 48)
            Button { store.changePage(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                .help("下一頁（⌘]）")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 12)
    }
}

/// 一個格子：有頻道 → VideoTile；沒有 → 可拖放的空格
struct LiveSlotView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let slot: Int
    @State private var dropTargeted = false

    var body: some View {
        let ref = store.gridSlots[slot]
        ZStack {
            if let ref, let dev = store.device(ref.deviceID) {
                VideoTile(ref: ref, device: dev, mainStream: store.wantsMainStream(slot: slot),
                          aspect: store.aspect(slot: slot))
                    .contextMenu { menu(ref) }
            } else {
                VStack(spacing: 6) {
                    if store.isCustomLive {
                        Image(systemName: "plus.viewfinder").font(.title2)
                        Text("點選左側頻道或拖曳到這裡").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
            }
        }
        .overlay {
            Rectangle()
                .strokeBorder(dropTargeted ? Color.accentColor : (store.focusedSlot == slot && store.gridLayout > 1 ? Color.accentColor.opacity(0.8) : .clear),
                              lineWidth: 2)
        }
        .contentShape(Rectangle())
        // 單擊立即選取（若用 onTapGesture 會等雙擊判定逾時才觸發，感覺卡頓）
        .onTapGesture(count: 2) { if ref != nil { store.toggleEnlarge(slot) } }
        .simultaneousGesture(TapGesture().onEnded { if store.focusedSlot != slot { store.focusedSlot = slot } })
        .dropDestination(for: String.self) { items, _ in
            guard store.isCustomLive, let t = items.first, let r = CameraRef(token: t) else { return false }
            store.assign(r, to: slot)
            return true
        } isTargeted: { dropTargeted = $0 && store.isCustomLive }
    }

    @ViewBuilder
    private func menu(_ ref: CameraRef) -> some View {
        Button(store.enlargedSlot == slot ? "還原分割畫面" : "放大") { store.toggleEnlarge(slot) }
        Button("在新視窗開啟") { openWindow(id: "camera", value: ref) }
        Button("重新命名…") { store.renaming = ref }
        Divider()
        if store.advancedFeatures {
            Picker("串流", selection: Binding(get: { store.wantsMainStream(slot: slot) },
                                            set: { store.cameraMainStream[ref] = $0 })) {
                Text("子串流（流暢）").tag(false)
                Text("主串流（高畫質）").tag(true)
            }
        }
        Picker("畫面比例", selection: Binding(get: { store.cameraAspect[ref] ?? .fit },
                                          set: { store.cameraAspect[ref] = $0 })) {
            ForEach(VideoAspect.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("回放此頻道錄影") { store.mode = .playback; store.showInPlayback(ref) }
        if store.isCustomLive {
            Button("從畫面移除") { store.clear(slot: slot) }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }
}
