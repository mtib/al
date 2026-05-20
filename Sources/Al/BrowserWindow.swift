import AppKit
import Foundation
import SwiftUI

// MARK: - Window controller

@MainActor
final class BrowserWindowController {

    static let shared = BrowserWindowController()

    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            // Re-opening a hidden window doesn't fire `.onAppear` on the
            // SwiftUI root, so we nudge the view to refresh by hand.
            NotificationCenter.default.post(name: .browserShouldRefresh, object: nil)
            return
        }
        let view = BrowserView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Al — Browse & Search"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 880, height: 560))
        w.center()
        self.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    /// Posted by `BrowserWindowController.show()` whenever the user opens
    /// (or re-opens) the Browse window. `BrowserView` listens and reloads.
    static let browserShouldRefresh = Notification.Name("al.browser.shouldRefresh")
}

// MARK: - HTTP client

enum AlServerError: LocalizedError {
    case notConfigured
    case http(Int)
    case transport(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:    return "Server URL or pre-shared key isn't set. Open Options… first."
        case .http(let code):   return "Server returned HTTP \(code)."
        case .transport(let m): return "Network error: \(m)"
        case .decode(let m):    return "Failed to decode response: \(m)"
        }
    }
}

struct ServerDocumentHit: Decodable, Identifiable, Equatable {
    let doc_id: String
    let text_hash: String
    let started_at: Double
    let ended_at: Double
    let entry_count: Int
    let client_ids: [String]
    let snippet: String
    let score: Double?

    var id: String { doc_id }
}

struct ServerDocumentSearchResponse: Decodable {
    let hits: [ServerDocumentHit]
}

struct ServerDocumentListResponse: Decodable {
    let documents: [ServerDocumentHit]
}

struct ServerDocumentDetailEntry: Decodable, Identifiable {
    let client_id: String
    let seq: Int
    let file_id: String
    let source: String
    let started_at: Double
    let ended_at: Double
    let text: String

    var id: String { "\(client_id)#\(seq)" }
}

struct ServerDocumentDetail: Decodable {
    let doc_id: String
    let text_hash: String
    let started_at: Double
    let ended_at: Double
    let entry_count: Int
    let client_ids: [String]
    let snippet: String
    let entries: [ServerDocumentDetailEntry]
}

enum AlClient {

    @MainActor
    private static func snapshot() -> (URL, String)? {
        let s = Settings.shared
        guard let url = s.resolvedServerURL, !s.psk.isEmpty else { return nil }
        return (url, s.psk)
    }

