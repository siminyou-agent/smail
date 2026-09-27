import SwiftUI
import WebKit
import SafariServices
import SwiftSoup

struct EmailDocument {
    let html: String
    let hasRemoteImages: Bool

    static func make(mail: Mail, allowRemoteImages: Bool) throws -> EmailDocument {
        let document = try SwiftSoup.parse(mail.htmlBody ?? "")
        // Parse untrusted email markup rather than stripping tags with regular expressions.
        try document.select("script, iframe, frame, frameset, object, embed, form, input, textarea, select, base, meta, link, applet, audio, video, source").remove()
        var remote = false
        for element in try document.getAllElements() {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let name = attribute.getKey().lowercased()
                if name.hasPrefix("on") || ["srcdoc", "nonce", "ping", "download", "autofocus", "contenteditable", "formaction"].contains(name) {
                    try element.removeAttr(attribute.getKey())
                }
            }
            if element.hasAttr("href") {
                let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                if !href.hasPrefix("#") && !isWebURL(href) { try element.removeAttr("href") }
                try element.attr("rel", "noreferrer noopener")
            }
            if element.hasAttr("src") {
                let src = try element.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
                if src.lowercased().hasPrefix("cid:") {
                    let cid = String(src.dropFirst(4)).removingPercentEncoding ?? String(src.dropFirst(4))
                    if let data = mail.inlineImages?.first(where: { $0.key.caseInsensitiveCompare(cid) == .orderedSame })?.value {
                        try element.attr("src", data)
                    } else { try element.removeAttr("src") }
                } else if src.hasPrefix("//") {
                    remote = true; try element.attr("src", "https:" + src)
                } else if isWebURL(src) { remote = true }
                else if !src.lowercased().hasPrefix("data:image/") { try element.removeAttr("src") }
            }
            if element.hasAttr("srcset") {
                // src remains the compatible fallback; don't allow srcset to bypass image handling.
                let value = try element.attr("srcset")
                if value.contains("http") || value.contains("//") { remote = true }
                try element.removeAttr("srcset")
            }
            if element.hasAttr("background") {
                let value = try element.attr("background")
                if isWebURL(value) || value.hasPrefix("//") { remote = true }
            }
            if element.hasAttr("style"), try element.attr("style").localizedCaseInsensitiveContains("url(") { remote = true }
        }
        if try document.select("style").html().localizedCaseInsensitiveContains("url(") { remote = true }

        let images = allowRemoteImages ? "data: https:" : "data:"
        // First-in-head CSP stays authoritative even if hostile email tries to add another policy.
        try document.head()?.prepend("""
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src \(images); font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; upgrade-insecure-requests">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        """)
        try document.head()?.append("""
        <style>
        :root { color-scheme: light; }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: 16px; font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 16px; line-height: 1.5; overflow-wrap: anywhere; }
        img { max-width: 100% !important; height: auto; }
        table { max-width: 100% !important; }
        a { overflow-wrap: anywhere; }
        </style>
        """)
        return EmailDocument(html: try document.outerHtml(), hasRemoteImages: remote)
    }

    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}

struct ReaderLink: Identifiable { let id = UUID(); let url: URL }

struct MailReader: View {
    let mail: Mail
    let load: () async throws -> Mail
    @Environment(\.dismiss) private var dismiss
    @State private var fresh: Mail?
    @State private var allowImages = false
    @State private var loading = true
    @State private var error: String?
    @State private var link: ReaderLink?
    @State private var document: EmailDocument?
    private var current: Mail { fresh ?? mail }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    MailSubject(subject: current.subject).font(.title3.bold()).lineLimit(4)
                    Text(current.from).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                Divider()
                if loading { ProgressView("读取原始邮件…").font(.caption).padding(8) }
                if let error {
                    HStack {
                        ErrorMessage(error).font(.caption).foregroundStyle(.secondary)
                        Button("重试") { Task { await refresh() } }.font(.caption.bold())
                    }.padding(10)
                }
                if document?.hasRemoteImages == true {
                    HStack(spacing: 10) {
                        Image(systemName: allowImages ? "photo" : "photo.badge.exclamationmark")
                        Text(LocalizedStringKey(allowImages ? "已允许这封邮件的外部图片" : "外部图片可能让发件人知道你已打开邮件")).font(.caption)
                        Spacer(minLength: 0)
                        Button(LocalizedStringKey(allowImages ? "隐藏图片" : "加载图片")) {
                            allowImages.toggle(); render()
                        }.font(.caption.bold()).accessibilityIdentifier("reader-images")
                    }.padding(12).background(Palette.paper)
                }
                if let document {
                    EmailWebView(html: document.html) { url in link = ReaderLink(url: url) }
                        .accessibilityIdentifier("html-reader")
                } else {
                    ScrollView {
                        Text(current.body).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
            }
            .navigationTitle("邮件正文").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { render(); await refresh() }
            .sheet(item: $link) { SafariReader(url: $0.url).ignoresSafeArea() }
        }
    }
    private func render() {
        guard current.htmlBody != nil else { document = nil; return }
        do { document = try EmailDocument.make(mail: current, allowRemoteImages: allowImages) }
        catch { document = nil; self.error = "HTML 排版无法显示，已切换为纯文本。" }
    }
    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await load()
            try Task.checkCancellation()
            fresh = value; render()
        } catch is CancellationError { }
        catch { self.error = "原文读取失败，当前显示已缓存内容。" }
    }
}

struct EmailWebView: UIViewRepresentable {
    let html: String
    let openLink: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        return config
    }
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration())
        web.navigationDelegate = context.coordinator
        web.isOpaque = false; web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.allowsLinkPreview = false
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        web.loadHTMLString(html, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        let openLink: (URL) -> Void
        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            // Only our locally-loaded document may navigate inside this view.
            if url.scheme == "about", url.absoluteString.hasPrefix("about:blank") { decisionHandler(.allow); return }
            if navigationAction.navigationType == .linkActivated, EmailDocument.isWebURL(url.absoluteString) { openLink(url) }
            decisionHandler(.cancel)
        }
    }
}

private struct SafariReader: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
