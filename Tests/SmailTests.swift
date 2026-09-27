import XCTest
@testable import Smail

@MainActor final class SmailTests: XCTestCase {
    let labels = [GmailLabel(id: "Label_a", name: "Smail/Useful", type: "user"), GmailLabel(id: "Label_b", name: "Smail/NotUseful", type: "user")]
    func testLabelPolicyRejectsSystemAndUnrelatedLabels() throws {
        let policy = LabelPolicy(labels: labels + [GmailLabel(id: "Label_other", name: "Other", type: "user")])
        for forbidden in ["TRASH", "INBOX", "UNREAD", "SPAM", "Label_other", "Label_missing"] {
            XCTAssertThrowsError(try policy.changes(target: [forbidden]))
        }
        XCTAssertEqual(try policy.changes(target: ["Label_a"]), LabelChange(addLabelIds: ["Label_a"], removeLabelIds: ["Label_b"]))
        XCTAssertEqual(try policy.changes(target: []), LabelChange(addLabelIds: [], removeLabelIds: ["Label_a", "Label_b"]))
    }
    func testSpoofedSystemLabelAndRenamedLabelsFailClosed() {
        let invalid = [GmailLabel(id: "TRASH", name: "Smail/Useful", type: "system"), labels[1]]
        XCTAssertThrowsError(try LabelPolicy(labels: invalid).changes(target: ["TRASH"]))
        XCTAssertThrowsError(try LabelPolicy(labels: [labels[0]]).changes(target: ["Label_a"]))
    }
    func testMIMEUsesPlainTextAndNeverAttachmentOrScript() throws {
        let json = """
        {"id":"abc","labelIds":["INBOX","UNREAD"],"internalDate":"1000","payload":{"mimeType":"multipart/alternative","headers":[{"name":"Subject","value":"Hello"}],"parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8g8J-YgA"}},{"mimeType":"text/plain","filename":"secret.txt","body":{"data":"U2VjcmV0"}}]}}
        """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8)).mail()
        XCTAssertEqual(message.body, "Hello 😀")
        XCTAssertEqual(message.labelIDs, ["INBOX", "UNREAD"])
        XCTAssertEqual(GmailMessage.cleanHTML("<style>hidden</style><p>A &amp; B</p><script>alert(1)</script><img src='https://example.com/pixel'>"), "A & B")
        XCTAssertEqual(GmailMessage.entities("&#x1f600; &#65;"), "😀 A")
    }
    func testPersistentIntentSurvivesFailureRestartAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = BatchDisk(root: root); let api = FakeService(labels: labels)
        let store = try BatchStore(account: "account-a", service: api, disk: disk)
        await store.load(); api.fail = true
        store.choose(.useful); await store.flush()
        XCTAssertEqual(store.batch.pending.count, 1)
        XCTAssertEqual(store.batch.decisions.count, 1)
        XCTAssertFalse(store.canUndo)
        store.stop()
        let restored = try BatchStore(account: "account-a", service: api, disk: disk)
        XCTAssertEqual(restored.batch.pending.count, 1)
        XCTAssertTrue(try disk.load("account-b").mails.isEmpty)
        api.fail = false; await restored.flush()
        XCTAssertTrue(restored.canUndo)
        restored.undo(); await restored.flush()
        XCTAssertEqual(restored.batch.mails.count, 1)
        XCTAssertTrue(restored.batch.decisions.isEmpty)
        XCTAssertEqual(api.targets.last, [])
        XCTAssertEqual(restored.current?.labelIDs, ["INBOX", "UNREAD", "Label_other"])
    }
    func testSwitchChoiceAfterUndoMaintainsOperationOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let api = FakeService(labels: labels)
        let store = try BatchStore(account: "a", service: api, disk: BatchDisk(root: root))
        await store.load(); store.choose(.useful); await store.flush()
        store.undo(); store.choose(.notUseful); await store.flush()
        XCTAssertEqual(api.targets, [["Label_a"], [], ["Label_b"]])
        XCTAssertTrue(store.batch.pending.isEmpty)
        XCTAssertEqual(store.batch.decisions.last?.choice, .notUseful)
    }
}

