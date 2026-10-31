import DVRKit
import SwiftUI

/// 新增／編輯 DVR。儲存前會實際登入測試；密碼只存在 iPhone 鑰匙圈。
struct DeviceEditorView: View {
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

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

    private var canSave: Bool {
        !testing && !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty
            && Int(port) != nil && Int(servicePort) != nil && (!isNew || !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱（例如：公司 DVR）", text: $name)
                    TextField("IP 或主機名稱", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("網頁 Port") {
                        TextField("80", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("影像服務 Port") {
                        TextField("6036", text: $servicePort).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("DVR 位址")
                } footer: {
                    Text("Port 填 DVR 網頁的連接埠。「影像服務 Port」用於同時看超過 6 路即時影像；同一個外網 IP 後面有多台 DVR 時，每台的影像服務 Port 不同（例如 6036、6033），請依路由器的轉發設定填寫。填錯時畫面會顯示「影像服務 Port 設定錯誤」。")
                }
                Section {
                    TextField("帳號", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField(isNew ? "密碼" : "密碼（留空表示不變更）", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("登入")
                } footer: {
                    Text("密碼儲存在 iPhone 鑰匙圈。注意：此類 DVR 以未加密的 HTTP 傳送登入資訊，經網際網路連線時建議使用 VPN。")
                }
                if let result {
                    Section {
                        Label(result, systemImage: resultOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(resultOK ? .green : .red)
                    }
                }
            }
            .navigationTitle(isNew ? "加入 DVR" : "編輯 DVR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if testing {
                        ProgressView()
                    } else {
                        Button(isNew ? "測試並加入" : "測試並儲存") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(testing)
            .onAppear(perform: load)
        }
    }

    private func load() {
        if case .edit(let c) = target {
            name = c.name; host = c.host; port = String(c.port); username = c.username
            servicePort = String(c.servicePort ?? 6036)
        }
    }

    private func save() async {
        guard let p = Int(port), let sp = Int(servicePort) else { return }
        testing = true
        result = nil
        defer { testing = false }

        var config: DeviceConfig
        switch target {
        case .new:
            config = DeviceConfig(name: name, host: host, port: p, username: username)
        case .edit(let c):
            config = c
            config.port = p
            config.username = username
        }
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.servicePort = sp == 6036 ? nil : sp
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        config.name = trimmed.isEmpty ? config.host : trimmed

        // 測試登入（用輸入的密碼；編輯時若未輸入則用鑰匙圈既有密碼）
        let pw = password
        let id = config.id
        let test = DVRConnection(host: config.host, port: p, username: config.username, servicePort: sp) {
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
