import SwiftUI

@MainActor @Observable final class BatchStore {
    var batch: Batch
    var loading = false
    var syncing = false
    var error: String?
    private let service: MailService
    private let disk: BatchDisk
    private var active = true
    var current: Mail? { batch.mails.first }
    var canUndo: Bool { !batch.decisions.isEmpty && batch.pending.isEmpty && !syncing && !loading }
    init(account: String, service: MailService, disk: BatchDisk = BatchDisk()) throws {
        self.service = service; self.disk = disk; self.batch = try disk.load(account)
    }
    func stop() { active = false }
    func detail(for mail: Mail) async throws -> Mail {
        guard active else { throw CancellationError() }
        let detail = try await service.message(id: mail.id)
        guard active else { throw CancellationError() }
        return detail
    }
    private func commit(_ next: Batch) throws { try disk.save(next); batch = next }

    func load() async {
        guard active, !loading, !syncing, batch.pending.isEmpty else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            let labels = try await service.prepareLabels()
            let mails = try await service.batch(excluding: Set(batch.decisions.map(\.id)))
            guard active else { return }
            var next = Batch(account: batch.account); next.labels = labels; next.mails = mails; next.started = true
            try commit(next)
        } catch { if active { self.error = error.localizedDescription } }
    }
    func choose(_ choice: Choice) {
        guard active, !loading, let mail = current else { return }
        do {
            let policy = LabelPolicy(labels: batch.labels); let label = try policy.id(for: choice)
            var next = batch
            next.mails.removeFirst()
            next.decisions.append(Decision(mail: mail, choice: choice, before: mail.labelIDs.filter { policy.allowed.contains($0) }))
            next.pending.append(Mutation(messageID: mail.id, target: [label]))
            try commit(next)
            Task { await flush() }
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        guard active, canUndo, let decision = batch.decisions.last else { return }
        do {
            var next = batch; next.decisions.removeLast(); next.mails.insert(decision.mail, at: 0)
            next.pending.append(Mutation(messageID: decision.id, target: decision.before))
            try commit(next)
            Task { await flush() }
        } catch { self.error = error.localizedDescription }
    }
    func flush() async {
        guard active, !syncing, !loading, !batch.pending.isEmpty else { return }
        syncing = true; error = nil; defer { syncing = false }
        while active, let operation = batch.pending.first {
            do {
                try await service.setLabels(messageID: operation.messageID, target: operation.target)
                guard active else { return }
                var next = batch
                guard next.pending.first?.id == operation.id else { return }
                next.pending.removeFirst()
                try commit(next)
            } catch { if active { self.error = error.localizedDescription }; return }
        }
    }
}

#if DEBUG
@MainActor final class DemoService: MailService {
    private func text(_ key: String) -> String { AppLanguage.text(key, locale: AppLanguage.currentLocale) }
    static let catalog = [GmailLabel(id: "Label_useful", name: "Smail/Useful", type: "user"), GmailLabel(id: "Label_notUseful", name: "Smail/NotUseful", type: "user")]
    func labels() async throws -> [GmailLabel] { Self.catalog }
    func prepareLabels() async throws -> [GmailLabel] { Self.catalog }
    func batch(excluding: Set<String>) async throws -> [Mail] {
        (1...10).map { Mail(id: String($0, radix: 16), from: $0 == 1 ? "Alex <alex@example.com>" : "Smail Demo <demo@example.com>",
            subject: $0 == 1 ? "A small idea for your next big thing" : String(format: text("示例邮件 %ld：给重要的事留点空间"), $0),
            snippet: text("这是演示邮件。向右划标记有用，向左划标记没用。你的真实邮箱不会改变。"), date: Date(),
            body: text("你好！\n\n每次十封，把注意力还给真正重要的事。\n\nSmail 只改变两个分类标签，原邮件和未读状态保持不变。\n\n这是演示内容，不会连接真实 Gmail。"), labelIDs: ["INBOX", "UNREAD"]) }
    }
    func setLabels(messageID: String, target: [String]) async throws { _ = try LabelPolicy(labels: Self.catalog).changes(target: target) }
    func message(id: String) async throws -> Mail {
        var mail = try await batch(excluding: []).first(where: { $0.id == id })!
        mail.htmlBody = """
        <html><head><style>.hero{background:#e8eee3;padding:24px;border-radius:16px} h1{color:#254f3f} .cta{display:inline-block;padding:14px 22px;background:#254f3f;color:white;text-decoration:none;border-radius:24px}</style></head>
        <body><div class="hero"><h1>\(text("给重要的事留点空间。"))</h1><p>\(text("这是 HTML 演示邮件，保留原始排版。"))</p><a class="cta" href="https://example.com/">\(text("阅读更多"))</a></div><p>\(text("这是一封示例邮件，没有任何真实邮箱操作。"))</p></body></html>
        """
        return mail
    }
}
#endif
