import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：從 queryUPnPCfg 取得 DVR 自己設定的影像服務 Port（樣本依實體回應格式合成）
struct ServicePortTests {
    func upnp(switchOn: Bool, status: String, local: Int, external: Int) throws -> DVRXMLElement {
        let xml = """
            <response><status>success</status><content><switch>\(switchOn)</switch><ports type="list">
            <item><portType>HTTP</portType><externalPort>80</externalPort><status>\(status)</status><localPort>80</localPort></item>
            <item><portType>SERVICE</portType><externalPort>\(external)</externalPort><status>\(status)</status><localPort>\(local)</localPort></item>
            </ports></content></response>
            """
        return try DVRXMLElement.parse(Data(xml.utf8))
    }

    @Test func upnpOffUsesLocalPort() throws {
        #expect(NVMSClient.servicePort(fromUPnP: try upnp(switchOn: false, status: "ineffective", local: 6033, external: 6033)) == 6033)
    }

    @Test func upnpEffectiveUsesExternalPort() throws {
        #expect(NVMSClient.servicePort(fromUPnP: try upnp(switchOn: true, status: "effective", local: 6036, external: 6040)) == 6040)
    }

    @Test func upnpOnButNotMappedUsesLocalPort() throws {
        #expect(NVMSClient.servicePort(fromUPnP: try upnp(switchOn: true, status: "ineffective", local: 6036, external: 6040)) == 6036)
    }

    @Test func missingServiceItem() throws {
        let root = try DVRXMLElement.parse(Data("<response><status>success</status><content><switch>false</switch></content></response>".utf8))
        #expect(NVMSClient.servicePort(fromUPnP: root) == nil)
    }
}
