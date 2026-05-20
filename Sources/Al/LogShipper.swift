import Foundation
import CryptoKit

/// Ships transcript utterances to an optional remote server using the
/// sealed-box scheme defined in `Crypto.swift`.
///
/// **Outbox.** Each utterance is enqueued as a JSON record on a single
/// append-only file at `~/Library/Application Support/al/outbox.jsonl`. The
/// plaintext payload lives on disk only because the transcripts themselves
/// already live in `~/Documents/al/`; encrypting the queue would provide no
/// additional confidentiality. We encrypt freshly per send so a server-URL
/// change is non-destructive.
///
/// **Worker loop.** A single Task wakes on enqueue or every 30 s, fetches
/// the server pubkey if missing, then drains the outbox in batches. The
/// server's `(client_id, seq)` primary key makes retries idempotent.
///
/// **Disabled mode.** When the user hasn't set a server URL + PSK the
/// shipper keeps appending to the outbox (so utterances aren't lost during
/// configuration churn) but never sends. A reasonable size cap on the
/// outbox prevents unbounded growth — once the cap is hit we drop the
/// oldest entries with a Log line.
actor LogShipper {

    static let shared = LogShipper()

    // MARK: - Disk layout

    private static let maxOutboxLines = 50_000
    private static let batchSize = 64
    private static let pollSeconds: UInt64 = 30
    private static let backoffSeconds: UInt64 = 15
    /// Refetch the server pubkey when its `valid_until` is within this many
    /// seconds. Should be smaller than the server's rotation lead so that
    /// the client picks up the rotated key before the old one stops being
    /// advertised.
    private static let pubkeyRefreshMargin: TimeInterval = 6 * 3600  // 6 h

    private let stateURL: URL
    private let outboxURL: URL

    // MARK: - Mutable state

    private var nextSeq: UInt64 = 1
    private var lastAckedSeq: UInt64 = 0
    private var serverPubkey: Data?
    private var serverPubkeyForURL: String = ""
    /// Unix seconds the current pubkey is advertised as valid until. 0 = unknown.
    private var serverPubkeyValidUntil: Double = 0

    private var workerTask: Task<Void, Never>?
    private var wakeCont: AsyncStream<Void>.Continuation?
    private var wakeStream: AsyncStream<Void>?
    private var notificationToken: NSObjectProtocol?

    // MARK: - Init

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("al", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateURL = dir.appendingPathComponent("shipper-state.json")
        self.outboxURL = dir.appendingPathComponent("outbox.jsonl")
        loadState()
    }

    // MARK: - Public API

    func start() {
        guard workerTask == nil else { return }
        let (stream, cont) = AsyncStream<Void>.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.wakeStream = stream
        self.wakeCont = cont
        // Listen for settings changes so we re-fetch the pubkey when URL/PSK changes.
        let observer = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleSettingsChange() }
        }
        self.notificationToken = observer

        workerTask = Task { [weak self] in
            await self?.runLoop()
        }
        Log.line("LogShipper: started (next_seq=\(nextSeq), last_acked=\(lastAckedSeq))")
    }

    func stop() async {
        workerTask?.cancel()
        wakeCont?.finish()
        workerTask = nil
        wakeCont = nil
        wakeStream = nil
        if let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
            notificationToken = nil
        }
        Log.line("LogShipper: stopped")
    }

    /// Append a transcript utterance to the outbox. Called from `Pipeline`
    /// after the line has been written to disk so the on-disk transcript
    /// remains the source of truth even if the shipper drops the entry.
    func enqueue(fileId: String, utterance: Utterance) {
        let payload = Payload(
            file_id: fileId,
            source: utterance.source.rawValue,
            started_at: utterance.startedAt.timeIntervalSince1970,
            ended_at: utterance.endedAt.timeIntervalSince1970,
            text: utterance.text
        )
        let entry = OutboxEntry(seq: nextSeq, payload: payload)
        nextSeq &+= 1
        appendOutbox(entry)
        saveState()
        wakeCont?.yield()
    }

    // MARK: - Settings change

    private func handleSettingsChange() async {
        // Invalidate the cached pubkey if the URL changed — it almost
        // certainly belongs to a different server now.
        let snap = await snapshotSettings()
        if snap?.serverURL.absoluteString != serverPubkeyForURL {
            serverPubkey = nil
            serverPubkeyForURL = ""
            serverPubkeyValidUntil = 0
            saveState()
        }
        wakeCont?.yield()
    }

    /// True when the cached pubkey is missing, expired, or close to expiry.
    private func pubkeyNeedsRefresh(for snap: SettingsSnapshot) -> Bool {
        if serverPubkey == nil { return true }
        if serverPubkeyForURL != snap.serverURL.absoluteString { return true }
        if serverPubkeyValidUntil <= 0 { return false }
        return Date().timeIntervalSince1970 + Self.pubkeyRefreshMargin >= serverPubkeyValidUntil
    }

    // MARK: - Worker loop

    private func runLoop() async {
        guard let stream = wakeStream else { return }
        // Periodic ticker so we still retry even without external wakeups.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
                await self?.tick()
            }
        }
        defer { ticker.cancel() }

        // Kick once on start to drain any backlog.
        wakeCont?.yield()

        for await _ in stream {
            if Task.isCancelled { break }
            await processOnce()
        }
    }

    private func tick() { wakeCont?.yield() }

    private func processOnce() async {
        guard let snap = await snapshotSettings() else {
            // not configured — silently keep enqueueing, never send
            return
        }
        // Ensure server pubkey is fresh.
        if pubkeyNeedsRefresh(for: snap) {
            if await fetchPubkey(snapshot: snap) == false {
                await backoff()
                return
            }
        }
        guard let pubkey = serverPubkey else { return }

        let pending = readPending()
        if pending.isEmpty { return }

        let batch = Array(pending.prefix(Self.batchSize))
        var sealed: [SealedEntry] = []
        sealed.reserveCapacity(batch.count)
        for entry in batch {
            do {
                let json = try JSONEncoder().encode(entry.payload)
                let envelope = try Crypto.seal(json, to: pubkey)
                sealed.append(SealedEntry(seq: entry.seq, ciphertext_b64: envelope.base64EncodedString()))
            } catch {
                Log.line("LogShipper: encrypt failed seq=\(entry.seq): \(error.localizedDescription)")
                return
            }
        }

        let req = IngestRequest(client_id: snap.clientId, batch: sealed)
        switch await sendBatch(req, snapshot: snap) {
        case .success(let highestAcked):
            if highestAcked > lastAckedSeq {
                lastAckedSeq = highestAcked
                saveState()
                compactOutbox()
                Log.line("LogShipper: acked up to seq=\(highestAcked) (\(batch.count) sent)")
            }
            // If there's more pending, schedule another pass immediately.
            if pending.count > batch.count {
                wakeCont?.yield()
            }
        case .failure(let why):
            Log.line("LogShipper: send failed: \(why) — backing off")
            await backoff()
        }
    }

    private func backoff() async {
        try? await Task.sleep(nanoseconds: Self.backoffSeconds * 1_000_000_000)
        wakeCont?.yield()
    }

    // MARK: - HTTP

    private struct SettingsSnapshot {
        let serverURL: URL
        let psk: String
        let clientId: String
    }

    @MainActor
    private func snapshotSettings() -> SettingsSnapshot? {
        let s = Settings.shared
        guard let url = s.resolvedServerURL, !s.psk.isEmpty else { return nil }
        return SettingsSnapshot(serverURL: url, psk: s.psk, clientId: s.clientId)
    }

    private func authorize(_ req: inout URLRequest, snapshot: SettingsSnapshot) {
        req.setValue("Bearer \(snapshot.psk)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
    }

    private func fetchPubkey(snapshot: SettingsSnapshot) async -> Bool {
        var req = URLRequest(url: snapshot.serverURL.appendingPathComponent("pubkey"))
        req.httpMethod = "GET"
        authorize(&req, snapshot: snapshot)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                Log.line("LogShipper: /pubkey non-HTTP response")
                return false
            }
            guard http.statusCode == 200 else {
                Log.line("LogShipper: /pubkey status=\(http.statusCode)")
                return false
            }
            let body = try JSONDecoder().decode(PubkeyResponse.self, from: data)
            guard let pk = Data(base64Encoded: body.public_key_b64), pk.count == 32 else {
                Log.line("LogShipper: /pubkey malformed key")
                return false
            }
            serverPubkey = pk
            serverPubkeyForURL = snapshot.serverURL.absoluteString
            serverPubkeyValidUntil = body.valid_until ?? 0
            saveState()
            let validNote: String
            if let until = body.valid_until, until > 0 {
                let secs = until - Date().timeIntervalSince1970
                validNote = String(format: " (valid for %.1f h)", secs / 3600)
            } else {
                validNote = ""
            }
            Log.line("LogShipper: fetched server pubkey from \(snapshot.serverURL.absoluteString)\(validNote)")
            return true
        } catch {
            Log.line("LogShipper: /pubkey error: \(error.localizedDescription)")
            return false
        }
    }

    private enum SendResult {
        case success(highestAcked: UInt64)
        case failure(String)
    }

    private func sendBatch(_ payload: IngestRequest, snapshot: SettingsSnapshot) async -> SendResult {
        var req = URLRequest(url: snapshot.serverURL.appendingPathComponent("logs"))
        req.httpMethod = "POST"
        authorize(&req, snapshot: snapshot)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .failure("encode: \(error.localizedDescription)")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure("non-HTTP") }
            guard http.statusCode == 200 else { return .failure("status=\(http.statusCode)") }
            let ack = try JSONDecoder().decode(IngestAck.self, from: data)
            return .success(highestAcked: UInt64(max(ack.highest_acked_seq, 0)))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Outbox persistence

    private func appendOutbox(_ entry: OutboxEntry) {
        do {
            let data = try JSONEncoder().encode(entry)
            var line = Data()
            line.append(data)
            line.append(0x0A)  // newline
            if !FileManager.default.fileExists(atPath: outboxURL.path) {
                FileManager.default.createFile(atPath: outboxURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: outboxURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.line("LogShipper: outbox append failed: \(error.localizedDescription)")
        }
    }

    private func readPending() -> [OutboxEntry] {
        guard let raw = try? Data(contentsOf: outboxURL) else { return [] }
        var entries: [OutboxEntry] = []
        let decoder = JSONDecoder()
        var start = raw.startIndex
        while start < raw.endIndex {
            guard let nl = raw[start..<raw.endIndex].firstIndex(of: 0x0A) else {
                let chunk = raw[start..<raw.endIndex]
                if !chunk.isEmpty, let e = try? decoder.decode(OutboxEntry.self, from: chunk) {
                    if e.seq > lastAckedSeq { entries.append(e) }
                }
                break
            }
            let chunk = raw[start..<nl]
            if !chunk.isEmpty, let e = try? decoder.decode(OutboxEntry.self, from: chunk) {
                if e.seq > lastAckedSeq { entries.append(e) }
            }
            start = raw.index(after: nl)
        }
        entries.sort { $0.seq < $1.seq }
        return entries
    }

    /// Rewrite the outbox dropping acked rows. Called after every
    /// successful batch ack so the file stays proportional to the unacked
    /// backlog — without this, a steady trickle of small utterances would
    /// look like the outbox never clears.
    private func compactOutbox() {
        guard let raw = try? Data(contentsOf: outboxURL) else { return }
        if raw.isEmpty { return }

        let decoder = JSONDecoder()
        var kept: [OutboxEntry] = []
        var droppedCount = 0
        var start = raw.startIndex
        while start < raw.endIndex {
            let nl = raw[start..<raw.endIndex].firstIndex(of: 0x0A) ?? raw.endIndex
            let chunk = raw[start..<nl]
            if !chunk.isEmpty, let e = try? decoder.decode(OutboxEntry.self, from: chunk) {
                if e.seq > lastAckedSeq {
                    kept.append(e)
                } else {
                    droppedCount += 1
                }
            }
            start = nl == raw.endIndex ? raw.endIndex : raw.index(after: nl)
        }

        // Nothing acked since the last compaction → leave the file alone so
        // we don't burn IO on every poll.
        if droppedCount == 0 && kept.count <= Self.maxOutboxLines { return }

        if kept.count > Self.maxOutboxLines {
            let drop = kept.count - Self.maxOutboxLines
            Log.line("LogShipper: outbox cap reached — dropping \(drop) oldest entries")
            kept = Array(kept.suffix(Self.maxOutboxLines))
        }

        if kept.isEmpty {
            // Empty file is unnecessary — remove it. The next enqueue will
            // recreate it via `FileManager.createFile` in `appendOutbox`.
            try? FileManager.default.removeItem(at: outboxURL)
            return
        }

        var newData = Data()
        let encoder = JSONEncoder()
        for entry in kept {
            if let line = try? encoder.encode(entry) {
                newData.append(line)
                newData.append(0x0A)
            }
        }
        do {
            try newData.write(to: outboxURL, options: .atomic)
        } catch {
            Log.line("LogShipper: compact failed: \(error.localizedDescription)")
        }
    }

    // MARK: - State JSON

    private struct PersistedState: Codable {
        var nextSeq: UInt64
        var lastAckedSeq: UInt64
        var serverPubkeyB64: String?
        var serverPubkeyForURL: String?
        var serverPubkeyValidUntil: Double?
    }

    private func loadState() {
        guard let raw = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(PersistedState.self, from: raw) else {
            return
        }
        self.nextSeq = max(s.nextSeq, 1)
        self.lastAckedSeq = s.lastAckedSeq
        if let b64 = s.serverPubkeyB64, let data = Data(base64Encoded: b64), data.count == 32 {
            self.serverPubkey = data
            self.serverPubkeyForURL = s.serverPubkeyForURL ?? ""
            self.serverPubkeyValidUntil = s.serverPubkeyValidUntil ?? 0
        }
    }

    private func saveState() {
        let s = PersistedState(
            nextSeq: nextSeq,
            lastAckedSeq: lastAckedSeq,
            serverPubkeyB64: serverPubkey?.base64EncodedString(),
            serverPubkeyForURL: serverPubkeyForURL.isEmpty ? nil : serverPubkeyForURL,
            serverPubkeyValidUntil: serverPubkeyValidUntil > 0 ? serverPubkeyValidUntil : nil
        )
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

// MARK: - Wire types

private struct Payload: Codable {
    let file_id: String
    let source: String
    let started_at: Double
    let ended_at: Double
    let text: String
}

private struct OutboxEntry: Codable {
    let seq: UInt64
    let payload: Payload
}

private struct SealedEntry: Codable {
    let seq: UInt64
    let ciphertext_b64: String
}

private struct IngestRequest: Codable {
    let client_id: String
    let batch: [SealedEntry]
}

private struct IngestAck: Codable {
    let highest_acked_seq: Int64
}

private struct PubkeyResponse: Codable {
    let public_key_b64: String
    let valid_until: Double?
}
