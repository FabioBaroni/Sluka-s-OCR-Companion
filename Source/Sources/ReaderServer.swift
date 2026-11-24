import Foundation
import Network
import Security

struct ReaderSnapshot: Codable {
    var revision: Int = 0
    var textRevision: Int = 0
    var text: String = ""
    var status: String = "Ready. Select a screen area in OCR Companion."
    var language: String = "zh-Hans"
    var refreshIfUnannotated = false
    var pointerOffset: Int? = nil
    var command: SlukaCommand?
}
struct SlukaObservation: Decodable {
    struct Word: Decodable {
        let surface: String
        let key: String
        let status: Int
        let gradeable: Bool
    }

    struct Lookup: Decodable, Equatable {
        let surface: String
        let key: String
        let reading: String
        let definition: String
        let status: Int?
        let gradeable: Bool?

        var valid: Bool {
            !key.isEmpty && key.utf16.count <= 128 && reading.utf16.count <= 128 &&
                definition.utf16.count <= 1500 && (status.map { (0...7).contains($0) } ?? true)
        }
    }

    struct PointerWord: Decodable {
        let surface: String
        let start: Int

        var range: NSRange { NSRange(location: start, length: surface.utf16.count) }
    }

    let textRevision: Int
    let words: [Word]
    let lookup: Lookup?
    let ambiguousSurfaces: [String]?
    let pointerWord: PointerWord?

    func matches(_ snapshot: ReaderSnapshot) -> Bool {
        guard textRevision == snapshot.textRevision, !snapshot.text.isEmpty,
              words.count <= 64 else { return false }
        func visibleSurface(_ surface: String) -> Bool {
            !surface.isEmpty && surface.utf16.count <= 64 && snapshot.text.contains(surface)
        }
        guard Set(words.map(\.surface)).count == words.count,
              words.allSatisfy({ visibleSurface($0.surface) && !$0.key.isEmpty &&
                  $0.key.utf16.count <= 128 && (0...7).contains($0.status) }) else { return false }
        if let ambiguousSurfaces {
            guard ambiguousSurfaces.count <= 64, ambiguousSurfaces.allSatisfy(visibleSurface),
                  Set(ambiguousSurfaces).isDisjoint(with: words.map(\.surface)) else { return false }
        }
        if let pointerWord {
            guard let pointer = snapshot.pointerOffset,
                  pointerWord.start >= 0, pointerWord.start <= pointer, pointer < snapshot.text.utf16.count,
                  words.contains(where: { $0.surface == pointerWord.surface }),
                  let range = Range(pointerWord.range, in: snapshot.text),
                  snapshot.text[range] == pointerWord.surface,
                  NSLocationInRange(pointer, pointerWord.range) else { return false }
        }
        guard let lookup else { return true }
        return visibleSurface(lookup.surface) && lookup.valid
    }
}

struct ReaderReply {
    var status: Int
    var type: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var sluka: SlukaObservation?
    var slukaCommit: SlukaCommandTicket?
    var slukaResult: SlukaCommandResult?
}

struct ReaderRequest {
    let method: String
    let path: String
    let headers: [String: String]

    init?(_ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let start = first.split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2] == "HTTP/1.1" else { return nil }
        method = String(start[0])
        path = String(start[1])
        var values: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, values[name] == nil else { return nil }
            values[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = values
    }

    var isSluka: Bool { method == "POST" && ["/sluka", "/sluka-commit", "/sluka-result", "/sluka-disconnect"].contains(path) }
    var slukaBodyLength: Int? {
        guard let length = headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(length), (1...ReaderPolicy.maxSlukaBody).contains(value) else { return nil }
        return value
    }
}

struct ReaderPolicy {
    static let maxSlukaBody = 20 * 1024
    static let assetTypes = [
        "/": "text/html; charset=utf-8",
        "/reader.css": "text/css; charset=utf-8",
        "/reader.js": "text/javascript; charset=utf-8",
        "/sluka-observer.js": "text/javascript; charset=utf-8",
        "/sluka-controls.js": "text/javascript; charset=utf-8"
    ]
    static let assetFiles = ["/": "index.html", "/reader.css": "reader.css", "/reader.js": "reader.js",
                             "/sluka-observer.js": "sluka-observer.js", "/sluka-controls.js": "sluka-controls.js"]
    let port: UInt16
    let key: String
    var origin: String { "http://127.0.0.1:\(port)" }

    func route(_ rawRequest: String, snapshot: ReaderSnapshot, assets: [String: Data], body: Data = Data()) -> ReaderReply {
        guard let request = ReaderRequest(rawRequest) else { return ReaderReply(status: 400) }
        return route(request, snapshot: snapshot, assets: assets, body: body)
    }

