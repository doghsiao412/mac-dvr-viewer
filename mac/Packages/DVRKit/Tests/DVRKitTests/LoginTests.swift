import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：reqLogin／nonce 雜湊登入（測試向量來自 DVR 網頁 login.js 的演算法，假密碼）
struct LoginTests {
    @Test func hashedPasswordMatchesWebVector() {
        #expect(NVMSClient.hashedPassword("123456", nonce: "{FFB02F57-8E0B-C242-BDAC-6320289A14E5}")
                == "D5A5FA47051FA9583A1C20E25C2919E620999F23")
    }

    @Test func tokenInsertedIntoRequests() {
        let empty = NVMSClient.withToken(NVMSClient.emptyRequest(), "{T}")
        #expect(empty.hasSuffix(#"<request version="1.0" systemType="NVMS-9000" clientType="WEB"><token>{T}</token></request>"#))
        #expect(XMLParser(data: Data(empty.utf8)).parse())
        let body = NVMSClient.withToken(NVMSClient.request("<content>x</content>"), "{T}")
        #expect(body.contains(#"clientType="WEB"><token>{T}</token><content>x</content></request>"#))
        // 已有 token（reqLogin 送的 null）不重複插入
        let req = NVMSClient.request("<token>null</token>")
        #expect(NVMSClient.withToken(req, "{T}") == req)
    }

    @Test func stripBraces() {
        #expect(NVMSClient.stripBraces("{ABC-1}") == "ABC-1")
        #expect(NVMSClient.stripBraces("ABC") == "ABC")
    }

    @Test func loginFailedMessage() {
        let e = NVMSError.loginFailed(code: 536870947, remaining: 3, locked: false)
        #expect(e.description.contains("帳號或密碼錯誤"))
        #expect(e.description.contains("剩餘嘗試次數 3"))
        #expect(NVMSError.loginFailed(code: 536870951, remaining: 0, locked: true).description.contains("鎖定"))
    }

    @Test func wrongCredentialsDetected() {
        #expect(NVMSError.loginFailed(code: 536870947, remaining: 4, locked: false).isWrongCredentials)
        #expect(NVMSError.loginFailed(code: 536870948, remaining: nil, locked: false).isWrongCredentials)
        // 已鎖定、其他錯誤、連線問題：不是「密碼錯」，不能因此要求使用者重輸密碼
        #expect(!NVMSError.loginFailed(code: 536870947, remaining: 0, locked: true).isWrongCredentials)
        #expect(!NVMSError.loginFailed(code: 536870951, remaining: nil, locked: false).isWrongCredentials)
        #expect(!NVMSError.transport("逾時").isWrongCredentials)
        #expect(!NVMSError.device(command: "doLogin", code: 536870947).isWrongCredentials)
    }
}
