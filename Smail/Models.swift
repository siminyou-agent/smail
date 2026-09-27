import Foundation

enum SmailError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Choice: String, Codable, CaseIterable {
    case useful, notUseful
    var labelName: String { self == .useful ? "Smail/Useful" : "Smail/NotUseful" }
    var title: String { self == .useful ? "有用" : "没用" }
}

struct Mail: Codable, Identifiable, Equatable {
    var id: String
    var from: String
    var subject: String
    var snippet: String
    var date: Date
    var body: String
    var labelIDs: [String]
    // Optional fields keep older, already-installed batch files decodable.
    var htmlBody: String? = nil
    var inlineImages: [String: String]? = nil
}

struct GmailLabel: Codable, Equatable {
    let id: String
    let name: String
    let type: String?
}

struct LabelPolicy {
    let labels: [GmailLabel]
    func id(for choice: Choice) throws -> String {
        let matches = labels.filter { $0.name == choice.labelName && $0.type == "user" && $0.id.hasPrefix("Label_") }
        guard matches.count == 1 else { throw SmailError.message("分类标签已更改，请重新加载标签后重试。") }
        return matches[0].id
    }
    var allowed: Set<String> { Set(labels.filter { $0.type == "user" && $0.id.hasPrefix("Label_") && Choice.allCases.map(\.labelName).contains($0.name) }.map(\.id)) }
    func changes(target: [String]) throws -> LabelChange {
        // Require both labels to exist and never accept system or unrelated custom labels.
        let both = Set(try Choice.allCases.map { try id(for: $0) })
        guard both.count == 2, Set(target).isSubset(of: both), Set(target).count == target.count else {
            throw SmailError.message("只允许修改 Smail 的两个自定义标签。")
        }
        return LabelChange(addLabelIds: target.sorted(), removeLabelIds: both.subtracting(target).sorted())
    }
}

struct LabelChange: Codable, Equatable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

struct Decision: Codable, Identifiable {
    var id: String { mail.id }
    let mail: Mail
    let choice: Choice
    let before: [String]
}

struct Mutation: Codable, Identifiable {
    var id = UUID()
    let messageID: String
    let target: [String]
}

struct Batch: Codable {
    let account: String
    var mails: [Mail] = []
    var decisions: [Decision] = []
    var pending: [Mutation] = []
    var labels: [GmailLabel] = []
    var started = false
    var total: Int { mails.count + decisions.count }
}

struct GmailMessage: Decodable {
    let id: String
    let snippet: String?
    let internalDate: String?
    let labelIds: [String]?
    let payload: Part?
    struct Part: Decodable {
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }
    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String?; let attachmentId: String? }

    func mail() -> Mail {
        func header(_ name: String) -> String { payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value ?? "" }
        let plain = payload.map { Self.text($0, html: false) } ?? ""
        let html = payload.map { Self.text($0, html: true) } ?? ""
        let body = plain.isEmpty ? Self.cleanHTML(html) : plain
        return Mail(id: id, from: header("From"), subject: header("Subject").isEmpty ? "（无主题）" : header("Subject"),
                    snippet: Self.entities(snippet ?? ""), date: Date(timeIntervalSince1970: (Double(internalDate ?? "") ?? 0) / 1000),
                    body: body.isEmpty ? Self.entities(snippet ?? "") : body, labelIDs: labelIds ?? [], htmlBody: html.isEmpty ? nil : html)
    }
    static func inlineParts(_ part: Part) -> [Part] {
        let types: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]
        var result: [Part] = []
        if types.contains(part.mimeType ?? ""), part.headers?.contains(where: { $0.name.lowercased() == "content-id" }) == true { result.append(part) }
        return result + (part.parts ?? []).flatMap(inlineParts)
    }
    static func decode(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    static func text(_ part: Part, html: Bool) -> String {
        guard (part.filename ?? "").isEmpty else { return "" }
        if part.mimeType == (html ? "text/html" : "text/plain"), let data = part.body?.data { return decode(data) }
        return (part.parts ?? []).map { text($0, html: html) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    static func cleanHTML(_ html: String) -> String {
        let noScript = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        return entities(noScript.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/tr|/h[1-6])>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func entities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] { result = result.replacingOccurrences(of: entity, with: value) }
        let regex = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range(at: 1), in: result), let full = Range(match.range, in: result) else { continue }
            let raw = String(result[range]); let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(full, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
