import AppKit
import DVRKit
import Foundation
import Observation

/// App 全域狀態：設備清單、模式、Live 版面、回放選擇、偏好設定。
@Observable
@MainActor
final class AppStore {
    static let maxSlots = 16

    private(set) var devices: [DeviceModel] = []
    var mode: ViewMode = .live { didSet { saveUI() } }

    // Live
    var layout: Int = 4 { didSet { saveUI() } }          // 1 / 4 / 9 / 16
    var slots: [CameraRef?] = Array(repeating: nil, count: AppStore.maxSlots) { didSet { saveUI() } }
    var focusedSlot: Int = 0
    var enlargedSlot: Int?
    var slotMainStream: [Int: Bool] = [:]
    var slotAspect: [Int: VideoAspect] = [:]

    // Playback
    var playbackRef: CameraRef? { didSet { saveUI() } }

    // 偏好設定
    var useMainStreamWhenEnlarged: Bool = UserDefaults.standard.bool(forKey: "useMainStreamWhenEnlarged") {
        didSet { UserDefaults.standard.set(useMainStreamWhenEnlarged, forKey: "useMainStreamWhenEnlarged") }
    }

    // 提示訊息
    var toast: String?

    // 聲音：即時畫面同時只有一格出聲
    var audioRef: CameraRef?
    var volume: Double = (UserDefaults.standard.object(forKey: "volume") as? Double) ?? 0.8 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }

    // 錄影下載
    let exports = ExportManager()
    /// 開始下載時遞增：觸發「飛到右上角」動畫
    var downloadFlight = 0
    /// 動畫落地時遞增：工具列下載按鈕彈跳
    var downloadLanded = 0

    // 側邊欄：已收合的設備（記憶於 UserDefaults）
    var collapsedDevices: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: "collapsedDevices") ?? []).compactMap(UUID.init)
    ) {
        didSet { UserDefaults.standard.set(collapsedDevices.map(\.uuidString), forKey: "collapsedDevices") }
    }

    func isExpanded(_ id: UUID) -> Bool { !collapsedDevices.contains(id) }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { collapsedDevices.remove(id) } else { collapsedDevices.insert(id) }
    }

    func setAllExpanded(_ expanded: Bool) {
        collapsedDevices = expanded ? [] : Set(devices.map(\.id))
    }

    init() {
        devices = DevicePersistence.load().map(DeviceModel.init)
        loadUI()
        devices.forEach { $0.start() }
    }

    // MARK: - 設備

    func device(_ id: UUID) -> DeviceModel? { devices.first { $0.id == id } }

    func add(_ config: DeviceConfig, password: String) throws {
        try KeychainStore.setPassword(password, for: config.id)
        let m = DeviceModel(config: config)
        devices.append(m)
        persistDevices()
        m.start()
        // 第一台設備：自動把前幾個頻道放進 Live 版面
        if slots.allSatisfy({ $0 == nil }) { autoFillSlots(from: m) }
    }

    func update(_ config: DeviceConfig, password: String?) throws {
        if let password, !password.isEmpty { try KeychainStore.setPassword(password, for: config.id) }
        guard let m = device(config.id) else { return }
        m.apply(config)
        if password?.isEmpty == false { m.reconnect() }
        persistDevices()
    }

    func remove(_ id: UUID) {
        guard let m = device(id) else { return }
        m.stop()
        devices.removeAll { $0.id == id }
        KeychainStore.deletePassword(for: id)
        slots = slots.map { $0?.deviceID == id ? nil : $0 }
        if playbackRef?.deviceID == id { playbackRef = nil }
        if liveDeviceID == id { liveDeviceID = nil }
        persistDevices()
    }

    func persistDevices() { DevicePersistence.save(devices.map(\.config)) }

    func rename(_ ref: CameraRef, to name: String) {
        guard let m = device(ref.deviceID) else { return }
        var c = m.config
        c.channelAliases[ref.channelID] = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        m.apply(c)
        persistDevices()
    }

    func moveChannel(_ ref: CameraRef, before target: CameraRef) {
        guard ref.deviceID == target.deviceID, let m = device(ref.deviceID) else { return }
        var ids = m.orderedChannels.map(\.id)
        ids.removeAll { $0 == ref.channelID }
        let idx = ids.firstIndex(of: target.channelID) ?? ids.count
        ids.insert(ref.channelID, at: idx)
        var c = m.config
        c.channelOrder = ids
        m.apply(c)
        persistDevices()
    }

    /// 正在重新命名的頻道（側邊欄雙擊、右鍵、即時畫面右鍵都會設定；對話框在主視窗）
    var renaming: CameraRef?

    // MARK: - 切換 DVR

    /// 即時畫面目前顯示的 DVR（nil＝自訂畫面）。
    /// DVR 畫面：依側邊欄順序顯示該 DVR 的所有頻道，格子內容不能修改。
    /// 自訂畫面：`slots`／`layout`，由使用者從左側自行加入。
    var liveDeviceID: UUID? {
        didSet {
            guard liveDeviceID != oldValue else { return }
            enlargedSlot = nil
            focusedSlot = 0
            dvrPage = 0
            audioRef = nil
            saveUI()
        }
    }

    var isCustomLive: Bool { liveDeviceID == nil }

    /// 目前畫面上的 DVR：即時＝DVR 畫面的設備（自訂畫面為 nil）；回放＝目前回放的設備
    var currentDeviceID: UUID? {
        mode == .playback ? playbackRef?.deviceID : liveDeviceID
    }

    /// DVR 畫面的分割數（可選 1／4／9／16，頻道超過時分頁）與目前頁碼
    var dvrLayout: Int = (UserDefaults.standard.object(forKey: "dvrLayout") as? Int) ?? 16 {
        didSet { UserDefaults.standard.set(dvrLayout, forKey: "dvrLayout") }
    }
    var dvrPage = 0

    private var liveDeviceChannels: [DVRChannel] {
        liveDeviceID.flatMap { device($0) }?.orderedChannels ?? []
    }

    /// DVR 畫面的總頁數（自訂畫面為 1）
    var pageCount: Int {
        guard !isCustomLive else { return 1 }
        return max(1, (liveDeviceChannels.count + dvrLayout - 1) / dvrLayout)
    }

    /// 畫面實際顯示的格子與分割數
    var gridSlots: [CameraRef?] {
        guard let id = liveDeviceID else { return slots }
        var r = [CameraRef?](repeating: nil, count: Self.maxSlots)
        let chs = liveDeviceChannels
        let start = min(dvrPage, pageCount - 1) * dvrLayout
        for (i, c) in chs.dropFirst(start).prefix(dvrLayout).enumerated() { r[i] = CameraRef(deviceID: id, channelID: c.id) }
        return r
    }

    var gridLayout: Int { isCustomLive ? layout : dvrLayout }

    /// DVR 畫面換頁（循環）
    func changePage(by offset: Int) {
        guard !isCustomLive, pageCount > 1 else { return }
        enlargedSlot = nil
        focusedSlot = 0
        dvrPage = ((dvrPage + offset) % pageCount + pageCount) % pageCount
    }

    /// 切換到自訂畫面
    func switchToCustom() {
        if mode == .playback { mode = .live }
        liveDeviceID = nil
    }

    /// 把整個畫面切到另一台 DVR。
    /// 即時：顯示該 DVR 的所有頻道。回放：切到同一個頻道編號（沒有則第一個頻道），日期不變。
    func switchTo(_ id: UUID) {
        guard let target = device(id) else { return }
        if mode == .playback {
            let idx = playbackRef.flatMap { r in device(r.deviceID)?.orderedChannels.firstIndex { $0.id == r.channelID } } ?? 0
            let chs = target.orderedChannels
            if let ch = chs.indices.contains(idx) ? chs[idx] : chs.first {
                playbackRef = CameraRef(deviceID: id, channelID: ch.id)
            } else {
                showToast("「\(target.config.name)」尚未載入頻道")
            }
            return
        }
        liveDeviceID = id
    }

    /// 切到上一台／下一台 DVR（依側邊欄順序）
    func switchDevice(by offset: Int) {
        guard !devices.isEmpty else { return }
        let i = currentDeviceID.flatMap { id in devices.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
        let n = devices.count
        switchTo(devices[((i + offset) % n + n) % n].id)
    }

    func name(of ref: CameraRef) -> String {
        device(ref.deviceID)?.displayName(ref.channelID) ?? "頻道"
    }

    // MARK: - Live 版面

    var visibleSlotCount: Int { layout }

    func assign(_ ref: CameraRef, to slot: Int) {
        guard isCustomLive, slot >= 0, slot < Self.maxSlots else { return }
        slots[slot] = ref
        focusedSlot = slot
    }

    /// 點側邊欄頻道：放到目前選取的格子，並移到下一格
    func showInLive(_ ref: CameraRef) {
        // DVR 畫面：選取該頻道（其他 DVR 的頻道則先切到那台）
        if !isCustomLive {
            if liveDeviceID != ref.deviceID { liveDeviceID = ref.deviceID }
            if let i = liveDeviceChannels.firstIndex(where: { $0.id == ref.channelID }) {
                if dvrPage != i / dvrLayout { enlargedSlot = nil; dvrPage = i / dvrLayout }
                focusedSlot = i % dvrLayout
            }
            return
        }
        if let existing = slots.prefix(layout).firstIndex(of: ref) {
            focusedSlot = existing
            return
        }
        assign(ref, to: min(focusedSlot, layout - 1))
        focusedSlot = (focusedSlot + 1) % layout
    }

    func clear(slot: Int) {
        guard isCustomLive else { return }
        slots[slot] = nil
        if enlargedSlot == slot { enlargedSlot = nil }
    }

    func setLayout(_ n: Int) {
        if !isCustomLive {
            // DVR 畫面：保持目前選取的頻道在新的頁面上
            let index = dvrPage * dvrLayout + focusedSlot
            dvrLayout = n
            dvrPage = index / n
            focusedSlot = index % n
            enlargedSlot = nil
            return
        }
        layout = n
        enlargedSlot = nil
        if focusedSlot >= n { focusedSlot = 0 }
    }

    func toggleEnlarge(_ slot: Int) {
        enlargedSlot = enlargedSlot == slot ? nil : slot
        focusedSlot = slot
    }

    func autoFillSlots(from m: DeviceModel) {
        Task { @MainActor in
            // 等待頻道載入
            for _ in 0..<40 where m.channels.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            let chs = m.orderedChannels.prefix(layout)
            for (i, c) in chs.enumerated() where slots[i] == nil {
                slots[i] = CameraRef(deviceID: m.id, channelID: c.id)
            }
        }
    }

    /// 放大時是否使用主串流（實測此 DVR 主串流遠端約 1 fps，故預設使用子串流）
    func wantsMainStream(slot: Int) -> Bool {
        if let v = slotMainStream[slot] { return v }
        return enlargedSlot == slot && useMainStreamWhenEnlarged
    }

    // MARK: - 提示

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    // MARK: - 視窗／版面記憶

    private struct UIState: Codable {
        var mode: ViewMode
        var layout: Int
        var slots: [CameraRef?]
        var playbackRef: CameraRef?
        var liveDeviceID: UUID?
    }

    private var loadingUI = false

    private func saveUI() {
        guard !loadingUI else { return }
        let s = UIState(mode: mode, layout: layout, slots: slots, playbackRef: playbackRef, liveDeviceID: liveDeviceID)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "uiState") }
    }

    private func loadUI() {
        loadingUI = true
        defer { loadingUI = false }
        guard let d = UserDefaults.standard.data(forKey: "uiState"),
              let s = try? JSONDecoder().decode(UIState.self, from: d) else { return }
        mode = s.mode
        layout = [1, 4, 9, 16].contains(s.layout) ? s.layout : 4
        var sl = s.slots
        if sl.count < Self.maxSlots { sl += Array(repeating: nil, count: Self.maxSlots - sl.count) }
        let ids = Set(devices.map(\.id))
        slots = Array(sl.prefix(Self.maxSlots)).map { r in r.flatMap { ids.contains($0.deviceID) ? $0 : nil } }
        playbackRef = s.playbackRef.flatMap { ids.contains($0.deviceID) ? $0 : nil }
        liveDeviceID = s.liveDeviceID.flatMap { ids.contains($0) ? $0 : nil }
    }

    // MARK: - 截圖

    static var snapshotFolder: URL {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appending(path: "DVR Viewer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func saveSnapshot(_ pb: CVPixelBuffer?, name: String, time: Date?) {
        guard let pb else { showToast("目前沒有畫面可截圖"); return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = Self.snapshotFolder.appending(path: "\(safe)-\(f.string(from: time ?? Date())).jpg")
        do {
            try Snapshot.writeJPEG(pb, to: url)
            showToast("已儲存截圖：\(url.lastPathComponent)")
        } catch {
            showToast("截圖失敗：\(error.localizedDescription)")
        }
    }
}
