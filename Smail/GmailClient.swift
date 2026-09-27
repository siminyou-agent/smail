import Foundation

@MainActor protocol MailService {
    func labels() async throws -> [GmailLabel]
    func prepareLabels() async throws -> [GmailLabel]
    func batch(excluding: Set<String>) async throws -> [Mail]
    func message(id: String) async throws -> Mail
    func setLabels(messageID: String, target: [String]) async throws
}

@MainActor final class GmailClient: MailService {
    private let token: () async throws -> String
    private let session: URLSession
    private let now: () -> Date
    init(session: URLSession = .shared, now: @escaping () -> Date = Date.init, token: @escaping () async throws -> String) {
        self.session = session; self.now = now; self.token = token
    }

    // Private transport; callers cannot select arbitrary Gmail write methods or paths.
    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.timeoutInterval = 25
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SmailError.message("Gmail 响应无效。") }
        switch response.statusCode {
        case 200..<300: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw SmailError.message("Google 授权已失效，请重新授权后重试。")
        case 403: throw SmailError.message("Gmail 拒绝请求，请检查标签权限及 API 配置。")
        case 404: throw SmailError.message("邮件或标签已不存在，请在 Gmail 检查后重试。")
        case 429, 500...599: throw SmailError.message("Gmail 暂时忙碌，分类已保存在手机，稍后点重试。")
        default: throw SmailError.message("Gmail 请求失败（\(response.statusCode)），请重试。")
        }
    }
    func labels() async throws -> [GmailLabel] {
        struct Catalog: Decodable { let labels: [GmailLabel]? }
        let catalog: Catalog = try await request("labels")
        return catalog.labels ?? []
    }
    func prepareLabels() async throws -> [GmailLabel] {
        var catalog = try await labels()
        for choice in Choice.allCases {
            if !catalog.contains(where: { $0.name == choice.labelName }) {
                struct NewLabel: Encodable { let name: String; let labelListVisibility = "labelShow"; let messageListVisibility = "show" }
                struct Created: Decodable { let id: String }
                do {
                    let _: Created = try await request("labels", body: JSONEncoder().encode(NewLabel(name: choice.labelName)))
                } catch {
                    // Creation may have succeeded despite a lost response or raced another device.
                    let latest = try await labels()
                    guard latest.contains(where: { $0.name == choice.labelName && $0.type == "user" }) else { throw error }
                }
                catalog = try await labels() // Sparse create responses need catalog readback.
            }
        }
        let policy = LabelPolicy(labels: catalog)
        for choice in Choice.allCases { _ = try policy.id(for: choice) }
        return catalog.filter { policy.allowed.contains($0.id) }
    }
    func batch(excluding: Set<String>) async throws -> [Mail] {
        struct Page: Decodable {
            struct ID: Decodable { let id: String }
            let messages: [ID]?
            let nextPageToken: String?
        }
        let classified = LabelPolicy(labels: try await labels()).allowed
        let cutoff = now().timeIntervalSince1970 * 1000
        var upper = Int64(floor(cutoff / 1000)) + 1
        var window: Int64 = 86_400
        var output: [Mail] = []
        var seen = excluding
        // Gmail list exposes no contractual sort parameter. Exhaust a recent time window,
        // sort its actual internalDate values, then move backwards only if more are needed.
        while output.count < 10, upper > 0 {
            try Task.checkCancellation()
            let lower = max(0, upper - window)
            var cursor: String?
            var cursors = Set<String>()
            var candidates: [(id: String, timestamp: Double)] = []
            repeat {
                // Overlap one second at the lower boundary; exact millisecond filtering
                // below prevents both gaps and duplicates from strict after/before semantics.
                let search = "in:inbox -label:Smail/Useful -label:Smail/NotUseful after:\(max(0, lower - 1)) before:\(upper)"
                var query = [URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "q", value: search)]
                if let cursor { query.append(.init(name: "pageToken", value: cursor)) }
                let page: Page = try await request("messages", query: query)
                let ids = Array(Set((page.messages ?? []).map(\.id))).filter { !seen.contains($0) }
                for message in try await messages(ids: ids, format: "metadata") {
                    guard let raw = message.internalDate, let timestamp = Double(raw), timestamp.isFinite else {
                        throw SmailError.message("邮件缺少有效收件时间，无法确认最新顺序，请重试。")
                    }
                    guard timestamp >= Double(lower) * 1000, timestamp < Double(upper) * 1000, timestamp <= cutoff else { continue }
                    guard seen.insert(message.id).inserted else { continue }
                    let currentLabels = Set(message.labelIds ?? [])
                    guard currentLabels.contains("INBOX"), currentLabels.isDisjoint(with: classified), currentLabels.isDisjoint(with: ["TRASH", "SPAM"]) else { continue }
                    candidates.append((message.id, timestamp))
                }
                cursor = page.nextPageToken
                if let cursor, !cursors.insert(cursor).inserted { throw SmailError.message("Gmail 分页重复，请重试。") }
            } while cursor != nil
            candidates.sort { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
            var offset = 0
            while output.count < 10, offset < candidates.count {
                let count = min(10 - output.count, candidates.count - offset)
                let ids = candidates[offset..<(offset + count)].map(\.id)
                for message in try await messages(ids: ids, format: "full") {
                    let currentLabels = Set(message.labelIds ?? [])
                    // Another device may classify or move mail while the batch is loading.
                    guard currentLabels.contains("INBOX"), currentLabels.isDisjoint(with: classified), currentLabels.isDisjoint(with: ["TRASH", "SPAM"]) else { continue }
                    output.append(message.mail())
                }
                offset += count
            }
            upper = lower
            window = min(window * 7, 31_536_000_000)
        }
        return output.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    }
    private func messages(ids: [String], format: String) async throws -> [GmailMessage] {
        var output: [GmailMessage] = []
        for start in stride(from: 0, to: ids.count, by: 5) {
            try Task.checkCancellation()
            let group = Array(ids[start..<min(start + 5, ids.count)])
            for id in group {
                guard id.range(of: "^[a-fA-F0-9]{1,64}$", options: .regularExpression) != nil else { throw SmailError.message("邮件 ID 无效。") }
            }
            let chunk = try await withThrowingTaskGroup(of: GmailMessage.self) { tasks in
                for id in group {
                    tasks.addTask {
                        var query = [URLQueryItem(name: "format", value: format)]
                        if format == "metadata" { query.append(.init(name: "fields", value: "id,internalDate,labelIds")) }
                        return try await self.request("messages/\(id)", query: query)
                    }
                }
                var results: [GmailMessage] = []
                for try await message in tasks { results.append(message) }
                return results
            }
            output.append(contentsOf: chunk)
        }
        return output
    }
    func setLabels(messageID: String, target: [String]) async throws {
        guard messageID.range(of: "^[a-fA-F0-9]{1,64}$", options: .regularExpression) != nil else { throw SmailError.message("邮件 ID 无效。") }
        let policy = LabelPolicy(labels: try await labels())
        let change = try policy.changes(target: target)
        let result: GmailMessage = try await request("messages/\(messageID)/modify", body: JSONEncoder().encode(change))
        guard Set(result.labelIds ?? []).intersection(policy.allowed) == Set(target) else {
            throw SmailError.message("Gmail 标签尚未确认，请重试同步。")
        }
    }
    func message(id: String) async throws -> Mail {
        guard id.range(of: "^[a-fA-F0-9]{1,64}$", options: .regularExpression) != nil else { throw SmailError.message("邮件 ID 无效。") }
        let message: GmailMessage = try await request("messages/\(id)", query: [.init(name: "format", value: "full")])
        var mail = message.mail()
        var images: [String: String] = [:]
        var totalBytes = 0
        if let payload = message.payload, mail.htmlBody != nil {
            for part in GmailMessage.inlineParts(payload).prefix(12) {
                guard let contentID = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<> \r\n")), !contentID.isEmpty,
                      mail.htmlBody?.range(of: "cid:" + contentID, options: .caseInsensitive) != nil else { continue }
                var encoded = part.body?.data
                if encoded == nil, let attachment = part.body?.attachmentId,
                   attachment.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
                    struct Attachment: Decodable { let data: String? }
                    // Embedded images only; general file attachment downloads are not exposed.
                    let result: Attachment? = try? await request("messages/\(id)/attachments/\(attachment)")
                    encoded = result?.data
                }
                guard let encoded, encoded.utf8.count < 3_000_000 else { continue }
                var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                guard let bytes = Data(base64Encoded: base64), totalBytes + bytes.count <= 5_000_000 else { continue }
                totalBytes += bytes.count
                images[contentID] = "data:\(part.mimeType!);base64,\(bytes.base64EncodedString())"
            }
        }
        mail.inlineImages = images
        return mail
    }
}