    private static func request(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let snap = await snapshot() else { throw AlServerError.notConfigured }
        var components = URLComponents(url: snap.0.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw AlServerError.transport("bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(snap.1)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AlServerError.transport("non-HTTP") }
            guard http.statusCode == 200 else { throw AlServerError.http(http.statusCode) }
            return data
        } catch let e as AlServerError {
            throw e
        } catch {
            throw AlServerError.transport(error.localizedDescription)
        }
    }

    static func hybridSearch(_ query: String, offset: Int, limit: Int) async throws -> [ServerDocumentHit] {
        let data = try await request(path: "search/hybrid", query: [
            .init(name: "q", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
        ])
        do {
            return try JSONDecoder().decode(ServerDocumentSearchResponse.self, from: data).hits
        } catch {
            throw AlServerError.decode(error.localizedDescription)
        }
    }

    static func recentDocuments(offset: Int, limit: Int) async throws -> [ServerDocumentHit] {
        let data = try await request(path: "documents", query: [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
        ])
        do {
            return try JSONDecoder().decode(ServerDocumentListResponse.self, from: data).documents
        } catch {
            throw AlServerError.decode(error.localizedDescription)
        }
    }

    static func document(_ docId: String) async throws -> ServerDocumentDetail {
        let data = try await request(path: "document/\(docId)")
        do {
            return try JSONDecoder().decode(ServerDocumentDetail.self, from: data)
        } catch {
            throw AlServerError.decode(error.localizedDescription)
        }
    }
}

// MARK: - View model

@MainActor
final class BrowserViewModel: ObservableObject {

    @Published var query: String = ""
    @Published var results: [ServerDocumentHit] = []
    @Published var loading: Bool = false
    @Published var loadingMore: Bool = false
    @Published var atEnd: Bool = false
    @Published var errorMessage: String?

    @Published var selectedDocument: ServerDocumentDetail?
    @Published var loadingDetail: Bool = false
    @Published var copyConfirmation: Bool = false

    private var copyResetTask: Task<Void, Never>?

    private static let pageSize = 30

    /// Token incremented on every new search; in-flight loads compare against
    /// it before publishing, so a slow request from an older query can't
    /// overwrite results from a newer one.
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func formatTime(_ epoch: Double) -> String {
        Self.dateFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func formatRange(_ start: Double, _ end: Double) -> String {
        let s = Self.dateFormatter.string(from: Date(timeIntervalSince1970: start))
        let secs = end - start
        let minutes = Int(secs / 60)
        if minutes < 1 { return "\(s) — < 1 min" }
        if minutes < 60 { return "\(s) — \(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return "\(s) — \(h)h \(m)m"
    }

    var isShippingConfigured: Bool {
        Settings.shared.isShippingConfigured
    }

    /// Called from the search field's onChange — debounces to avoid hammering
    /// the server while the user is mid-typing.
    func queryChanged() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)  // 250 ms
            if Task.isCancelled { return }
            self.reload()
        }
    }

    /// Reset and fetch page 0.
    func reload() {
        generation &+= 1
        let myGen = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        atEnd = false
        loading = true
        errorMessage = nil
        Task {
            do {
                let page = try await fetchPage(query: trimmed, offset: 0)
                guard myGen == generation else { return }
                results = page
                atEnd = page.count < Self.pageSize
            } catch let e as AlServerError {
                guard myGen == generation else { return }
                errorMessage = e.localizedDescription
            } catch {
                guard myGen == generation else { return }
                errorMessage = error.localizedDescription
            }
            if myGen == generation { loading = false }
        }
    }

    /// Append the next page; called by the infinite scroll trigger.
    func loadMore() {
        guard !loading, !loadingMore, !atEnd else { return }
        let myGen = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = results.count
        loadingMore = true
        Task {
            do {
                let page = try await fetchPage(query: trimmed, offset: offset)
                guard myGen == generation else { return }
                // De-dupe by doc_id in case docs shift across pages (the server
                // recomputes documents lazily so a doc seen on page N could
                // reappear on N+1 if new entries arrived).
                let known = Set(results.map { $0.id })
                let fresh = page.filter { !known.contains($0.id) }
                results.append(contentsOf: fresh)
                atEnd = page.count < Self.pageSize
            } catch let e as AlServerError {
                guard myGen == generation else { return }
                errorMessage = e.localizedDescription
                atEnd = true
            } catch {
                guard myGen == generation else { return }
                errorMessage = error.localizedDescription
                atEnd = true
            }
            if myGen == generation { loadingMore = false }
        }
    }

    private func fetchPage(query trimmed: String, offset: Int) async throws -> [ServerDocumentHit] {
        if trimmed.isEmpty {
            return try await AlClient.recentDocuments(offset: offset, limit: Self.pageSize)
        }
        return try await AlClient.hybridSearch(trimmed, offset: offset, limit: Self.pageSize)
    }

    /// Copies the document's plain text (space-joined entry text, no timestamps
    /// or source labels) to the system pasteboard. Flashes a confirmation flag
    /// that the view resets after a second.
    func copyDocumentToClipboard(_ doc: ServerDocumentDetail) {
        let joined = doc.entries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        copyConfirmation = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { self.copyConfirmation = false }
        }
    }

    func openDocument(_ hit: ServerDocumentHit) {
        let isSameSelection = selectedDocument?.doc_id == hit.doc_id
        if !isSameSelection {
            // Wipe the detail pane only when switching to a different doc so
            // a re-click on the active row just refreshes in place instead
            // of flashing the empty state.
            selectedDocument = nil
            copyConfirmation = false
            copyResetTask?.cancel()
        }
        loadingDetail = !isSameSelection
        Task {
            do {
                let fresh = try await AlClient.document(hit.doc_id)
                // Don't clobber the pane if the user has moved on in the
                // meantime.
                if selectedDocument == nil || selectedDocument?.doc_id == hit.doc_id {
                    selectedDocument = fresh
                }
            } catch let e as AlServerError {
                errorMessage = e.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            loadingDetail = false
        }
    }

    /// Silent re-fetch of the currently selected document. Used by the
    /// 5-second background ticker — failures are swallowed so a temporarily
    /// offline server doesn't replace the pane with an error banner.
    func refreshSelectedDocument() {
        guard let current = selectedDocument else { return }
        let docId = current.doc_id
        Task {
            do {
                let fresh = try await AlClient.document(docId)
                if selectedDocument?.doc_id == docId {
                    selectedDocument = fresh
                }
            } catch {
                // intentionally silent
            }
        }
    }
}

// MARK: - View

struct BrowserView: View {

