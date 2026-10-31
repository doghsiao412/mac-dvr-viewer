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

    private var isNew: Bool { if case .new = target { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("名稱", text: $name, prompt: Text("例如：公司 DVR"))
                    TextField("IP 或主機名稱", text: $host, prompt: Text("192.168.1.100 或 mydvr.ddns.net"))
                    TextField("Port（網頁連接埠）", text: $port)
                    TextField("影像服務 Port", text: $servicePort)
                } header: {
                    Text("DVR 位址")
                } footer: {
                    Text("Port 填 DVR 網頁的連接埠。「影像服務 Port」是 TVT 私有協定的連接埠（DVR 預設 6036；若路由器轉發成其他 Port，請填外部 Port）：較舊韌體的影像全部走這裡；新韌體同時超過 6 路即時影像時，多出的畫面也會改走這裡。")
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
            await test.disconnect()
            resultOK = true
            result = "連線成功：\(info?.model ?? "DVR")，\(chs.count) 個頻道"
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
