import AppIntents
import SwiftUI
import WidgetKit

/// Self-build (runzhou-tao 2026-11-09): the Today-view widget. It has its own sign-in (the app's
/// refresh token rotates, so the two cannot share one), which the app leaves in the shared keychain
/// when the signed-out widget is tapped (`raft://widget/connect`, RaftWidgetConnect in the app).
private let api = "https://api.raft.build/api/"

enum WidgetTokens {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "raft.widget",
        kSecAttrAccount as String: "session",
        kSecAttrAccessGroup as String: "76682Q85WA.dev.vgent.raft.shared",
    ]

    static func load() -> [String: String]? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: d)
    }

    static func save(_ tokens: [String: String]?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let d = try? JSONEncoder().encode(tokens) else { return }
        var q = query
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct SignedOut: Error {}

struct Row: Codable, Hashable {
    var title: String
    var preview: String
    var time: Date
    var unread: Int
    var mention: Bool
    var url: URL?
}

struct Snapshot: Codable {
    var rows: [Row] = []
    var unread = 0
    var mentions = 0
    var signedOut = false

    static let sample = Snapshot(
        rows: [
            Row(title: "#general", preview: "Alice: Shipping it today", time: .now, unread: 2, mention: true),
            Row(title: "Bob", preview: "Bob: Sounds good", time: .now, unread: 1, mention: false),
            Row(title: "#design › New icons", preview: "Carol: Updated the set", time: .now, unread: 0, mention: false),
        ],
        unread: 3,
        mentions: 1
    )
}

enum Raft {
    static func request(_ path: String, body: [String: String]? = nil, token: String? = nil, server: String? = nil) async throws -> (Any, Int) {
        var r = URLRequest(url: URL(string: api + path)!)
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let server { r.setValue(server, forHTTPHeaderField: "X-Server-Id") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        return ((try? JSONSerialization.jsonObject(with: d)) ?? [:], (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The stored access token, refreshed when it has less than a minute left (it lives 15 minutes).
    static func accessToken() async throws -> String {
        guard let tokens = WidgetTokens.load(), let refresh = tokens["refreshToken"] else { throw SignedOut() }
        if let access = tokens["accessToken"], expiry(access) > Date().addingTimeInterval(60) { return access }
        let (j, status) = try await request("auth/refresh", body: ["refreshToken": refresh])
        if (400..<500).contains(status), status != 429 {
            WidgetTokens.save(nil)
            throw SignedOut()
        }
        guard let j = j as? [String: Any], let a = j["accessToken"] as? String, let r = j["refreshToken"] as? String else {
            throw URLError(.badServerResponse)
        }
        WidgetTokens.save(["accessToken": a, "refreshToken": r])
        return a
    }

    static func expiry(_ jwt: String) -> Date {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return .distantPast }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        guard let d = Data(base64Encoded: b), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = j["exp"] as? Double else { return .distantPast }
        return Date(timeIntervalSince1970: exp)
    }

    /// The newest conversations across all the servers.
    /// The signed-in person's servers as (id, slug).
    static func servers(_ token: String) async throws -> [(String, String)] {
        let (s, status) = try await request("servers", token: token)
        if status == 401 { throw SignedOut() }
        return (s as? [[String: Any]] ?? []).compactMap { sv -> (String, String)? in
            guard let id = sv["id"] as? String, let slug = sv["slug"] as? String else { return nil }
            return (id, slug)
        }
    }

    static func snapshot() async throws -> Snapshot {
        let token = try await TokenGate.shared.token()
        let servers = try await Self.servers(token)
        var rows: [Row] = []
        var unread = 0
        await withTaskGroup(of: ([Row], Int).self) { group in
            for (id, slug) in servers { group.addTask { await inbox(id: id, slug: slug, token: token) } }
            for await (r, n) in group {
                rows += r
                unread += n
            }
        }
        rows.sort { $0.time > $1.time }
        return Snapshot(rows: Array(rows.prefix(8)), unread: unread, mentions: rows.filter { $0.mention && $0.unread > 0 }.count)
    }

    /// The newest message of the channel or DM named [name] (`#` and `@` optional), on any server.
    static func brief(_ name: String) async throws -> Brief {
        let token = try await TokenGate.shared.token()
        let want = name.trimmingCharacters(in: CharacterSet(charactersIn: "#@ ")).lowercased()
        for (id, slug) in try await servers(token) {
            guard let r = try? await request("channels/inbox?filter=all&limit=50", token: token, server: id),
                  let items = (r.0 as? [String: Any])?["items"] as? [[String: Any]],
                  let item = items.first(where: { ($0["kind"] as? String) != "thread" && ($0["channelName"] as? String)?.lowercased() == want }),
                  let channel = item["channelId"] as? String else { continue }
            let (m, _) = try await request("messages/channel/\(channel)?limit=5", token: token, server: id)
            let messages = (m as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            guard let newest = messages.max(by: { ($0["createdAt"] as? String ?? "") < ($1["createdAt"] as? String ?? "") }) else { continue }
            let dm = (item["kind"] as? String) == "dm" || (item["channelType"] as? String) == "dm"
            return Brief(
                title: dm ? item["channelName"] as? String ?? name : "#\(item["channelName"] as? String ?? name)",
                sender: newest["senderName"] as? String ?? "",
                time: date(newest["createdAt"] as? String ?? ""),
                content: newest["content"] as? String ?? "",
                url: URL(string: "raft:///s/\(slug)/\(dm ? "dm" : "channel")/\(channel)")
            )
        }
        return Brief(title: name, missing: true)
    }

    static func inbox(id: String, slug: String, token: String) async -> ([Row], Int) {
        guard let r = try? await request("channels/inbox?filter=all&limit=8", token: token, server: id),
              let j = r.0 as? [String: Any] else { return ([], 0) }
        let rows = (j["items"] as? [[String: Any]] ?? []).compactMap { row($0, slug: slug) }
        return (rows, j["totalUnreadCount"] as? Int ?? rows.reduce(0) { $0 + $1.unread })
    }

    static func row(_ i: [String: Any], slug: String) -> Row? {
        func s(_ k: String) -> String { i[k] as? String ?? "" }
        let kind = s("kind")
        let thread = kind == "thread"
        let channel = thread ? s("parentChannelId") : s("channelId")
        guard !channel.isEmpty, kind != "object" else { return nil }
        let dm = kind == "dm" || (thread ? s("parentChannelType") : s("channelType")) == "dm"
        let name = thread ? s("parentChannelName") : s("channelName")
        var title = dm ? name : "#\(name)"
        if thread { title += " › " + s("parentMessagePreview") }
        if kind == "task", let n = i["taskNumber"] as? Int { title = "task #\(n) \(s("taskTitle"))" }
        let sender = thread ? s("latestActivitySenderName") : s("lastMessageSenderName")
        let text = thread ? s("latestActivityPreview") : s("lastMessagePreview")
        var link = "raft:///s/\(slug)/\(dm ? "dm" : "channel")/\(channel)"
        if thread { link += "?thread=\(channel)%3A\(s("parentMessageId"))" }
        return Row(
            title: title,
            preview: sender.isEmpty ? text : "\(sender): \(text)",
            time: date(thread ? s("lastActivityAt") : s("lastMessageAt")),
            unread: i["unreadCount"] as? Int ?? 0,
            mention: i["hasMention"] as? Bool ?? false,
            url: URL(string: link)
        )
    }

    static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? .distantPast
    }
}

/// One token refresh at a time: the refresh token rotates, so two widgets on screen must not both
/// spend it.
actor TokenGate {
    static let shared = TokenGate()
    private var running: Task<String, Error>?

    func token() async throws -> String {
        if let running { return try await running.value }
        let task = Task { try await Raft.accessToken() }
        running = task
        defer { running = nil }
        return try await task.value
    }
}

/// [load]'s result, or when the network fails the last good one saved under [key].
func cached<T: Codable>(_ key: String, signedOut: T, _ load: () async throws -> T) async -> T? {
    do {
        let v = try await load()
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
        return v
    } catch is SignedOut {
        return signedOut
    } catch {
        return UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snap: Snapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snap: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(Entry(date: .now, snap: await load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        Task {
            let entry = Entry(date: .now, snap: await load())
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    func load() async -> Snapshot {
        await cached("snapshot", signedOut: Snapshot(signedOut: true)) { try await Raft.snapshot() } ?? Snapshot()
    }
}

struct RaftWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: Entry

    var body: some View {
        Group {
            if entry.snap.signedOut {
                ConnectView()
            } else if family == .systemSmall {
                small
            } else {
                list(family == .systemLarge ? 7 : 3)
            }
        }
        .containerBackground(Color(.systemBackground), for: .widget)
    }

    var small: some View {
        let first = entry.snap.rows.first { $0.unread > 0 }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Raft").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(entry.snap.unread)").font(.system(size: 40, weight: .semibold)).minimumScaleFactor(0.5)
            Text(entry.snap.mentions > 0 ? "unread · \(entry.snap.mentions) @you" : "unread").font(.caption)
            if let first {
                Text(first.title).font(.caption2.weight(.semibold)).lineLimit(1).padding(.top, 4)
                Text(first.preview).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(first?.url ?? URL(string: "raft://"))
    }

    func list(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raft").font(.subheadline.weight(.semibold))
                Spacer()
                if entry.snap.unread > 0 {
                    Text("\(entry.snap.unread) unread").font(.caption).foregroundStyle(.secondary)
                }
            }
            if entry.snap.rows.isEmpty {
                Spacer()
                Text("No conversations yet").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(entry.snap.rows.prefix(count), id: \.self) { r in
                Link(destination: r.url ?? URL(string: "raft://")!) { row(r) }
            }
            Spacer(minLength: 0)
        }
    }

    func row(_ r: Row) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.subheadline.weight(r.unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text(r.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Calendar.current.isDateInToday(r.time)
                     ? r.time.formatted(date: .omitted, time: .shortened)
                     : r.time.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2).foregroundStyle(.secondary)
                if r.unread > 0 {
                    Text(r.mention ? "@" : "\(r.unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.primary))
                }
            }
        }
    }
}

struct ConnectView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right").font(.title2)
            Text("Connect anyRaft").font(.headline)
            Text("Tap to sign in the widget").font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .widgetURL(URL(string: "raft://widget/connect"))
    }
}

struct RaftWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RaftInbox", provider: Provider()) { RaftWidgetView(entry: $0) }
            .configurationDisplayName("Raft")
            .description("Your latest conversations.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: Brief (runzhou-tao 2026-11-09): a daily brief or dashboard an agent writes into a conversation.

struct Brief: Codable {
    var title: String
    var sender = ""
    var time = Date.distantPast
    var content = ""
    var url: URL?
    var missing = false
    var signedOut = false
}

struct BriefSource: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Brief"
    static var description = IntentDescription("The newest message of a channel, or of your DM with an agent.")
    @Parameter(title: "Channel or agent", default: "brief") var source: String
}

struct BriefEntry: TimelineEntry {
    var date: Date
    var brief: Brief
}

struct BriefProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BriefEntry {
        BriefEntry(date: .now, brief: Brief(title: "#brief", sender: "Brief", time: .now,
                                            content: "**Today**\n3 tasks in review, 2 mentions waiting.\n\n**Highlights**\nShipped the widget."))
    }

    func snapshot(for configuration: BriefSource, in context: Context) async -> BriefEntry {
        context.isPreview ? placeholder(in: context) : BriefEntry(date: .now, brief: await load(configuration.source))
    }

    func timeline(for configuration: BriefSource, in context: Context) async -> Timeline<BriefEntry> {
        Timeline(entries: [BriefEntry(date: .now, brief: await load(configuration.source))],
                 policy: .after(.now.addingTimeInterval(15 * 60)))
    }

    func load(_ source: String) async -> Brief {
        await cached("brief:\(source)", signedOut: Brief(title: source, signedOut: true)) { try await Raft.brief(source) }
            ?? Brief(title: source, missing: true)
    }
}

struct BriefView: View {
    var entry: BriefEntry

    var body: some View {
        let b = entry.brief
        Group {
            if b.signedOut {
                ConnectView()
            } else if b.missing {
                VStack(spacing: 6) {
                    Text("No conversation named “\(b.title)”").font(.subheadline.weight(.semibold))
                    Text("Long-press the widget, Edit Widget, and name a channel or an agent.").font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(b.title).font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(b.sender) · \(b.time.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text((try? AttributedString(markdown: b.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(b.content))
                        .font(.footnote)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(b.url)
            }
        }
        .containerBackground(Color(.systemBackground), for: .widget)
    }
}

struct RaftBriefWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RaftBrief", intent: BriefSource.self, provider: BriefProvider()) { BriefView(entry: $0) }
            .configurationDisplayName("Raft Brief")
            .description("A daily brief or dashboard an agent writes into a channel or DM.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct RaftWidgets: WidgetBundle {
    var body: some Widget {
        RaftWidget()
        RaftBriefWidget()
    }
}
