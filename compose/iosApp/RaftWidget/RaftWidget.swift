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
    var kind = "channel"
}

struct Snapshot: Codable {
    var rows: [Row] = []
    var unread = 0
    var mentions = 0
    var signedOut = false

    static let sample = Snapshot(
        rows: [
            Row(title: "#general", preview: "Alice: Shipping it today", time: .now, unread: 2, mention: true),
            Row(title: "Bob", preview: "Bob: Sounds good", time: .now, unread: 1, mention: false, kind: "dm"),
            Row(title: "#design › New icons", preview: "Carol: Updated the set", time: .now, unread: 0, mention: false, kind: "thread"),
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
        let raw = thread ? s("latestActivityPreview") : s("lastMessagePreview")
        // Previews are markdown; show the words.
        let text = (try? AttributedString(markdown: raw)).map { String($0.characters) } ?? raw
        var link = "raft:///s/\(slug)/\(dm ? "dm" : "channel")/\(channel)"
        if thread { link += "?thread=\(channel)%3A\(s("parentMessageId"))" }
        return Row(
            title: title,
            preview: sender.isEmpty ? text : "\(sender): \(text)",
            time: date(thread ? s("lastActivityAt") : s("lastMessageAt")),
            unread: i["unreadCount"] as? Int ?? 0,
            mention: i["hasMention"] as? Bool ?? false,
            url: URL(string: link),
            kind: thread || kind == "task" ? kind : dm ? "dm" : "channel"
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

// MARK: Look: Raft's yellow and ink, outlined like the app's icon tiles.

extension Color {
    static let raftYellow = Color(red: 1, green: 0.831, blue: 0.251)
    static let raftInk = Color(red: 0.078, green: 0.067, blue: 0.067)
}

/// A yellow tile with an ink outline holding [symbol]; plain grey when not [lit].
struct Tile: View {
    var symbol: String
    var size: CGFloat = 26
    var lit = true

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(lit ? Color.raftYellow : Color(.tertiarySystemFill))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(lit ? Color.raftInk : .clear, lineWidth: 1.5))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(lit ? Color.raftInk : Color.secondary))
            .frame(width: size, height: size)
    }
}

/// A count on yellow, outlined: unread messages, or `@` when they mention you.
struct Badge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.raftInk)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(Capsule().fill(Color.raftYellow))
            .overlay(Capsule().strokeBorder(Color.raftInk, lineWidth: 1.2))
    }
}

struct RaftWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: Entry

    var body: some View {
        InboxView(snap: entry.snap, family: family)
            .containerBackground(Color(.systemBackground), for: .widget)
    }
}

struct InboxView: View {
    var snap: Snapshot
    var family: WidgetFamily

    var body: some View {
        if snap.signedOut {
            ConnectView()
        } else if family == .systemSmall {
            small
        } else {
            list(family == .systemLarge ? 8 : 3)
        }
    }

    var header: some View {
        HStack(spacing: 7) {
            Tile(symbol: "bubble.left.and.bubble.right.fill", size: 22)
            Text("Raft").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            if snap.unread > 0 { Badge(text: "\(snap.unread) unread") }
        }
    }

    var small: some View {
        let unread = snap.rows.filter { $0.unread > 0 }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Tile(symbol: "bubble.left.and.bubble.right.fill", size: 22)
                Spacer()
                if snap.mentions > 0 { Badge(text: "@ \(snap.mentions)") }
            }
            Spacer(minLength: 0)
            Text("\(snap.unread)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("unread").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(unread.prefix(2), id: \.self) { Text($0.title).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
            }
            .padding(.top, 6)
        }
        .widgetURL(unread.first?.url ?? URL(string: "raft://"))
    }

    func list(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if snap.rows.isEmpty {
                Spacer()
                Text("No conversations yet").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(snap.rows.prefix(count), id: \.self) { r in
                Link(destination: r.url ?? URL(string: "raft://")!) { row(r) }
            }
            Spacer(minLength: 0)
        }
    }

    func row(_ r: Row) -> some View {
        HStack(spacing: 9) {
            Tile(symbol: symbol(r.kind), size: 28, lit: r.unread > 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 14, weight: r.unread > 0 ? .bold : .medium)).lineLimit(1)
                Text(r.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Calendar.current.isDateInToday(r.time)
                     ? r.time.formatted(date: .omitted, time: .shortened)
                     : r.time.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if r.unread > 0 { Badge(text: r.mention ? "@" : "\(r.unread)") }
            }
        }
        .foregroundStyle(Color.primary)
    }

    func symbol(_ kind: String) -> String {
        switch kind {
        case "dm": "person.fill"
        case "thread": "arrowshape.turn.up.left.fill"
        case "task": "checklist"
        default: "number"
        }
    }
}

struct ConnectView: View {
    var body: some View {
        VStack(spacing: 8) {
            Tile(symbol: "bubble.left.and.bubble.right.fill", size: 36)
            Text("Connect anyRaft").font(.system(size: 15, weight: .bold, design: .rounded))
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
        BriefCard(brief: entry.brief)
            .containerBackground(Color(.systemBackground), for: .widget)
    }
}

/// The brief as a card: a line that is all bold is a heading, `- ` a bullet, the rest text.
struct BriefCard: View {
    var brief: Brief

    var body: some View {
        if brief.signedOut {
            ConnectView()
        } else if brief.missing {
            VStack(spacing: 8) {
                Tile(symbol: "text.page.fill", size: 32, lit: false)
                Text("No conversation named “\(brief.title)”").font(.system(size: 14, weight: .bold))
                Text("Long-press the widget, Edit Widget, and name a channel or an agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Tile(symbol: "sparkles", size: 22)
                    Text(brief.title).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                    Spacer()
                    Text(brief.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 3)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in block(line) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(brief.url)
        }
    }

    var lines: [String] {
        brief.content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder func block(_ line: String) -> some View {
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.raftYellow)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.raftInk, lineWidth: 1))
                    .frame(width: 4, height: 12)
                Text(line.dropFirst(2).dropLast(2)).font(.system(size: 12, weight: .heavy, design: .rounded))
            }
            .padding(.top, 4)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, 9)
        } else {
            inline(line)
        }
    }

    func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
            .font(.system(size: 12.5))
            .lineLimit(2)
            .minimumScaleFactor(0.85)
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