    @StateObject private var model = BrowserViewModel()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if !model.isShippingConfigured {
                emptyState(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Not configured",
                    detail: "Set the server URL and pre-shared key in Options… first."
                )
            } else {
                HSplitView {
                    resultsPane
                        .frame(minWidth: 320, idealWidth: 420)
                    detailPane
                        .frame(minWidth: 320)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .browserShouldRefresh)) { _ in
            model.reload()
        }
        .task {
            // Refresh the currently-selected document every 5 s while the
            // browser is visible. `.task` is cancelled when the view goes
            // off-screen (window closed/hidden), so we don't poll in the
            // background.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                model.refreshSelectedDocument()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search documents — leave empty to browse recent", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query) { _, _ in model.queryChanged() }
                .onSubmit { model.reload() }
            if model.loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var resultsPane: some View {
        if let msg = model.errorMessage, model.results.isEmpty {
            emptyState(icon: "exclamationmark.triangle.fill", title: "Error", detail: msg)
        } else if model.loading {
            emptyState(icon: "hourglass", title: "Searching…", detail: "")
        } else if model.results.isEmpty {
            emptyState(
                icon: "tray",
                title: model.query.isEmpty ? "No documents yet" : "No results",
                detail: model.query.isEmpty
                    ? "Once the app ships some transcripts, they'll appear here."
                    : ""
            )
        } else {
            documentList
        }
    }

    private var documentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { (idx, hit) in
                    documentRowButton(hit)
                        .onAppear {
                            // Trigger the next page as the last few rows scroll
                            // into view. SwiftUI fires onAppear once per row, so
                            // the threshold makes this idempotent.
                            if idx >= model.results.count - 5 {
                                model.loadMore()
                            }
                        }
                    Divider()
                }
                if model.loadingMore {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 12)
                } else if model.atEnd && !model.results.isEmpty {
                    HStack {
                        Spacer()
                        Text("· end ·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func documentRowButton(_ hit: ServerDocumentHit) -> some View {
        Button {
            model.openDocument(hit)
        } label: {
            documentRow(hit)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    model.selectedDocument?.doc_id == hit.doc_id
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                )
        }
        .buttonStyle(.plain)
    }

    private func documentRow(_ hit: ServerDocumentHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(BrowserViewModel.formatRange(hit.started_at, hit.ended_at))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if let s = hit.score {
                    Text(String(format: "%.2f", s))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Text(hit.snippet)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label("\(hit.entry_count)", systemImage: "text.alignleft")
                Label(hit.client_ids.count == 1 ? "1 client" : "\(hit.client_ids.count) clients",
                      systemImage: "person.2.fill")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.loadingDetail {
            emptyState(icon: "hourglass", title: "Loading…", detail: "")
        } else if let doc = model.selectedDocument {
            documentDetail(doc)
        } else {
            emptyState(icon: "sidebar.right", title: "Pick a document", detail: "to see its entries.")
        }
    }

    private func documentDetail(_ doc: ServerDocumentDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(BrowserViewModel.formatRange(doc.started_at, doc.ended_at))
                        .font(.headline)
                    HStack(spacing: 6) {
                        Label("\(doc.entry_count) entries", systemImage: "text.alignleft")
                        Label(doc.client_ids.count == 1 ? "1 client" : "\(doc.client_ids.count) clients",
                              systemImage: "person.2.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.copyDocumentToClipboard(doc)
                } label: {
                    Label(
                        model.copyConfirmation ? "Copied" : "Copy",
                        systemImage: model.copyConfirmation ? "checkmark" : "doc.on.doc"
                    )
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the full document text (no timestamps) — ⇧⌘C")
            }
            .padding([.horizontal, .top], 12)

            Divider().padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(doc.entries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(BrowserViewModel.formatTime(entry.started_at))
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Image(systemName: entry.source == "mic" ? "mic.fill" : "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
