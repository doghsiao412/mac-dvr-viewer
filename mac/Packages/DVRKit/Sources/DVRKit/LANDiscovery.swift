import Foundation

/// 區網中找到的設備
public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable { case tvt, onvif }

    public var ip: String
    /// 網頁連接埠（新增 DVR 的「Port」）
    public var httpPort: Int?
    /// TVT 私有協定（SERVICE）連接埠
    public var servicePort: Int?
    /// 型號（TVT 搜尋回報）或 ONVIF hardware
    public var model: String?
    /// ONVIF 名稱
    public var name: String?
    /// DVR／NVR／IPC 等
    public var kind: String?
    public var mac: String?
    public var sources: Set<Source> = []

    public var id: String { ip }

    /// TVT 搜尋到的（可直接用本 App 連線的 DVR／NVR）排前面
    public var isTVT: Bool { sources.contains(.tvt) }
}

/// 區網搜尋：不逐一掃描 IP，只送出「詢問」封包，讓設備自己回報。
/// 1. TVT 原廠搜尋（原廠 SDK `NET_SDK_DiscoverDevice` 的格式）：多播到 234.55.55.55:23456，設備回覆到 234.55.55.56:23456
/// 2. ONVIF WS-Discovery：多播 Probe 到 239.255.255.250:3702，設備以單播回覆
public enum LANDiscovery {
    public static func search(timeout: Double = 3) async -> [DiscoveredDevice] {
        async let tvt = Task.detached { tvtSearch(timeout: timeout) }.value
        async let onvif = Task.detached { onvifSearch(timeout: timeout) }.value
        return merge(tvt: await tvt, onvif: await onvif)
    }

    static func merge(tvt: [DiscoveredDevice], onvif: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var byIP: [String: DiscoveredDevice] = [:]
        for d in tvt { byIP[d.ip] = d }
        for o in onvif {
            if var d = byIP[o.ip] {
                d.sources.insert(.onvif)
                d.name = d.name ?? o.name
                d.model = d.model ?? o.model
                d.httpPort = d.httpPort ?? o.httpPort
                byIP[o.ip] = d
            } else {
                byIP[o.ip] = o
            }
        }
        return byIP.values.sorted {
            if $0.isTVT != $1.isTVT { return $0.isTVT }
            return ipKey($0.ip).lexicographicallyPrecedes(ipKey($1.ip))
        }
    }

    private static func ipKey(_ ip: String) -> [Int] { ip.split(separator: ".").map { Int($0) ?? 0 } }

    // MARK: - TVT 原廠搜尋

    static let tvtMagic: UInt32 = 0x4445_484D   // "MHED"
    static let tvtPacketSize = 0x8C

    /// 搜尋請求：MHED、版本 0x00010008、類型 1（請求），其餘補 0，共 0x8C bytes
    static func tvtRequest() -> Data {
        var d = Data(count: tvtPacketSize)
        d.putU32(tvtMagic, at: 0)
        d.putU32(0x0001_0008, at: 4)
        d.putU32(1, at: 8)
        return d
    }

    /// 解析設備回覆（類型 2）。欄位位置依原廠 SDK 轉成 NET_SDK_DEVICE_DISCOVERY_INFO 的方式。
    static func parseTVTReply(_ d: Data, from sourceIP: String?) -> DiscoveredDevice? {
        guard d.count >= tvtPacketSize, d.u32(at: 0) == tvtMagic, d.u32(at: 8) == 2 else { return nil }
        let type = d.u32(at: 0x40)
        guard type <= 6 else { return nil }
        let version = d.u32(at: 4)
        let ipBytes = d[d.startIndex + 0x28 ..< d.startIndex + 0x2C]
        var ip = ipBytes.map(String.init).joined(separator: ".")
        if ip == "0.0.0.0", let sourceIP { ip = sourceIP }
        let mac = d[d.startIndex + 0x20 ..< d.startIndex + 0x26].map { String(format: "%02X", $0) }.joined(separator: ":")
        var dev = DiscoveredDevice(ip: ip)
        dev.servicePort = Int(d.u16(at: 0x26)).nonZero
        dev.httpPort = Int(d.u16(at: 0x3C)).nonZero
        dev.mac = mac
        dev.kind = ["DVR", "DVS", "IPC", "NVR", "DVR", "解碼器", "DVR"][Int(type)]
        if version > 0x0001_0006, d.count >= 0xD4 {
            let model = d.cString(at: 0xC4, max: 16) + d.cString(at: 0xB4, max: 16)
            if !model.isEmpty { dev.model = model }
        }
        dev.sources = [.tvt]
        return dev
    }

    static func tvtSearch(timeout: Double) -> [DiscoveredDevice] {
        let replies = UDPMulticast.exchange(payload: tvtRequest(), to: "234.55.55.55", port: 23456,
                                            bindPort: 23456, joinGroup: "234.55.55.56", timeout: timeout)
        var out: [String: DiscoveredDevice] = [:]
        for (data, src) in replies {
            if let d = parseTVTReply(data, from: src) { out[d.ip] = d }
        }
        return Array(out.values)
    }