    func route(_ request: ReaderRequest, snapshot: ReaderSnapshot, assets: [String: Data], body: Data,
               command: SlukaCommand? = nil) -> ReaderReply {
        guard request.method == "GET" || request.isSluka else { return ReaderReply(status: 405) }
        let headers = request.headers
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil else {
            return ReaderReply(status: 403)
        }
        if let source = headers["origin"], source != origin { return ReaderReply(status: 403) }
        if let site = headers["sec-fetch-site"], !["same-origin", "none"].contains(site) { return ReaderReply(status: 403) }

        let authenticated = headers["x-ocrcompanion-session"] == key && headers["sec-fetch-site"] == "same-origin"
        if request.isSluka {
            guard authenticated, headers["origin"] == origin else { return ReaderReply(status: 403) }
            guard headers["content-type"] == "application/json", request.slukaBodyLength == body.count else {
                return ReaderReply(status: 400)
            }
            let decoder = JSONDecoder()
            switch request.path {
            case "/sluka-disconnect":
                return ReaderReply(status: 204)
            case "/sluka-commit":
                guard let ticket = try? decoder.decode(SlukaCommandTicket.self, from: body) else {
                    return ReaderReply(status: 400)
                }
                return ReaderReply(status: 204, slukaCommit: ticket)
            case "/sluka-result":
                guard let result = try? decoder.decode(SlukaCommandResult.self, from: body) else {
                    return ReaderReply(status: 400)
                }
                return ReaderReply(status: 204, slukaResult: result)
            default:
                guard let observation = try? decoder.decode(SlukaObservation.self, from: body) else {
                    return ReaderReply(status: 400)
                }
                guard observation.matches(snapshot) else { return ReaderReply(status: 409) }
                return ReaderReply(status: 204, sluka: observation)
            }
        }
        guard body.isEmpty, headers["content-length"] == nil || headers["content-length"] == "0" else {
            return ReaderReply(status: 403)
        }
        if request.path == "/state" {
            guard authenticated else { return ReaderReply(status: 403) }
            var state = snapshot
            if headers["x-ocrcompanion-view"] == "compact", headers["x-ocrcompanion-controls"] == "ready" {
                state.command = command
            }
            return ReaderReply(status: 200, type: "application/json; charset=utf-8", body: (try? JSONEncoder().encode(state)) ?? Data())
        }
        guard let type = Self.assetTypes[request.path], let asset = assets[request.path] else { return ReaderReply(status: 404) }
        return ReaderReply(status: 200, type: type, body: asset)
    }
}

final class ReaderServer {
    private let queue = DispatchQueue(label: "local.ocrcompanion.screen-reader")
    private var listener: NWListener?
    private var snapshot = ReaderSnapshot()
    private var reader = ReaderLease()
    private var expiryWork: DispatchWorkItem?
    private var lastSluka: SlukaObservation?
    private var pending: BoundedSlukaCommand?
    private var connections: [UUID: NWConnection] = [:]
    private var assets: [String: Data] = [:]
    private(set) var policy: ReaderPolicy!
    var onStudyViewChanged: (() -> Void)?
    var onSlukaObservation: ((SlukaObservation) -> Void)?