@MainActor private final class FakeService: MailService {
    let catalog: [GmailLabel]
    var fail = false
    var targets: [[String]] = []
    init(labels: [GmailLabel]) { catalog = labels }
    func labels() async throws -> [GmailLabel] { catalog }
    func prepareLabels() async throws -> [GmailLabel] { catalog }
    func batch(excluding: Set<String>) async throws -> [Mail] {
        [Mail(id: "abc", from: "test@example.com", subject: "Test", snippet: "Test", date: Date(), body: "Test", labelIDs: ["INBOX", "UNREAD", "Label_other"])]
    }
    func setLabels(messageID: String, target: [String]) async throws {
        if fail { throw SmailError.message("Offline") }
        _ = try LabelPolicy(labels: catalog).changes(target: target)
        targets.append(target)
    }
    func message(id: String) async throws -> Mail { try await batch(excluding: [])[0] }
}

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class GmailTransportTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    func client() -> GmailClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return GmailClient(session: URLSession(configuration: config)) { "synthetic-token" }
    }
    func testNoWriteForSystemLabelOrPathInjection() async throws {
        var methods: [String] = []
        StubProtocol.handler = { request in
            methods.append(request.httpMethod!)
            return (200, Data(#"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"},{"id":"Label_b","name":"Smail/NotUseful","type":"user"}]}"#.utf8))
        }
        let api = client()
        do { try await api.setLabels(messageID: "abc", target: ["TRASH"]); XCTFail("Must reject") } catch {}
        do { try await api.setLabels(messageID: "../trash", target: ["Label_a"]); XCTFail("Must reject") } catch {}
        XCTAssertEqual(methods, ["GET"])
    }
    func testOnlyFixedModifyRequestAndPreservesOtherLabels() async throws {
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if request.httpMethod == "GET" {
                return (200, Data(#"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"},{"id":"Label_b","name":"Smail/NotUseful","type":"user"}]}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/gmail/v1/users/me/messages/abc/modify")
            let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024); let count = stream.read(&bytes, maxLength: bytes.count)
            let change = try JSONDecoder().decode(LabelChange.self, from: Data(bytes.prefix(count)))
            XCTAssertEqual(change, LabelChange(addLabelIds: ["Label_a"], removeLabelIds: ["Label_b"]))
            return (200, Data(#"{"id":"abc","labelIds":["INBOX","UNREAD","Label_other","Label_a"]}"#.utf8))
        }
        try await client().setLabels(messageID: "abc", target: ["Label_a"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    }
    func testSparseLabelCreationIsReadBackAndValidated() async throws {
        var created = false
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" { created = true; return (200, Data(#"{"id":"Label_b"}"#.utf8)) }
            let labels = created ? #"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"},{"id":"Label_b","name":"Smail/NotUseful","type":"user"}]}"# : #"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"}]}"#
            return (200, Data(labels.utf8))
        }
        let labels = try await client().prepareLabels()
        XCTAssertTrue(created); XCTAssertEqual(labels.count, 2)
    }
    func testBatchIncludesReadMailAndSelectsNewestAcrossShuffledPages() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = GmailClient(session: URLSession(configuration: config), now: { Date(timeIntervalSince1970: 200_000) }) { "synthetic-token" }
        var fullReads = Set<String>()
        var pageCount = 0
        let lock = NSLock()
        StubProtocol.handler = { request in
            lock.lock(); defer { lock.unlock() }
            XCTAssertEqual(request.httpMethod, "GET")
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if url.lastPathComponent == "labels" {
                return (200, Data(#"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"},{"id":"Label_b","name":"Smail/NotUseful","type":"user"}]}"#.utf8))
            }
            if url.lastPathComponent == "messages" {
                pageCount += 1
                let q = query.first(where: { $0.name == "q" })!.value!
                XCTAssertTrue(q.contains("in:inbox"))
                XCTAssertTrue(q.contains("-label:Smail/Useful"))
                XCTAssertTrue(q.contains("-label:Smail/NotUseful"))
                XCTAssertFalse(q.contains("is:unread"))
                if query.contains(where: { $0.name == "pageToken" }) {
                    return (200, Data(#"{"messages":[{"id":"c"},{"id":"b"},{"id":"a"}]}"#.utf8))
                }
                let ids = (1...10).map { ["id": String($0, radix: 16)] }
                return (200, try JSONSerialization.data(withJSONObject: ["messages": ids, "nextPageToken": "second"]))
            }
            let id = url.lastPathComponent
            if query.contains(where: { $0.name == "format" && $0.value == "full" }) { fullReads.insert(id) }
            let labels = id == "a" ? ["INBOX", "Label_a"] : (id == "c" ? ["INBOX"] : ["INBOX", "UNREAD"])
            return (200, try JSONSerialization.data(withJSONObject: ["id": id, "internalDate": String(199_000_000 + Int(id, radix: 16)! * 1000), "labelIds": labels]))
        }
        let batch = try await api.batch(excluding: [])
        XCTAssertEqual(pageCount, 2)
        XCTAssertEqual(batch.map(\.id), ["c", "b", "9", "8", "7", "6", "5", "4", "3", "2"])
        XCTAssertFalse(batch[0].labelIDs.contains("UNREAD"))
        XCTAssertEqual(fullReads, Set(batch.map(\.id)))
    }
    func testBatchSearchesOlderWindowsWithoutLosingBoundaryMessages() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let now: Double = 200_000
        let boundary = 200_001 - 86_400
        let api = GmailClient(session: URLSession(configuration: config), now: { Date(timeIntervalSince1970: now) }) { "synthetic-token" }
        var searches = 0
        let lock = NSLock()
        StubProtocol.handler = { request in
            lock.lock(); defer { lock.unlock() }
            let url = request.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if url.lastPathComponent == "labels" {
                return (200, Data(#"{"labels":[{"id":"Label_a","name":"Smail/Useful","type":"user"},{"id":"Label_b","name":"Smail/NotUseful","type":"user"}]}"#.utf8))
            }
            if url.lastPathComponent == "messages" {
                searches += 1
                let q = query.first(where: { $0.name == "q" })!.value!
                if searches == 1 {
                    XCTAssertTrue(q.contains("after:\(boundary - 1) before:200001"))
                    return (200, Data(#"{"messages":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#.utf8))
                }
                XCTAssertTrue(q.contains("before:\(boundary)"))
                return (200, Data(#"{"messages":[{"id":"c"},{"id":"d"}]}"#.utf8))
            }
            let id = url.lastPathComponent
            let milliseconds = ["a": 200_000_000, "b": boundary * 1000, "c": boundary * 1000 - 1, "d": 1000][id]!
            return (200, try JSONSerialization.data(withJSONObject: ["id": id, "internalDate": String(milliseconds), "labelIds": ["INBOX"]]))
        }
        let batch = try await api.batch(excluding: ["d"])
        XCTAssertEqual(searches, 2)
        XCTAssertEqual(batch.map(\.id), ["a", "b", "c"])
    }
}