    // MARK: - ONVIF WS-Discovery

    static func onvifProbe() -> Data {
        let id = UUID().uuidString.lowercased()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <e:Header><w:MessageID>uuid:\(id)</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header>\
        <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
        return Data(xml.utf8)
    }

    /// 解析 ProbeMatch：從 XAddrs 取 IP／Port，從 Scopes 取名稱與型號
    static func parseONVIFReply(_ d: Data, from sourceIP: String?) -> DiscoveredDevice? {
        guard let s = String(data: d, encoding: .utf8), s.contains("ProbeMatch") else { return nil }
        // NAS、Windows 電腦（網路芳鄰 WSD）也會回 Probe：只保留 ONVIF 影像設備
        guard s.contains("NetworkVideoTransmitter") || s.contains("onvif://") else { return nil }
        func element(_ name: String) -> String? {
            guard let r = s.range(of: #"<[A-Za-z0-9]*:?\#(name)[^>]*>([^<]*)</"#, options: .regularExpression) else { return nil }
            let m = String(s[r])
            guard let gt = m.firstIndex(of: ">") else { return nil }
            return String(m[m.index(after: gt)...].dropLast(2))
        }
        var ip = sourceIP
        var port: Int?
        for addr in (element("XAddrs") ?? "").split(separator: " ") {
            guard let u = URL(string: String(addr)), let h = u.host, h.split(separator: ".").count == 4,
                  h.allSatisfy({ $0.isNumber || $0 == "." }) else { continue }
            ip = h
            port = u.port ?? (u.scheme == "https" ? 443 : 80)
            break
        }
        guard let ip else { return nil }
        var dev = DiscoveredDevice(ip: ip)
        dev.httpPort = port
        for scope in (element("Scopes") ?? "").split(whereSeparator: \.isWhitespace) {
            let v = String(scope)
            func tail(_ key: String) -> String? {
                guard let r = v.range(of: "onvif://www.onvif.org/\(key)/") else { return nil }
                return String(v[r.upperBound...]).removingPercentEncoding
            }
            if let n = tail("name") { dev.name = n }
            if let h = tail("hardware") { dev.model = h }
            if let t = tail("type")?.uppercased(), ["NVR", "DVR", "IPC"].contains(t) { dev.kind = t }
        }
        dev.sources = [.onvif]
        return dev
    }

    static func onvifSearch(timeout: Double) -> [DiscoveredDevice] {
        let replies = UDPMulticast.exchange(payload: onvifProbe(), to: "239.255.255.250", port: 3702,
                                            bindPort: 0, joinGroup: nil, timeout: timeout)
        var out: [String: DiscoveredDevice] = [:]
        for (data, src) in replies {
            if let d = parseONVIFReply(data, from: src) { out[d.ip] = d }
        }
        return Array(out.values)
    }
}

/// 給命令列工具顯示用
public enum UDPMulticastInfo {
    public static var interfaceCount: Int { UDPMulticast.interfaces().count }
}

// MARK: - UDP 多播（BSD socket）

enum UDPMulticast {
    /// 本機可用的 IPv4 介面（已啟用、可多播、非 loopback）
    static func interfaces() -> [in_addr] {
        var out: [in_addr] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if !out.contains(where: { $0.s_addr == a.s_addr }) { out.append(a) }
        }
        return out
    }

    /// 從每個介面送出 payload，並在 timeout 內收集回覆（資料、來源 IP）
    static func exchange(payload: Data, to group: String, port: UInt16, bindPort: UInt16,
                         joinGroup: String?, timeout: Double) -> [(Data, String)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = bindPort.bigEndian
        local.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return [] }
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        let ifs = interfaces()
        if let joinGroup {
            for a in ifs {
                var m = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(joinGroup)), imr_interface: a)
                setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, socklen_t(MemoryLayout<ip_mreq>.size))
            }
        }
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = port.bigEndian
        dst.sin_addr.s_addr = inet_addr(group)
        func sendAll() {
            for var a in ifs {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size))
                payload.withUnsafeBytes { buf in
                    withUnsafePointer(to: &dst) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        sendAll()
        var resent = false

        var replies: [(Data, String)] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            // UDP 可能遺失：過了三分之一時間再送一次
            if !resent, left < timeout * 2 / 3 { sendAll(); resent = true }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(min(left, timeout / 3) * 1000))
            if r <= 0 { continue }
            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(src.sin_addr))
            replies.append((Data(buf[0..<n]), ip))
        }
        return replies
    }
}

// MARK: - 小工具

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension Data {
    func u32(at o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func u16(at o: Int) -> UInt16 {
        let i = startIndex + o
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
    func cString(at o: Int, max: Int) -> String {
        let s = startIndex + o
        let e = Swift.min(s + max, endIndex)
        guard s < e else { return "" }
        let bytes = self[s..<e].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
