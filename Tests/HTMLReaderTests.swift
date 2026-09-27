import XCTest
import WebKit
import SwiftSoup
@testable import Smail

@MainActor final class HTMLReaderTests: XCTestCase, WKNavigationDelegate {
    private var loaded: XCTestExpectation?
    private func mail(html: String) -> Mail {
        Mail(id: "abc", from: "sender@example.com", subject: "Newsletter", snippet: "Preview", date: Date(), body: "Plain fallback https://example.com/long-tracking-url", labelIDs: ["UNREAD"], htmlBody: html)
    }
    func testPreservesLayoutButRemovesActiveContentAndRestrictsNetwork() throws {
        let source = """
        <html><head><meta http-equiv="refresh" content="0;url=https://example.com/redirect"><base href="https://example.com"><script>window.injected=1</script><style>.hero{background:#123456}</style></head><body onload="alert(1)"><table class="hero"><tr><td><h1>Sources confirm</h1><a href="https://example.com/click?longtracking=123" ping="https://example.com/ping">Read more</a><img src="https://example.com/photo.jpg"></td></tr></table><iframe src="https://example.com/frame"></iframe><a href="javascript:alert(1)">Bad</a></body></html>
        """
        let result = try EmailDocument.make(mail: mail(html: source), allowRemoteImages: false)
        let parsed = try SwiftSoup.parse(result.html)
        XCTAssertTrue(result.hasRemoteImages)
        XCTAssertEqual(try parsed.select("table.hero h1").text(), "Sources confirm")
        XCTAssertEqual(try parsed.select("a[href]").text(), "Read more")
        XCTAssertTrue(try parsed.select("script,iframe,base,[onload],[ping]").isEmpty())
        let csp = try parsed.select("meta[http-equiv=Content-Security-Policy]").attr("content")
        XCTAssertTrue(csp.contains("img-src data:;"))
        XCTAssertTrue(csp.contains("connect-src 'none'"))
        XCTAssertFalse(result.html.contains("http-equiv=\"refresh\""))
        let allowed = try EmailDocument.make(mail: mail(html: source), allowRemoteImages: true)
        XCTAssertTrue(allowed.html.contains("img-src data: https:"))
        XCTAssertTrue(allowed.html.contains("script-src 'none'"))
    }
    func testCIDImageResolvesWithoutEnablingRemoteImages() throws {
        var source = mail(html: "<p>Hello</p><img src='cid:logo@example'><img src='javascript:alert(1)'>")
        source.inlineImages = ["logo@example": "data:image/png;base64,AA=="]
        let result = try EmailDocument.make(mail: source, allowRemoteImages: false)
        let parsed = try SwiftSoup.parse(result.html)
        XCTAssertEqual(try parsed.select("img[src]").count, 1)
        XCTAssertEqual(try parsed.select("img[src]").attr("src"), "data:image/png;base64,AA==")
        XCTAssertFalse(result.hasRemoteImages)
    }
    func testLegacyCacheDecodesAndMultipartKeepsHTMLAlternative() throws {
        let legacy = #"{"id":"abc","from":"sender","subject":"Test","snippet":"Text","date":0,"body":"Plain","labelIDs":["UNREAD"]}"#
        let old = try JSONDecoder().decode(Mail.self, from: Data(legacy.utf8))
        XCTAssertNil(old.htmlBody)
        let html = Data("<h1>Rich text</h1>".utf8).base64EncodedString()
        let json = """
        {"id":"abc","payload":{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"UGxhaW4="}},{"mimeType":"text/html","body":{"data":"\(html)"}}]}}
        """
        let parsed = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)).mail()
        XCTAssertEqual(parsed.body, "Plain")
        XCTAssertEqual(parsed.htmlBody, "<h1>Rich text</h1>")
    }
    func testWebKitActuallyRendersHTMLAndDoesNotExecuteMailScripts() async throws {
        let source = mail(html: "<style>h1{color:rgb(12,34,56)}</style><h1>Sources confirm</h1><a href='https://example.com/secret-tracking-url'>Shop now</a><script>window.mailInjected=true</script>")
        let document = try EmailDocument.make(mail: source, allowRemoteImages: false)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 600), configuration: EmailWebView.configuration())
        loaded = expectation(description: "Local HTML rendered")
        web.navigationDelegate = self
        web.loadHTMLString(document.html, baseURL: nil)
        await fulfillment(of: [loaded!], timeout: 15)
        let rendered = try await web.evaluateJavaScript("({text:document.body.innerText,color:getComputedStyle(document.querySelector('h1')).color,script:typeof window.mailInjected})") as! [String: String]
        XCTAssertTrue(rendered["text"]!.contains("Shop now"))
        XCTAssertFalse(rendered["text"]!.contains("secret-tracking-url"))
        XCTAssertEqual(rendered["color"], "rgb(12, 34, 56)")
        XCTAssertEqual(rendered["script"], "undefined")
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill(); loaded = nil }
}