    func currentTextRevision() -> Int { queue.sync { snapshot.textRevision } }
    func hasRecentStudyView() -> Bool {
        queue.sync { reader.isActive(at: ProcessInfo.processInfo.systemUptime) }
    }
    var url: URL { URL(string: policy.origin + "/#session=" + policy.key)! }
    func start(ready: @escaping (Result<URL, Error>) -> Void) throws {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw NSError(domain: "OCRCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a secure reader session."])
        }
        let key = random.map { String(format: "%02x", $0) }.joined()
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Reader") else { throw CocoaError(.fileNoSuchFile) }
        for (path, file) in ReaderPolicy.assetFiles {
            assets[path] = try Data(contentsOf: root.appendingPathComponent(file))
        }
        let parameters = NWParameters.tcp
        // Bind only IPv4 loopback; never expose the reader to the LAN.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        var completed = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !completed, let port = listener.port else { return }; completed = true
                self.policy = ReaderPolicy(port: port.rawValue, key: key)
                ready(.success(self.url))
            case .failed(let error): if !completed { completed = true; ready(.failure(error)) }
            default: break
            }
        }
        listener.start(queue: queue)
    }
    func publish(text: String? = nil, status: String, language: String, refreshIfUnannotated: Bool = false,
                 pointerOffset: Int? = nil) {
        queue.async {
            if let text {
                self.finish(.stale)
                self.lastSluka = nil
                self.snapshot.text = text
                self.snapshot.pointerOffset = pointerOffset
                self.snapshot.textRevision += 1
            }
            self.snapshot.status = status; self.snapshot.language = language
            self.snapshot.refreshIfUnannotated = refreshIfUnannotated
            self.snapshot.revision += 1
        }
    }
    func clear() { publish(text: "", status: "Text cleared. Ready for another capture.", language: "zh-Hans") }
    func requestSluka(_ word: SlukaObservation.Word, revision: Int, grade: Int?, mayWake: Bool = true,
                      completion: @escaping (SlukaCommandResult.Outcome, SlukaCommandResult?) -> Void,
                      wake: @escaping () -> Void) {
        queue.async {
            guard self.pending == nil else { completion(.busy, nil); return }
            guard self.snapshot.textRevision == revision,
                  self.lastSluka?.words.contains(where: {
                      $0.surface == word.surface && $0.key == word.key && $0.status == word.status &&
                          (grade == nil || $0.gradeable)
                  }) == true,
                  grade.map({ (0...6).contains($0) }) ?? true else {
                completion(.stale, nil); return
            }
            let lifetime: TimeInterval = mayWake ? 14 : 9
            self.enqueue(surface: word.surface, key: word.key, status: word.status, grade: grade,
                         revision: revision, lifetime: lifetime, completion: completion, wake: mayWake ? wake : nil)
        }
    }

    func requestTranslation(_ text: String, revision: Int,
                            completion: @escaping (SlukaCommandResult.Outcome, SlukaCommandResult?) -> Void) {
        queue.async {
            guard self.pending == nil else { completion(.busy, nil); return }
            guard self.hasOwner, self.snapshot.textRevision == revision, text == self.snapshot.text,
                  (2...1200).contains(text.utf16.count) else { completion(.stale, nil); return }
            self.enqueue(surface: text, key: "", status: 0, grade: nil, revision: revision,
                         lifetime: 18, translatesPassage: true, completion: completion, wake: nil)
        }
    }

    private var hasOwner: Bool {
        reader.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    private func enqueue(surface: String, key: String, status: Int, grade: Int?, revision: Int, lifetime: TimeInterval,
                         translatesPassage: Bool? = nil,
                         completion: @escaping (SlukaCommandResult.Outcome, SlukaCommandResult?) -> Void,
                         wake: (() -> Void)?) {
        let id = UUID().uuidString.lowercased()
        let expiresAt = Int64((Date().timeIntervalSince1970 + lifetime) * 1_000)
        let command = SlukaCommand(id: id, textRevision: revision, surface: surface, key: key,
                                   expectedStatus: status, grade: grade, expiresAt: expiresAt,
                                   translatesPassage: translatesPassage)
        pending = BoundedSlukaCommand(request: command, callback: completion)
        if let wake {
            queue.asyncAfter(deadline: .now() + 3) {
                if self.pending?.request.id == id, self.pending?.offered == false { wake() }
            }
        }
        queue.asyncAfter(deadline: .now() + lifetime) {
            if self.pending?.request.id == id {
                self.finish(self.pending?.committed == true ? .unconfirmed : .unavailable)
            }
        }
    }

    private func finish(_ outcome: SlukaCommandResult.Outcome, _ result: SlukaCommandResult? = nil) {
        guard let pending else { return }
        self.pending = nil
        pending.callback(outcome, result)
    }

    private func acceptCommit(_ ticket: SlukaCommandTicket) -> Bool {
        guard let pending, !pending.committed, pending.request.grade != nil,
              pending.matches(id: ticket.id, textRevision: ticket.textRevision),
              snapshot.textRevision == ticket.textRevision,
              lastSluka?.words.contains(where: {
                  $0.surface == pending.request.surface && $0.key == pending.request.key &&
                      $0.status == pending.request.expectedStatus && $0.gradeable
              }) == true else { return false }
        self.pending?.committed = true
        return true
    }

    private func invalidateObservation() {
        lastSluka = nil
        finish(pending?.committed == true ? .unconfirmed : .unavailable)
    }

    private func disconnectReader() {
        reader = ReaderLease()
        expiryWork?.cancel()
        expiryWork = nil
        invalidateObservation()
        onStudyViewChanged?()
    }

    private func scheduleExpiry() {
        expiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.reader.isActive(at: ProcessInfo.processInfo.systemUptime) {
                self.scheduleExpiry()
            } else {
                self.disconnectReader()
            }
        }
        expiryWork = work
        let remaining = max(0.01, reader.expiresAt - ProcessInfo.processInfo.systemUptime)
        queue.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(connection, data: Data())
    }
    private func receive(_ connection: NWConnection, data: Data) {
        let maxHeader = 8192
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxHeader) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data
            if let bytes { data.append(bytes) }
            let canReadMore = !complete && error == nil
            guard data.count <= maxHeader + ReaderPolicy.maxSlukaBody else {
                self.send(ReaderReply(status: 413), connection); return
            }
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
                if data.count >= maxHeader { self.send(ReaderReply(status: 413), connection) }
                else if canReadMore { self.receive(connection, data: data) }
                else { connection.cancel() }
                return
            }
            guard boundary.upperBound <= maxHeader,
                  let header = String(data: data[..<boundary.lowerBound], encoding: .utf8),
                  let request = ReaderRequest(header), let policy = self.policy else {
                self.send(ReaderReply(status: 400), connection); return
            }
            let length = request.slukaBodyLength ?? 0
            let received = data.count - boundary.upperBound
            if request.isSluka && received < length && canReadMore {
                self.receive(connection, data: data)
                return
            }
            guard received == (request.isSluka ? length : 0) else {
                self.send(ReaderReply(status: 400), connection); return
            }
            let readerID = request.headers["x-ocrcompanion-reader"].flatMap { UUID(uuidString: $0) }
            let isReaderPoll = request.path == "/state" && request.headers["x-ocrcompanion-view"] == "compact"
            let now = ProcessInfo.processInfo.systemUptime
            let mayReceive = isReaderPoll && self.reader.owns(readerID, at: now)
            let offer = mayReceive ? self.pending.flatMap { !$0.offered && $0.unexpired ? $0.request : nil } : nil
            var reply = policy.route(request, snapshot: self.snapshot, assets: self.assets,
                                     body: Data(data[boundary.upperBound...]), command: offer)
            if reply.status == 200, isReaderPoll {
                let oldOwner = self.reader.owner
                guard self.reader.poll(readerID, joining: request.headers["x-ocrcompanion-join"] == "1", at: now) else {
                    self.send(ReaderReply(status: 409), connection)
                    return
                }
                if oldOwner != self.reader.owner {
                    self.invalidateObservation()
                    self.scheduleExpiry()
                    self.onStudyViewChanged?()
                }
                if offer != nil, request.headers["x-ocrcompanion-controls"] == "ready" {
                    self.pending?.offered = true
                }
            }
            if reply.status == 200, isReaderPoll, offer == nil,
               request.headers["x-ocrcompanion-wait"].flatMap(Int.init) == self.snapshot.textRevision {
                self.queue.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    guard let self else { connection.cancel(); return }
                    let current = ProcessInfo.processInfo.systemUptime
                    guard self.reader.owns(readerID, at: current) else {
                        self.send(ReaderReply(status: 409), connection)
                        return
                    }
                    let command = self.pending.flatMap { !$0.offered && $0.unexpired ? $0.request : nil }
                    let ready = request.headers["x-ocrcompanion-controls"] == "ready"
                    let response = policy.route(request, snapshot: self.snapshot, assets: self.assets, body: Data(), command: command)
                    if ready, command != nil, response.status == 200 { self.pending?.offered = true }
                    self.send(response, connection)
                }
                return
            }
            if reply.status == 204, request.isSluka {
                guard self.reader.owns(readerID, at: now) else {
                    self.send(ReaderReply(status: 409), connection)
                    return
                }
                if request.path == "/sluka-disconnect" { self.disconnectReader() }
            }
            if let observation = reply.sluka {
                self.lastSluka = observation
                self.onSlukaObservation?(observation)
            }
            if let ticket = reply.slukaCommit, !self.acceptCommit(ticket) {
                reply = ReaderReply(status: 409)
            }
            if let result = reply.slukaResult {
                if self.pending?.accepts(result) == true {
                    self.finish(result.outcome, result)
                } else {
                    reply = ReaderReply(status: 409)
                }
            }
            self.send(reply, connection)
        }
    }
    private func send(_ response: ReaderReply, _ connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        default: reason = "Request rejected"
        }
        let headers = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n"
        var bytes = Data(headers.utf8); bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}


struct ReaderLease {
    private(set) var owner: UUID?
    private(set) var expiresAt: TimeInterval = 0

    func isActive(at now: TimeInterval) -> Bool { owner != nil && now < expiresAt }
    func owns(_ id: UUID?, at now: TimeInterval) -> Bool { isActive(at: now) && owner == id }

    mutating func poll(_ id: UUID?, joining: Bool, at now: TimeInterval) -> Bool {
        guard let id, joining || owns(id, at: now) else { return false }
        owner = id
        expiresAt = now + 75
        return true
    }
}
