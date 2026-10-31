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
    // 目前自訂畫面的工作副本（變更會寫回 customViews）
    var layout: Int = 4 { didSet { syncCustom() } }          // 1 / 4 / 9 / 16
    var slots: [CameraRef?] = Array(repeating: nil, count: AppStore.maxSlots) { didSet { syncCustom() } }

    /// 使用者建立的自訂畫面（可新增、移除、命名）
    struct CustomView: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var layout: Int = 4
        var slots: [CameraRef?] = Array(repeating: nil, count: AppStore.maxSlots)
    }
    var customViews: [CustomView] = [] { didSet { saveUI() } }
    private(set) var customID: UUID?
    var currentCustom: CustomView? { customViews.first { $0.id == customID } }

    private func syncCustom() {
        guard !loadingUI, let i = customViews.firstIndex(where: { $0.id == customID }) else { saveUI(); return }
        if customViews[i].slots != slots || customViews[i].layout != layout {
            customViews[i].slots = slots
            customViews[i].layout = layout
        }
    }
    var focusedSlot: Int = 0
    var enlargedSlot: Int?
    /// 每支攝影機的個別設定（跟著攝影機走，換頁、切 DVR、換自訂畫面都不會套到別支）
    var cameraMainStream: [CameraRef: Bool] = AppStore.loadDict("cameraMainStream") {
        didSet { Self.saveDict(cameraMainStream, "cameraMainStream") }
    }
    var cameraAspect: [CameraRef: VideoAspect] = AppStore.loadDict("cameraAspect") {
        didSet { Self.saveDict(cameraAspect, "cameraAspect") }
    }

    private static func loadDict<V: Codable>(_ key: String) -> [CameraRef: V] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([CameraRef: V].self, from: d) else { return [:] }
        return v
    }
    private static func saveDict<V: Codable>(_ v: [CameraRef: V], _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// 格子目前的畫面比例
    func aspect(slot: Int) -> VideoAspect {
        gridSlots[slot].flatMap { cameraAspect[$0] } ?? .fit
    }

    /// 進階功能（主／子串流選擇等）。一般使用者不需要：App 依實測自動使用最佳設定
    var advancedFeatures: Bool = UserDefaults.standard.bool(forKey: "advancedFeatures") {
        didSet { UserDefaults.standard.set(advancedFeatures, forKey: "advancedFeatures") }
    }

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
        Notifier.shared.activate()
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
        for i in customViews.indices { customViews[i].slots = customViews[i].slots.map { $0?.deviceID == id ? nil : $0 } }
        slots = slots.map { $0?.deviceID == id ? nil : $0 }
        if playbackRef?.deviceID == id { playbackRef = nil }
        if liveDeviceID == id { liveDeviceID = nil }
        persistDevices()
    }

    func persistDevices() { DevicePersistence.save(devices.map(\.config)) }

    // MARK: - DVR 排序（側邊欄、切換選單與 ⌥⌘1–9 都依此順序）

    /// 把 DVR 移到另一台的前面（拖曳排序）
    func moveDevice(_ id: UUID, before target: UUID) {
        guard id != target, let from = devices.firstIndex(where: { $0.id == id }) else { return }
        let m = devices.remove(at: from)
        let to = devices.firstIndex(where: { $0.id == target }) ?? devices.count
        devices.insert(m, at: to)
        persistDevices()
    }

    /// 超過 DVR 同時連線上限的提示（每台設備每次開啟 App 只提示一次）
    var liveLimitDevice: UUID?
    private var liveLimitNotified: Set<UUID> = []

    func noteLiveLimit(_ id: UUID) {
        guard !liveLimitNotified.contains(id) else { return }
        liveLimitNotified.insert(id)
        liveLimitDevice = id
    }

    /// 「編輯順序」視窗
    var editingDeviceOrder = false

    /// 自訂畫面命名對話框：新增（nil）或重新命名（id）
    enum CustomNameEdit: Equatable { case new, rename(UUID) }
    var customNameEdit: CustomNameEdit?
    var deletingCustom: UUID?

    /// 清單拖曳排序（List.onMove）
    func moveDevices(fromOffsets: IndexSet, toOffset: Int) {
        devices.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistDevices()
    }

    /// 上移（-1）／下移（+1）
    func moveDevice(_ id: UUID, by offset: Int) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard devices.indices.contains(j) else { return }
        devices.swapAt(i, j)
        persistDevices()
    }

    func canMoveDevice(_ id: UUID, by offset: Int) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return false }
        return devices.indices.contains(i + offset)
    }

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

    /// 切換到自訂畫面（nil＝上次使用的自訂畫面）
    func switchToCustom(_ id: UUID? = nil) {
        if mode == .playback { mode = .live }
        if let id, id != customID, let v = customViews.first(where: { $0.id == id }) {
            loadingUI = true
            customID = id
            layout = v.layout
            slots = v.slots
            loadingUI = false
            enlargedSlot = nil
            focusedSlot = 0
            audioRef = nil
            saveUI()
        }
        liveDeviceID = nil
    }

    func addCustomView(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let v = CustomView(name: n.isEmpty ? "自訂畫面 \(customViews.count + 1)" : n)
        customViews.append(v)
        switchToCustom(v.id)
    }

    func renameCustomView(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = customViews.firstIndex(where: { $0.id == id }) else { return }
        customViews[i].name = n
    }

    /// 移除自訂畫面（至少保留一個）
    func deleteCustomView(_ id: UUID) {
        guard customViews.count > 1, let i = customViews.firstIndex(where: { $0.id == id }) else { return }
        customViews.remove(at: i)
        if customID == id {
            let next = customViews[min(i, customViews.count - 1)]
            customID = nil
            if isCustomLive { switchToCustom(next.id) } else {
                loadingUI = true
                customID = next.id; layout = next.layout; slots = next.slots
                loadingUI = false
                saveUI()
            }
        }
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
        // 一般模式一律用子串流（此類 DVR 遠端看主串流約每秒 1 張）；進階功能才可切換
        guard advancedFeatures else { return false }
        if let r = gridSlots[slot], let v = cameraMainStream[r] { return v }
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
        var customViews: [CustomView]?
        var customID: UUID?
    }

    private var loadingUI = false

    private func saveUI() {
        guard !loadingUI else { return }
        let s = UIState(mode: mode, layout: layout, slots: slots, playbackRef: playbackRef, liveDeviceID: liveDeviceID,
                        customViews: customViews, customID: customID)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "uiState") }
    }

    private func loadUI() {
        loadingUI = true
        defer {
            // 舊版只有一個自訂畫面：搬成第一個自訂畫面
            if customViews.isEmpty { customViews = [CustomView(name: "自訂畫面", layout: layout, slots: slots)] }
            if currentCustom == nil, let f = customViews.first { customID = f.id; layout = f.layout; slots = f.slots }
            loadingUI = false
            saveUI()
        }
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
        if let cv = s.customViews, !cv.isEmpty {
            customViews = cv.map { v in
                var v = v
                if v.slots.count < Self.maxSlots { v.slots += Array(repeating: nil, count: Self.maxSlots - v.slots.count) }
                v.slots = v.slots.map { r in r.flatMap { ids.contains($0.deviceID) ? $0 : nil } }
                return v
            }
            customID = s.customID
            if let c = currentCustom { layout = c.layout; slots = c.slots }
        }
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
