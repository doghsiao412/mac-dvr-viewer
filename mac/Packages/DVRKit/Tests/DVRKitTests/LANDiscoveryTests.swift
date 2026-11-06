import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：區網搜尋封包（依原廠 SDK 的欄位位置合成，未經實體設備驗證）
struct LANDiscoveryTests {
    @Test func tvtRequestFormat() {
        let d = LANDiscovery.tvtRequest()
        #expect(d.count == 0x8C)
        #expect(Array(d.prefix(4)) == Array("MHED".utf8))
        #expect(d.u32(at: 4) == 0x0001_0008)
        #expect(d.u32(at: 8) == 1)
        #expect(d.dropFirst(12).allSatisfy { $0 == 0 })
    }

    static func tvtReply(ip: [UInt8], service: UInt16, http: UInt16, type: UInt32 = 0, model: String = "TD-2716NE-HC") -> Data {
        var d = Data(count: 0xE0)
        d.putU32(LANDiscovery.tvtMagic, at: 0)
        d.putU32(0x0001_0008, at: 4)
        d.putU32(2, at: 8)
        d.replaceSubrange(0x20..<0x26, with: [0x00, 0x18, 0xAE, 0x01, 0x02, 0x03])
        d.putU16(service, at: 0x26)
        d.replaceSubrange(0x28..<0x2C, with: ip)
        d.putU16(http, at: 0x3C)
        d.putU32(type, at: 0x40)
        d.replaceSubrange(0xB4..<(0xB4 + model.utf8.count), with: Array(model.utf8))
        return d
    }

    @Test func tvtReplyParsed() throws {
        let dev = try #require(LANDiscovery.parseTVTReply(Self.tvtReply(ip: [192, 168, 1, 50], service: 6036, http: 80, type: 3), from: "192.168.1.50"))
        #expect(dev.ip == "192.168.1.50")
        #expect(dev.servicePort == 6036)
        #expect(dev.httpPort == 80)
        #expect(dev.kind == "NVR")
        #expect(dev.model == "TD-2716NE-HC")
        #expect(dev.mac == "00:18:AE:01:02:03")
        #expect(dev.isTVT)
    }

    @Test func tvtIgnoresOwnRequestAndGarbage() {
        #expect(LANDiscovery.parseTVTReply(LANDiscovery.tvtRequest(), from: nil) == nil)   // 自己送出的請求（類型 1）
        #expect(LANDiscovery.parseTVTReply(Data(count: 0x8C), from: nil) == nil)
        #expect(LANDiscovery.parseTVTReply(Data("MHED".utf8), from: nil) == nil)
    }

    static let onvifReply = """
    <?xml version="1.0" encoding="UTF-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" \
    xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch>\
    <d:Types>dn:NetworkVideoTransmitter tds:Device</d:Types>\
    <d:Scopes>onvif://www.onvif.org/type/NVR onvif://www.onvif.org/name/Front%20Door onvif://www.onvif.org/hardware/TD-2704AS-PL</d:Scopes>\
    <d:XAddrs>http://192.168.1.60:8080/onvif/device_service http://[fe80::1]/onvif/device_service</d:XAddrs>\
    </d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>
    """

    @Test func onvifReplyParsed() throws {
        let dev = try #require(LANDiscovery.parseONVIFReply(Data(Self.onvifReply.utf8), from: "192.168.1.60"))
        #expect(dev.ip == "192.168.1.60")
        #expect(dev.httpPort == 8080)
        #expect(dev.name == "Front Door")
        #expect(dev.model == "TD-2704AS-PL")
        #expect(dev.kind == "NVR")
        #expect(!dev.isTVT)
    }

    @Test func onvifIgnoresNonCameraWSD() {
        // NAS／Windows 的 WSD 回覆：有 ProbeMatch、XAddrs，但不是 ONVIF 影像設備
        let nas = """
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery">\
        <soap:Body><wsd:ProbeMatches><wsd:ProbeMatch><wsd:Types>wsdp:Device pub:Computer</wsd:Types>\
        <wsd:XAddrs>http://192.168.1.9:5357/abc</wsd:XAddrs></wsd:ProbeMatch></wsd:ProbeMatches></soap:Body></soap:Envelope>
        """
        #expect(LANDiscovery.parseONVIFReply(Data(nas.utf8), from: "192.168.1.9") == nil)
        #expect(LANDiscovery.parseONVIFReply(Data("<wsd:ProbeMatches/>".utf8), from: "192.168.1.9") == nil)
    }

    @Test func onvifProbeIsValidXML() {
        let p = LANDiscovery.onvifProbe()
        #expect(XMLParser(data: p).parse())
        #expect(LANDiscovery.parseONVIFReply(p, from: nil) == nil)   // 自己的 Probe 不是回覆
    }

    @Test func mergePrefersTVTAndSorts() throws {
        let t = try #require(LANDiscovery.parseTVTReply(Self.tvtReply(ip: [192, 168, 1, 60], service: 6036, http: 80), from: nil))
        let o = try #require(LANDiscovery.parseONVIFReply(Data(Self.onvifReply.utf8), from: nil))
        var cam = o; cam.ip = "192.168.1.5"; cam.name = "Camera"
        let r = LANDiscovery.merge(tvt: [t], onvif: [o, cam])
        #expect(r.map(\.ip) == ["192.168.1.60", "192.168.1.5"])
        #expect(r[0].sources == [.tvt, .onvif])
        #expect(r[0].httpPort == 80)          // TVT 回報的網頁 Port 優先
        #expect(r[0].name == "Front Door")    // 名稱由 ONVIF 補上
    }
}
