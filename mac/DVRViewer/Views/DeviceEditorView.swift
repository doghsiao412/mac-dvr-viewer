import DVRKit
import SwiftUI

/// 新增／編輯 DVR。儲存前會實際登入測試；密碼只存在 Keychain。
struct DeviceEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: DeviceEditorTarget

    @State private var name = ""
    @State private var host = ""
    @State private var port = "80"
    @State private var username = ""
    @State private var password = ""
    @State private var servicePort = "6036"
    @State private var testing = false
    @State private var result: String?
    @State private var resultOK = false
    @State private var searching = false
    @State private var found: [DiscoveredDevice]?

    private var isNew: Bool { if case .new = target { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        Button {
                            Task { await searchLAN() }
                        } label: {
                            Label(searching ? "搜尋中…" : "搜尋區網中的 DVR", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .disabled(searching)
                        if searching { ProgressView().controlSize(.small) }
                    }
                    if let found {
                        if found.isEmpty {
                            Text("沒有找到設備。Mac 要和 DVR 在同一個區網；也可能是 DVR 關閉了搜尋或路由器擋掉。可以直接在下方手動輸入。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(found) { d in
                            Button { pick(d) } label: { FoundDeviceRow(device: d, selected: host == d.ip) }
                                .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("區網搜尋")
                } footer: {
                    Text("只在 Mac 和 DVR 在同一個區網時有用；從外網連線請手動輸入。點一下找到的設備即可帶入 IP 與 Port。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("名稱", text: $name, prompt: Text("例如：公司 DVR"))
                    TextField("IP 或主機名稱", text: $host, prompt: Text("192.168.1.100 或 mydvr.ddns.net"))
                    TextField("Port（網頁連接埠）", text: $port)
                    TextField("影像服務 Port（通常會自動帶入）", text: $servicePort)
                } header: {
                    Text("DVR 位址")
                } footer: {
                    Text("Port 填 DVR 網頁的連接埠即可。「影像服務 Port」保持 6036 時，連線成功後會自動帶入 DVR 自己設定的 Port（DVR「網路 → 連接埠」中的伺服器 Port）。只有路由器把它轉發成不同號碼時，才需要手動填外部 Port。")
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("帳號", text: $username)
                    SecureField(isNew ? "密碼" : "密碼（留空表示不變更）", text: $password)
                } header: {
                    Text("登入")
                } footer: {
                    Text("密碼儲存在 macOS 鑰匙圈。注意：此類 DVR 以未加密的 HTTP 傳送登入資訊，經網際網路連線時建議使用 VPN。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let result {
                Label(result, systemImage: resultOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(resultOK ? .green : .red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "測試並加入" : "測試並儲存") { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(testing || host.isEmpty || username.isEmpty || Int(port) == nil || Int(servicePort) == nil || (isNew && password.isEmpty))
            }
            .padding(20)
        }
        .frame(width: 460)
        .onAppear(perform: load)
        #if DEBUG
        .task { if UITestHarness.scene == "discover" { await searchLAN() } }
        #endif
    }

    private func searchLAN() async {
        searching = true
        defer { searching = false }
        found = await LANDiscovery.search(timeout: 3)
    }

    private func pick(_ d: DiscoveredDevice) {
        host = d.ip
        if let p = d.httpPort { port = String(p) }
        if let sp = d.servicePort { servicePort = String(sp) }
        if name.isEmpty { name = d.name ?? d.model ?? "" }
        result = nil
    }

    private func load() {
        if case .edit(let c) = target {
            name = c.name; host = c.host; port = String(c.port); username = c.username
            servicePort = String(c.servicePort ?? 6036)
        }
    }

    private func save() async {
        guard let p = Int(port) else { return }
        testing = true
        result = nil
        defer { testing = false }

        var config: DeviceConfig
        switch target {
        case .new:
            config = DeviceConfig(name: name, host: host, port: p, username: username)
        case .edit(let c):
            config = c
            config.host = host; config.port = p; config.username = username
        }
        config.host = config.host.trimmingCharacters(in: .whitespaces)
        config.servicePort = Int(servicePort).flatMap { $0 == 6036 ? nil : $0 }
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty || name.isEmpty { config.name = name.isEmpty ? host : name }
        else { config.name = name }

        // 測試登入（用輸入的密碼；編輯時若未輸入則用 Keychain 既有密碼）
        let pw = password
        let id = config.id
        let test = DVRConnection(host: config.host, port: p, username: config.username) {
            pw.isEmpty ? try KeychainStore.password(for: id) : pw
        }
        do {
            let chs = try await test.connect()
            let info = await test.info
            let detected = await test.detectedServicePort
            await test.disconnect()
            resultOK = true
            result = "連線成功：\(info?.model ?? "DVR")，\(chs.count) 個頻道"
            // 影像服務 Port 保持預設時，自動帶入 DVR 自己設定的 Port
            if config.servicePort == nil, let d = detected, d != 6036 {
                config.servicePort = d
                servicePort = String(d)
                result! += "；已自動帶入影像服務 Port \(d)"
            }
            if isNew {
                try store.add(config, password: pw)
            } else {
                try store.update(config, password: pw.isEmpty ? nil : pw)
            }
            try? await Task.sleep(for: .milliseconds(600))
            dismiss()
        } catch {
            resultOK = false
            result = "連線失敗：\(DeviceModel.describe(error))"
        }
    }
}

/// 搜尋結果的一列
private struct FoundDeviceRow: View {
    let device: DiscoveredDevice
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isTVT ? "server.rack" : "video")
                .foregroundStyle(device.isTVT ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        [device.name, device.model].compactMap { $0 }.first ?? (device.isTVT ? "TVT 設備" : "ONVIF 設備")
    }

    private var detail: String {
        var parts = [device.ip]
        if let p = device.httpPort { parts.append("Port \(p)") }
        if let k = device.kind { parts.append(k) }
        if !device.isTVT { parts.append("可能不是 TVT 設備") }
        return parts.joined(separator: "・")
    }
}
