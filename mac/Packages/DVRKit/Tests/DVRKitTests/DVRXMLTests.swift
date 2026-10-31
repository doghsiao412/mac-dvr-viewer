import Foundation
import Testing
@testable import DVRKit

/// Mock 測試：跨平台 XML 解析（取代 macOS 專屬的 XMLDocument），樣本依 NVMS 回應格式合成
struct DVRXMLTests {
    let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <response>
            <status>success</status>
            <content total="2">
                <item id="{CH-1}"><name><![CDATA[前門 & 車道]]></name><chlIndex>0</chlIndex></item>
                <item id="{CH-2}"><name>後院</name><chlIndex>1</chlIndex></item>
            </content>
        </response>
        """

    @Test func parsesPathsAttributesAndCDATA() throws {
        let root = try DVRXMLElement.parse(Data(sample.utf8))
        #expect(root.name == "response")
        #expect(root.text("status") == "success")
        #expect(root.elements(forName: "content").first?.attribute("total") == "2")
        let items = root.elements(forPath: "content/item")
        #expect(items.map { $0.attribute("id") } == ["{CH-1}", "{CH-2}"])
        #expect(items[0].text("name") == "前門 & 車道")
        #expect(items[1].text("chlIndex") == "1")
        #expect(root.text("content/missing") == nil)
    }

    @Test func flatContentSkipsIndentation() throws {
        let xml = "<response><content>\n  <a>1</a>\n  <b><c> x </c></b>\n</content></response>"
        let flat = try DVRXMLElement.parse(Data(xml.utf8)).flatContent()
        #expect(flat == ["a": "1", "b.c": " x "])
    }

    @Test func entitiesAndRoundTrip() throws {
        let root = try DVRXMLElement.parse(Data(#"<r k="a&quot;b"><v>1 &lt; 2</v><e/></r>"#.utf8))
        #expect(root.attribute("k") == "a\"b")
        #expect(root.text("v") == "1 < 2")
        let again = try DVRXMLElement.parse(Data(root.xmlString.utf8))
        #expect(again.text("v") == "1 < 2")
        #expect(again.elements(forName: "e").count == 1)
    }

    @Test func malformedThrows() {
        #expect(throws: NVMSError.self) { try DVRXMLElement.parse(Data("<a><b></a>".utf8)) }
    }
}
