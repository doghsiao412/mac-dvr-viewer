import Foundation

/// 跨平台（macOS／iOS）的精簡 XML 樹。
///
/// macOS 的 `XMLDocument`／`XMLElement` 在 iOS 上不存在，所以改用 `XMLParser` 自己建樹。
/// 只實作 DVR 回應需要的部分：元素名稱、屬性、子元素、文字（含 CDATA）。
public struct DVRXMLElement: Sendable {
    public var name: String
    public var attributes: [String: String]
    public var children: [DVRXMLElement]
    /// 這個元素本身的文字（不含子元素）
    public var ownText: String

    public init(name: String, attributes: [String: String] = [:], children: [DVRXMLElement] = [], ownText: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.ownText = ownText
    }

    /// 解析 XML，回傳根元素
    public static func parse(_ data: Data) throws -> DVRXMLElement {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw NVMSError.badXML(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return root
    }

    /// 自己與所有子孫的文字串接（同 `XMLNode.stringValue`）
    public var stringValue: String {
        ownText + children.map(\.stringValue).joined()
    }

    public func attribute(_ name: String) -> String? { attributes[name] }

    public func elements(forName name: String) -> [DVRXMLElement] {
        children.filter { $0.name == name }
    }

    /// 以 "a/b/c" 路徑取所有符合的元素
    public func elements(forPath path: String) -> [DVRXMLElement] {
        var current = [self]
        for part in path.split(separator: "/") {
            current = current.flatMap { $0.elements(forName: String(part)) }
        }
        return current
    }

    /// 以 "a/b/c" 路徑取第一個元素的文字
    public func text(_ path: String) -> String? {
        elements(forPath: path).first?.stringValue
    }

    /// 把 <content> 底下的葉節點攤平成 [路徑: 值]
    public func flatContent() -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ e: DVRXMLElement, _ prefix: String) {
            if e.children.isEmpty {
                out[prefix] = e.stringValue
            } else {
                for k in e.children { walk(k, prefix.isEmpty ? k.name : prefix + "." + k.name) }
            }
        }
        if let c = elements(forName: "content").first { walk(c, "") }
        return out
    }

    /// 序列化回 XML 字串（開發探索用）
    public var xmlString: String {
        let attrs = attributes.keys.sorted().map { " \($0)=\"\(Self.escape(attributes[$0]!, quote: true))\"" }.joined()
        if children.isEmpty && ownText.isEmpty { return "<\(name)\(attrs)/>" }
        return "<\(name)\(attrs)>" + Self.escape(ownText, quote: false) + children.map(\.xmlString).joined() + "</\(name)>"
    }

    static func escape(_ s: String, quote: Bool) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote { r = r.replacingOccurrences(of: "\"", with: "&quot;") }
        return r
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [DVRXMLElement] = []
        var root: DVRXMLElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(DVRXMLElement(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard var e = stack.popLast() else { return }
            // 有子元素時，元素間的縮排空白不算文字
            if !e.children.isEmpty, e.ownText.allSatisfy(\.isWhitespace) { e.ownText = "" }
            if stack.isEmpty { root = e } else { stack[stack.count - 1].children.append(e) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].ownText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].ownText += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}
