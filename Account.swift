import SwiftUI
import PhotosUI
import UIKit
import UserNotifications

// MARK: - 账号：数据模型

struct AccountStats: Codable, Equatable {
    var games: Int?
    var wins: Int?
    var losses: Int?
}

struct AccountUser: Codable, Equatable {
    var id: String
    var username: String
    var avatar: String?
    var hasPassword: Bool?
    var barkKey: String?
    var stats: AccountStats?
}

struct MatchDetail: Codable, Equatable {
    var names: [String]
    var controllers: [String]
    var colors: [String]
    var winnerName: String?
}

struct MatchRecord: Codable, Identifiable, Equatable {
    var id: String
    var playedAt: Double          // 毫秒时间戳
    var mode: String              // vsAI / local / online
    var players: Int
    var boardSize: Int
    var aiKey: String?
    var aiLabel: String?
    var moves: Int
    var myMoves: Int
    var result: String            // win / loss / draw / none
    var duration: Int
    var detail: MatchDetail?

    var date: Date { Date(timeIntervalSince1970: playedAt / 1000) }

    var modeText: String {
        switch mode {
        case "vsAI": return "人机"
        case "online": return "联机"
        default: return "本地"
        }
    }

    var resultText: String {
        switch result {
        case "win": return "胜"
        case "loss": return "负"
        case "draw": return "平"
        default: return detail?.winnerName.map { "\($0) 胜" } ?? "—"
        }
    }

    var resultColor: Color {
        switch result {
        case "win": return .green
        case "loss": return .red
        default: return .gray
        }
    }

    var summary: String {
        var parts = ["\(modeText)", "\(players)人", "\(boardSize)×\(boardSize)"]
        if let aiLabel, !aiLabel.isEmpty { parts.append(displayAILabel(aiLabel)) }
        parts.append("\(moves)步")
        return parts.joined(separator: " · ")
    }
}

struct LeaderboardEntry: Codable, Identifiable {
    var rank: Int
    var userId: String
    var username: String
    var avatar: String?
    var games: Int
    var wins: Int?
    var losses: Int?
    var avgMoves: Double
    var bestMoves: Int?
    var id: String { userId }
}

struct LeaderboardLevel: Codable, Identifiable, Hashable {
    var aiKey: String
    var aiLabel: String?
    var games: Int
    var id: String { aiKey }
}

struct LeaderboardBoardSize: Codable, Identifiable, Hashable {
    var boardSize: Int
    var games: Int
    var id: Int { boardSize }
}

struct LeaderboardResponse: Codable {
    var period: String
    var aiKey: String?
    var levels: [LeaderboardLevel]
    var boardSize: Int?
    var boardSizes: [LeaderboardBoardSize]?
    var entries: [LeaderboardEntry]
    var rule: String?
}

struct FriendUser: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var username: String
    var avatar: String?
}

struct FriendsResponse: Codable {
    var friends: [FriendUser]
    var incoming: [FriendUser]
    var outgoing: [FriendUser]
}

struct InviteItem: Codable, Identifiable, Equatable {
    var id: String
    var from: FriendUser
    var roomCode: String
    var boardSize: Int?
    var createdAt: Double
}

struct InviteUpdate: Codable, Identifiable {
    var id: String
    var to: FriendUser
    var status: String
    var roomCode: String
}

struct NotificationsResponse: Codable {
    var invites: [InviteItem]
    var inviteUpdates: [InviteUpdate]
    var friendRequests: [FriendUser]
}

private struct AuthResponse: Codable {
    var token: String
    var user: AccountUser
}

private struct UserResponse: Codable { var user: AccountUser }
private struct MatchesResponse: Codable { var matches: [MatchRecord] }
private struct ErrorResponse: Codable { var error: String }
private struct RespondInviteResponse: Codable { var status: String; var roomCode: String? }

enum LeaderboardPeriod: String, CaseIterable, Identifiable {
    case week, month, season, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: return "周榜"
        case .month: return "月榜"
        case .season: return "季榜"
        case .year: return "年榜"
        }
    }
}

/// 只改显示：Bot 3 强度 4（原 Drive 原版）显示为“困难+”，存储的 aiKey/aiLabel 不变
func displayAILabel(_ label: String) -> String {
    label.replacingOccurrences(of: "Bot 3 · 强度 4", with: "Bot 3 · 困难+")
}

// MARK: - 账号：网络请求

enum AccountAPIError: LocalizedError {
    case server(String)
    case network
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .network: return "网络连接失败，请稍后再试"
        case .unauthorized(let message): return message
        }
    }
}

enum AccountAPI {
    static var baseURL: URL { URL(string: WebSocketNetworkManager.defaultServerURL)! }

    static func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                                   token: String? = nil, as type: T.Type = T.self) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AccountAPIError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountAPIError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                // 只有真正用到联网功能时才会发现登录失效，这时再要求重新登录
                let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ?? "登录已过期，请重新登录"
                if let token { await AccountStore.shared.sessionExpired(token: token, message: message) }
                throw AccountAPIError.unauthorized(message)
            }
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) { throw AccountAPIError.server(err.error) }
            throw AccountAPIError.server("服务器错误 (\(status))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AccountAPIError.server("服务器返回的数据无法解析")
        }
    }
}

private struct EmptyResponse: Codable {}

// MARK: - 账号：Keychain

enum AccountKeychain {
    private static let service = "com.colorwarai.account"
    private static let account = "session"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String?) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(key as CFDictionary)
        guard let token else { return }
        var item = key
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - 账号：状态

/// 从账号页发起的房间操作：加入好友的房间，或者建房并邀请好友。
struct AccountRoomRequest: Equatable {
    enum Kind: Equatable {
        case join(String)
        case hostAndInvite(FriendUser)
    }
    let id = UUID()
    let kind: Kind
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var user: AccountUser? {
        didSet { syncOnlineNickname(old: oldValue) }
    }
    @Published private(set) var token: String?

    /// 登录后联机昵称用账号用户名；退出后恢复登录前手动设置的昵称。
    private static let manualNicknameKey = "CW_Account_ManualNickname"
    private func syncOnlineNickname(old: AccountUser?) {
        let profile = PlayerProfile.shared
        if let name = user?.username, !name.isEmpty {
            if old == nil, UserDefaults.standard.string(forKey: Self.manualNicknameKey) == nil {
                UserDefaults.standard.set(profile.myNickname, forKey: Self.manualNicknameKey)
            }
            if profile.myNickname != name { profile.myNickname = name }
        } else if old != nil {
            if let manual = UserDefaults.standard.string(forKey: Self.manualNicknameKey), !manual.isEmpty {
                profile.myNickname = manual
            }
            UserDefaults.standard.removeObject(forKey: Self.manualNicknameKey)
        }
    }
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published private(set) var history: [MatchRecord] = []
    @Published private(set) var friends = FriendsResponse(friends: [], incoming: [], outgoing: [])
    @Published private(set) var friendRequests: [FriendUser] = []
    @Published var incomingInvite: InviteItem?
    @Published var roomRequest: AccountRoomRequest?

    private var pollTask: Task<Void, Never>?
    private var seenInviteIDs = Set<String>()
    private var seenUpdateIDs = Set<String>()
    private var seenFriendRequestIDs = Set<String>()
    private let pendingKey = "CW_Account_PendingMatches"
    private let localHistoryKey = "CW_Local_MatchHistory"
    /// 上次登录成功时的账号信息，打开 App 时直接用它恢复登录状态，不联网
    private let cachedUserKey = "CW_Account_CachedUser"

    var isLoggedIn: Bool { user != nil && token != nil }

    private init() {
        history = loadLocalHistory()
        if let saved = AccountKeychain.load() {
            token = saved
            if let data = UserDefaults.standard.data(forKey: cachedUserKey),
               let cached = try? JSONDecoder().decode(AccountUser.self, from: data) {
                // 默认保持登录：不请求 /api/me，等真正联网操作时再校验
                user = cached
                startPolling()
                Task { await self.uploadPendingMatches() }
            } else {
                // 旧版本升级上来还没有缓存，只校验这一次
                Task { await self.refreshMe() }
            }
        }
    }

    private func cacheUser() {
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: cachedUserKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cachedUserKey)
        }
    }

    /// 服务器返回 401：清掉登录状态，但保留还没上传的战绩，重新登录后会补传。
    func sessionExpired(token expired: String, message: String) {
        guard token == expired else { return }
        clearSession()
        errorMessage = message
    }

    // 登录 / 注册 / 退出

    func login(username: String, password: String) async {
        await authenticate(path: "/api/login", body: ["username": username, "password": password])
    }

    func register(username: String, password: String, confirmPassword: String) async {
        guard password == confirmPassword else {
            errorMessage = "两次输入的密码不一致"
            return
        }
        await authenticate(path: "/api/register",
                           body: ["username": username, "password": password, "confirmPassword": confirmPassword])
    }

    private func authenticate(path: String, body: [String: Any]) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response: AuthResponse = try await AccountAPI.send("POST", path, body: body)
            token = response.token
            AccountKeychain.save(response.token)
            user = response.user
            cacheUser()
            didLogin()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAccount(password: String) async throws {
        let _: EmptyResponse = try await AccountAPI.send("POST", "/api/me/delete", body: ["password": password], token: token)
        logout()
    }

    func logout() {
        let oldToken = token
        Task { let _: EmptyResponse? = try? await AccountAPI.send("POST", "/api/logout", token: oldToken) }
        clearSession()
    }

    private func clearSession() {
        pollTask?.cancel()
        pollTask = nil
        token = nil
        user = nil
        friends = FriendsResponse(friends: [], incoming: [], outgoing: [])
        friendRequests = []
        incomingInvite = nil
        history = loadLocalHistory()
        AccountKeychain.save(nil)
        UserDefaults.standard.removeObject(forKey: cachedUserKey)
    }

    private func didLogin() {
        LocalNotifier.requestAuthorization()
        startPolling()
        Task {
            await uploadPendingMatches()
            await refreshHistory()
            await refreshFriends()
        }
    }

    func refreshMe() async {
        guard let token else { return }
        do {
            let firstCheck = user == nil
            let response: UserResponse = try await AccountAPI.send("GET", "/api/me", token: token)
            user = response.user
            cacheUser()
            if firstCheck { didLogin() }
        } catch {
            // 401 已在 AccountAPI 里处理；网络问题保持本地登录状态
        }
    }

    func updateProfile(username: String? = nil, avatar: String? = nil, barkKey: String? = nil) async -> Bool {
        guard let token else { return false }
        var body: [String: Any] = [:]
        if let username { body["username"] = username }
        if let avatar { body["avatar"] = avatar }
        if let barkKey { body["barkKey"] = barkKey }
        isBusy = true
        defer { isBusy = false }
        do {
            let response: UserResponse = try await AccountAPI.send("PATCH", "/api/me", body: body, token: token)
            user = response.user
            cacheUser()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // 战绩

    func submit(_ record: MatchRecord) {
        var local = loadLocalHistory()
        local.removeAll { $0.id == record.id }
        local.insert(record, at: 0)
        saveLocalHistory(Array(local.prefix(500)))
        var pending = loadPending()
        pending.append(record)
        savePending(pending)
        if isLoggedIn {
            history.removeAll { $0.id == record.id }
            history.insert(record, at: 0)
            Task { await uploadPendingMatches() }
        } else {
            history = local
        }
    }

    func uploadPendingMatches() async {
        guard let token else { return }
        let pending = loadPending()
        guard !pending.isEmpty else { return }
        let payload = pending.compactMap { record -> [String: Any]? in
            guard let data = try? JSONEncoder().encode(record),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object
        }
        do {
            let _: [String: Int] = try await AccountAPI.send("POST", "/api/matches", body: ["matches": payload], token: token)
            let uploaded = Set(pending.map(\.id))
            savePending(loadPending().filter { !uploaded.contains($0.id) })
        } catch {}
    }

    func refreshHistory() async {
        guard let token else { history = loadLocalHistory(); return }
        do {
            let response: MatchesResponse = try await AccountAPI.send("GET", "/api/matches?limit=200", token: token)
            let serverIDs = Set(response.matches.map(\.id))
            let unsent = loadPending().filter { !serverIDs.contains($0.id) }
            history = (unsent + response.matches).sorted { $0.playedAt > $1.playedAt }
        } catch {
            if history.isEmpty { history = loadLocalHistory() }
        }
    }

    private func loadPending() -> [MatchRecord] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([MatchRecord].self, from: data)) ?? []
    }

    private func savePending(_ records: [MatchRecord]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: pendingKey)
    }

    private func loadLocalHistory() -> [MatchRecord] {
        guard let data = UserDefaults.standard.data(forKey: localHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([MatchRecord].self, from: data)) ?? []
    }

    private func saveLocalHistory(_ records: [MatchRecord]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: localHistoryKey)
    }

    // 排行榜

    func leaderboard(period: LeaderboardPeriod, aiKey: String?, boardSize: Int? = nil, limit: Int) async throws -> LeaderboardResponse {
        var path = "/api/leaderboard?period=\(period.rawValue)&limit=\(limit)"
        if let aiKey, let encoded = aiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&aiKey=\(encoded)"
        }
        if let boardSize { path += "&boardSize=\(boardSize)" }
        return try await AccountAPI.send("GET", path)
    }

    // 好友

    func refreshFriends() async {
        guard let token else { return }
        if let response: FriendsResponse = try? await AccountAPI.send("GET", "/api/friends", token: token) {
            friends = response
            friendRequests = response.incoming
        }
    }

    func addFriend(username: String) async {
        guard let token else { return }
        do {
            let response: [String: AnyCodableValue] = try await AccountAPI.send("POST", "/api/friends/request",
                                                                                 body: ["username": username], token: token)
            toast = response["status"]?.stringValue == "accepted" ? "你们已经是好友了" : "好友申请已发送"
            await refreshFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondFriend(_ friend: FriendUser, accept: Bool) async {
        guard let token else { return }
        do {
            let _: [String: String] = try await AccountAPI.send("POST", "/api/friends/respond",
                                                                body: ["userId": friend.id, "accept": accept], token: token)
            await refreshFriends()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFriend(_ friend: FriendUser) async {
        guard let token else { return }
        let _: [String: Bool]? = try? await AccountAPI.send("DELETE", "/api/friends/\(friend.id)", token: token)
        await refreshFriends()
    }

    // 邀请

    func requestHostAndInvite(_ friend: FriendUser) {
        roomRequest = AccountRoomRequest(kind: .hostAndInvite(friend))
    }

    func sendInvite(to friend: FriendUser, roomCode: String, boardSize: Int) async {
        guard let token else { return }
        do {
            let _: [String: String] = try await AccountAPI.send("POST", "/api/invites",
                                                                body: ["friendId": friend.id, "roomCode": roomCode, "boardSize": boardSize],
                                                                token: token)
            toast = "已邀请 \(friend.username) 加入房间 \(roomCode)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondInvite(_ invite: InviteItem, accept: Bool) async {
        incomingInvite = nil
        guard let token else { return }
        do {
            let response: RespondInviteResponse = try await AccountAPI.send("POST", "/api/invites/\(invite.id)/respond",
                                                                           body: ["accept": accept], token: token)
            if accept { roomRequest = AccountRoomRequest(kind: .join(response.roomCode ?? invite.roomCode)) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // 轮询通知（App 在前台时每 20 秒一次）

    /// 对局进行中（任何模式）暂停通知轮询；对局结束或离开对局后立刻补一次（顺带补传战绩）。
    var gameActive = false {
        didSet {
            if oldValue && !gameActive, isLoggedIn, UIApplication.shared.applicationState == .active {
                Task { await pollOnce() }
            }
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // 只在前台轮询；切到后台/锁屏时跳过，回到前台由 scenePhase 立刻补一次
                if UIApplication.shared.applicationState == .active, self?.gameActive == false { await self?.pollOnce() }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func pollOnce() async {
        guard let token else { return }
        guard let response: NotificationsResponse = try? await AccountAPI.send("GET", "/api/notifications", token: token) else { return }
        // 网络恢复后顺便补传离线时下的对局
        if !loadPending().isEmpty { await uploadPendingMatches() }
        for invite in response.invites where !seenInviteIDs.contains(invite.id) {
            seenInviteIDs.insert(invite.id)
            incomingInvite = invite
            LocalNotifier.post(id: invite.id, title: "对局邀请",
                               body: "\(invite.from.username) 邀请你加入房间 \(invite.roomCode)")
        }
        for update in response.inviteUpdates where !seenUpdateIDs.contains(update.id) {
            seenUpdateIDs.insert(update.id)
            toast = update.status == "accepted" ? "\(update.to.username) 接受了邀请" : "\(update.to.username) 拒绝了邀请"
        }
        let newRequests = response.friendRequests.filter { !seenFriendRequestIDs.contains($0.id) }
        for request in newRequests {
            seenFriendRequestIDs.insert(request.id)
            LocalNotifier.post(id: "friend-\(request.id)", title: "好友申请", body: "\(request.username) 想加你为好友")
        }
        if friendRequests.map(\.id) != response.friendRequests.map(\.id) {
            friendRequests = response.friendRequests
            await refreshFriends()
        }
    }

    // 推送令牌（只有用付费开发者证书签名的版本才能拿到 APNs 令牌）

    func uploadPushToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "CW_APNs_Token")
        guard let token else { return }
        Task { let _: [String: Bool]? = try? await AccountAPI.send("POST", "/api/push-token",
                                                                    body: ["token": hex, "platform": "ios"], token: token) }
    }
}

/// 用来解析 {"status": "...", "user": {...}} 这种混合 JSON。
enum AnyCodableValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: AnyCodableValue]), array([AnyCodableValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyCodableValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AnyCodableValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
}

// MARK: - 本地通知

enum LocalNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class AccountAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in AccountStore.shared.uploadPushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // 侧载（免费签名）版本没有 aps-environment 权限，这里失败是正常的；邀请改用 App 内轮询 + 本地通知。
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 对局记录与本地复盘

struct ReplayMove: Codable, Equatable {
    var row: Int
    var column: Int
    var player: Int
}

struct MatchReplay: Codable, Identifiable, Equatable {
    var id: String              // 与 MatchRecord.id 相同
    var playedAt: Double
    var title: String
    var boardSize: Int
    var names: [String]
    var colors: [String]
    var frames: [String]        // 每一步后的棋盘，每格 2 位十六进制：(owner+1)*16 + count
    var moves: [ReplayMove]
    var isSaved: Bool
    var emojis: [String?]? = nil  // 表情棋子（旧复盘没有这个字段）

    static func encode(_ board: [[Cell]]) -> String {
        var out = ""
        out.reserveCapacity(board.count * board.count * 2)
        for row in board {
            for cell in row {
                let value = cell.owner.map { ($0 + 1) * 16 + min(cell.count, 15) } ?? 0
                out += String(format: "%02X", min(value, 255))
            }
        }
        return out
    }

    /// 对局里实际下过棋的两个座位（按座位号排序）；第一个当红方，第二个当蓝方。
    var duelSeats: [Int] {
        var seats = Set(moves.map(\.player))
        if let first = frames.first {
            for r in 0..<boardSize { for c in 0..<boardSize { if let o = cellValue(first, r, c).owner { seats.insert(o) } } }
        }
        return seats.sorted()
    }

    /// 分析器只分析双人局（棋盘 5–12）。
    var isAnalyzerImportable: Bool {
        (5...12).contains(boardSize) && !moves.isEmpty && frames.count == moves.count + 1 && duelSeats.count == 2
    }

    private func cellValue(_ encoded: String, _ row: Int, _ column: Int) -> (owner: Int?, count: Int) {
        let chars = Array(encoded.utf8)
        let index = (row * boardSize + column) * 2
        guard index + 1 < chars.count,
              let value = Int(String(bytes: chars[index...index + 1], encoding: .utf8) ?? "", radix: 16),
              value > 0 else { return (nil, 0) }
        return (value / 16 - 1, value % 16)
    }

    func cell(frame: Int, row: Int, column: Int) -> (owner: Int?, count: Int) {
        guard frames.indices.contains(frame) else { return (nil, 0) }
        let chars = Array(frames[frame].utf8)
        let index = (row * boardSize + column) * 2
        guard index + 1 < chars.count,
              let value = Int(String(bytes: chars[index...index + 1], encoding: .utf8) ?? "", radix: 16),
              value > 0 else { return (nil, 0) }
        return (value / 16 - 1, value % 16)
    }
}

@MainActor
final class MatchRecorder: ObservableObject {
    static let shared = MatchRecorder()

    @Published private(set) var replays: [MatchReplay] = []
    /// 复盘页点“导入分析器”时设置，开始菜单收到后切到分析器并载入这一局。
    @Published var analyzerImportID: String?

    private var current: MatchReplay?
    private var startedAt = Date()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ColorWarReplays.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([MatchReplay].self, from: data) {
            replays = saved
        }
    }

    /// 新一局开始（GameModel.resetGame 末尾调用）。
    func begin(_ game: GameModel) {
        startedAt = Date()
        let colors = game.colors.map { String($0.toHex().dropFirst().prefix(6)) }
        current = MatchReplay(id: UUID().uuidString, playedAt: Date().timeIntervalSince1970 * 1000, title: "",
                              boardSize: game.boardSize, names: game.playerNames, colors: colors,
                              frames: [MatchReplay.encode(game.board)], moves: [], isSaved: false,
                              emojis: game.emojis)
    }

    /// 一步（含连锁）结算完成后调用。
    func recordMove(_ game: GameModel, row: Int, column: Int, player: Int) {
        guard current != nil, game.board.count == current?.boardSize else { return }
        current?.moves.append(ReplayMove(row: row, column: column, player: player))
        current?.frames.append(MatchReplay.encode(game.board))
    }

    /// 对局分出胜负时调用。
    func finish(_ game: GameModel) {
        guard var replay = current else { return }
        current = nil
        let active = game.activePlayerIndices
        let types = game.playerTypes
        let humans = active.filter { types[safe: $0] == .human }
        let ais = active.filter { types[safe: $0]?.isAI == true }
        let isOnline = game.gameMode == .online
        let winner = game.winnerIndex
        let winnerName = winner.flatMap { game.playerNames[safe: $0] }

        var mode = "local"
        var mySeat: Int? = humans.count == 1 ? humans.first : nil
        var aiKey: String?
        var aiLabel: String?
        if isOnline {
            mode = "online"
            mySeat = WebSocketNetworkManager.shared.playerIndex
        } else if active.count == 2 && humans.count == 1 && ais.count == 1, let aiSeat = ais.first, let aiType = types[safe: aiSeat] {
            mode = "vsAI"
            switch aiType {
            case .driveBot:
                if game.duelBotStrength == DuelBeginnerBot.strength {
                    aiKey = DuelBeginnerBot.aiKey      // 入门单独一个榜
                    aiLabel = DuelBeginnerBot.aiLabel
                } else {
                    aiKey = "bot3-s\(game.duelBotStrength)"
                    aiLabel = "Bot 3 · 强度 \(game.duelBotStrength)"
                }
            case .enhancedNightmare:
                aiKey = "bot2-l\(game.aiDifficultyLevel.rawValue)"
                aiLabel = "Bot 2 · \(game.aiDifficultyLevel.rawValue)档"
            default:
                aiKey = "bot1-l\(game.aiDifficultyLevel.rawValue)"
                aiLabel = "Bot 1 · \(game.aiDifficultyLevel.rawValue)档"
            }
        }

        var result = "none"
        if let mySeat, let winner { result = winner == mySeat ? "win" : "loss" }
        let myMoves = mySeat.map { seat in replay.moves.filter { $0.player == seat }.count } ?? 0

        let detail = MatchDetail(names: active.map { game.playerNames[safe: $0] ?? "玩家" },
                                 controllers: active.map { types[safe: $0]?.displayName ?? "" },
                                 colors: active.map { replay.colors[safe: $0] ?? "808080" },
                                 winnerName: winnerName)
        let record = MatchRecord(id: replay.id, playedAt: replay.playedAt, mode: mode, players: active.count,
                                 boardSize: replay.boardSize, aiKey: aiKey, aiLabel: aiLabel,
                                 moves: replay.moves.count, myMoves: myMoves, result: result,
                                 duration: Int(Date().timeIntervalSince(startedAt)), detail: detail)

        replay.title = "\(record.resultText) · \(record.summary)"
        replays.insert(replay, at: 0)
        trimAndSave()
        AccountStore.shared.submit(record)
    }

    func replay(for id: String) -> MatchReplay? {
        replays.first { $0.id == id }
    }

    /// 最近 5 局（未收藏）可以复盘；收藏的复盘会一直保留。
    var recentReplayIDs: Set<String> {
        Set(replays.filter { !$0.isSaved }.prefix(5).map(\.id))
    }

    func toggleSaved(_ id: String) {
        guard let index = replays.firstIndex(where: { $0.id == id }) else { return }
        replays[index].isSaved.toggle()
        trimAndSave()
    }

    func delete(_ id: String) {
        replays.removeAll { $0.id == id }
        trimAndSave()
    }

    private func trimAndSave() {
        var unsavedKept = 0
        replays = replays.filter { replay in
            if replay.isSaved { return true }
            unsavedKept += 1
            return unsavedKept <= 5
        }
        if let data = try? JSONEncoder().encode(replays) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - 头像

struct AvatarView: View {
    let avatar: String?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            if let image = decodedImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let (emoji, color) = emojiAvatar {
                Circle().fill(color)
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Circle().fill(Color.darkNavyBlue)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
    }

    private var decodedImage: UIImage? {
        guard let avatar, avatar.hasPrefix("data:image"),
              let comma = avatar.firstIndex(of: ","),
              let data = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    private var emojiAvatar: (String, Color)? {
        guard let avatar, avatar.hasPrefix("emoji:") else { return nil }
        let parts = avatar.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[1], Color(hex: parts[2]))
    }
}

// MARK: - 玻璃卡片

private struct AccountGlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
    }
}

private enum AccountRoute: Hashable {
    case profile, history, leaderboard, friends
    case replay(String)
}

// MARK: - 第 4 个标签页

struct AccountTabView: View {
    @ObservedObject var store = AccountStore.shared
    @ObservedObject var recorder = MatchRecorder.shared
    let background: AnyView
    @State private var path: [AccountRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isLoggedIn {
                    loggedInHome
                } else {
                    AccountAuthView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: AccountRoute.self) { route in
                destination(route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: AccountRoute) -> some View {
                switch route {
                case .profile: ProfileEditView()
                case .history: MatchHistoryView(path: $path)
                case .leaderboard: LeaderboardFullView()
                case .friends: FriendsView()
                case .replay(let id): ReplayView(replayID: id)
                }
    }

    private var loggedInHome: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Button { path.append(.profile) } label: { ProfileCard() }.buttonStyle(.plain)
                Button { path.append(.history) } label: { HistoryPreviewCard(path: $path) }.buttonStyle(.plain)
                Button { path.append(.leaderboard) } label: { LeaderboardPreviewCard() }.buttonStyle(.plain)
                Button { path.append(.friends) } label: { FriendsPreviewCard() }.buttonStyle(.plain)
                DeleteAccountCard()
                TipCard()
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(minHeight: proxy.size.height)
        }
        }
        .refreshable {
            await store.refreshMe()
            await store.refreshHistory()
            await store.refreshFriends()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { store.logout() } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.white)
                }
            }
        }
        .task { await store.refreshHistory() }
    }
}

// MARK: 登录 / 注册

private struct AccountAuthView: View {
    @ObservedObject var store = AccountStore.shared
    @State private var isRegister = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    private var canSubmit: Bool {
        username.trimmingCharacters(in: .whitespaces).count >= 2 && password.count >= 6
            && (!isRegister || !confirmPassword.isEmpty) && !store.isBusy
    }

    var body: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Text("COLOR WAR")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 30)
                AccountGlassCard {
                    Picker("", selection: $isRegister) {
                        Text("登录").tag(false)
                        Text("注册").tag(true)
                    }
                    .pickerStyle(.segmented)

                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField(isRegister ? "密码（至少 6 位）" : "密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(isRegister ? .newPassword : .password)
                    if isRegister {
                        SecureField("再次输入密码", text: $confirmPassword)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                        if !confirmPassword.isEmpty && confirmPassword != password {
                            Text("两次输入的密码不一致").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let error = store.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        Task {
                            if isRegister {
                                await store.register(username: username, password: password, confirmPassword: confirmPassword)
                            } else {
                                await store.login(username: username, password: password)
                            }
                        }
                    } label: {
                        Group {
                            if store.isBusy { ProgressView().tint(.white) } else { Text(isRegister ? "注册" : "登录").bold() }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                        .glassEffect(.regular.tint(canSubmit ? .darkNavyBlue : .gray).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                }
                Text("登录后可以同步战绩、上排行榜、加好友和邀请好友联机。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 440)
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(minHeight: proxy.size.height)
        }
        }
        .onChange(of: isRegister) { _, _ in store.errorMessage = nil }
    }
}

// MARK: 卡片 1：头像和用户名

private struct ProfileCard: View {
    @ObservedObject var store = AccountStore.shared
    var body: some View {
        AccountGlassCard {
            HStack(spacing: 14) {
                AvatarView(avatar: store.user?.avatar, name: store.user?.username ?? "", size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.user?.username ?? "")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    let stats = store.user?.stats
                    Text("\(stats?.games ?? 0) 局 · \(stats?.wins ?? 0) 胜 \(stats?.losses ?? 0) 负")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct ProfileEditView: View {
    @ObservedObject var store = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var emoji = "🙂"
    @State private var emojiColor = Color(hex: "#1E5BB8")
    @State private var photoItem: PhotosPickerItem?
    @State private var photoAvatar: String?
    @State private var useEmoji = false
    @State private var barkKey = ""

    private let emojiChoices = ["🙂", "😎", "🐯", "🐼", "🦊", "🐸", "🐙", "🦄", "🔥", "⚡️", "🌈", "🎯", "🎻", "🚀", "👾", "🍀"]

    private var previewAvatar: String? {
        if useEmoji { return "emoji:\(emoji):\(Self.avatarHex(emojiColor))" }
        return photoAvatar ?? store.user?.avatar
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AccountGlassCard {
                    HStack {
                        Spacer()
                        AvatarView(avatar: previewAvatar, name: username, size: 96)
                        Spacer()
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册选择头像", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Capsule())
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Text("或者用表情头像").font(.caption).foregroundStyle(.white.opacity(0.7))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                        ForEach(emojiChoices, id: \.self) { item in
                            Button {
                                emoji = item
                                useEmoji = true
                            } label: {
                                Text(item).font(.title2)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(useEmoji && emoji == item ? Color.white.opacity(0.25) : .clear))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ColorPicker("表情头像底色", selection: Binding(get: { emojiColor }, set: { emojiColor = $0; useEmoji = true }),
                                supportsOpacity: false)
                        .foregroundStyle(.white)
                }
                AccountGlassCard {
                    Text("用户名").font(.caption).foregroundStyle(.white.opacity(0.7))
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                AccountGlassCard {
                    Text("Bark 推送（可选）").font(.caption).foregroundStyle(.white.opacity(0.7))
                    TextField("Bark Key（App Store 的 Bark App 里复制）", text: $barkKey)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("填了以后，App 没打开时也能通过 Bark 收到好友邀请。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Button {
                    Task {
                        let changedName = username.trimmingCharacters(in: .whitespaces) != store.user?.username
                        let newAvatar = useEmoji ? previewAvatar : photoAvatar
                        let newBark = barkKey != (store.user?.barkKey ?? "") ? barkKey : nil
                        if await store.updateProfile(username: changedName ? username : nil, avatar: newAvatar, barkKey: newBark) {
                            dismiss()
                        }
                    }
                } label: {
                    Text("保存").bold().foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .contentShape(Capsule())
                        .glassEffect(.regular.tint(.darkNavyBlue).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(store.isBusy)
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("个人资料")
        .onAppear {
            store.errorMessage = nil
            username = store.user?.username ?? ""
            barkKey = store.user?.barkKey ?? ""
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let encoded = Self.encodeAvatar(image) else { return }
                photoAvatar = encoded
                useEmoji = false
            }
        }
    }

    /// 表情头像底色转成 #RRGGBB。ColorPicker 可能给出 Display P3 的颜色，分量会超出 0...1，
    /// 先夹到合法范围，否则服务器会拒绝这个头像。
    static func avatarHex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// 裁成 160×160 的 JPEG，控制在服务器的大小限制内。
    static func encodeAvatar(_ image: UIImage) -> String? {
        let side: CGFloat = 160
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let resized = renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.75) else { return nil }
        return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }
}

// MARK: 卡片 2：战绩

private struct HistoryPreviewCard: View {
    @ObservedObject var store = AccountStore.shared
    @Binding var path: [AccountRoute]

    var body: some View {
        AccountGlassCard {
            HStack {
                Label("最近战绩", systemImage: "clock.arrow.circlepath").font(.headline).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            let recent = Array(store.history.prefix(5))
            if recent.isEmpty {
                Text("还没有对局记录。打完一局就会出现在这里。")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            } else {
                HStack(spacing: 10) {
                    ForEach(recent) { match in
                        Text(match.resultText.count == 1 ? match.resultText : "—")
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(match.resultColor.opacity(0.75)))
                    }
                }
                if let last = recent.first {
                    Text("上一局：\(last.summary)")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

private struct MatchHistoryView: View {
    @ObservedObject var store = AccountStore.shared
    @ObservedObject var recorder = MatchRecorder.shared
    @Binding var path: [AccountRoute]

    var body: some View {
        List {
            let savedOnly = recorder.replays.filter { replay in replay.isSaved && !store.history.contains(where: { $0.id == replay.id }) }
            if !savedOnly.isEmpty {
                Section("已保存的复盘") {
                    ForEach(savedOnly) { replay in
                        Button { path.append(.replay(replay.id)) } label: {
                            Label(replay.title, systemImage: "play.rectangle.fill")
                        }
                    }
                }
            }
            Section {
                ForEach(store.history) { match in
                    let hasReplay = recorder.replay(for: match.id) != nil
                    Button {
                        if hasReplay { path.append(.replay(match.id)) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(match.resultText)
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(match.resultColor.opacity(0.75)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.summary).font(.subheadline).foregroundStyle(.primary)
                                Text(match.date.formatted(date: .abbreviated, time: .shortened)
                                     + (match.detail.map { " · " + $0.names.joined(separator: " vs ") } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if hasReplay {
                                Image(systemName: "play.circle.fill").foregroundStyle(.cyan)
                            }
                        }
                    }
                    .disabled(!hasReplay)
                }
            } header: {
                Text("全部对局（\(store.history.count)）")
            } footer: {
                Text("最近 5 局和你保存的对局可以复盘，复盘只存在这台设备上。")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("战绩")
        .refreshable { await store.refreshHistory() }
        .task { await store.refreshHistory() }
    }
}

private struct ReplayView: View {
    let replayID: String
    @ObservedObject var recorder = MatchRecorder.shared
    @State private var frame = 0

    var body: some View {
        if let replay = recorder.replay(for: replayID) {
            VStack(spacing: 16) {
                Text(replay.title).font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                ReplayBoard(replay: replay, frame: frame)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 520)
                if frame > 0, let move = replay.moves[safe: frame - 1] {
                    Text("第 \(frame) 步：\(replay.names[safe: move.player] ?? "玩家") 下在 (\(move.row + 1), \(move.column + 1))")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("开局").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
                Slider(value: Binding(get: { Double(frame) }, set: { frame = Int($0.rounded()) }),
                       in: 0...Double(max(replay.frames.count - 1, 1)), step: 1)
                    .frame(maxWidth: 520)
                HStack(spacing: 14) {
                    replayButton("backward.end.fill") { frame = 0 }
                    replayButton("chevron.left") { frame = max(0, frame - 1) }
                    Text("\(frame)/\(replay.frames.count - 1)")
                        .font(.headline.monospacedDigit()).foregroundStyle(.white).frame(minWidth: 70)
                    replayButton("chevron.right") { frame = min(replay.frames.count - 1, frame + 1) }
                    replayButton("forward.end.fill") { frame = replay.frames.count - 1 }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("复盘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recorder.analyzerImportID = replay.id } label: {
                        Label("导入分析器", systemImage: "sparkle.magnifyingglass")
                    }
                    .disabled(!replay.isAnalyzerImportable)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recorder.toggleSaved(replay.id) } label: {
                        Label(replay.isSaved ? "已保存" : "保存", systemImage: replay.isSaved ? "bookmark.fill" : "bookmark")
                    }
                }
            }
        } else {
            Text("这局的复盘已经不在本机了").foregroundStyle(.white.opacity(0.7))
        }
    }

    private func replayButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

private struct ReplayBoard: View {
    let replay: MatchReplay
    let frame: Int

    // 与对局棋盘 BoardView / 分析器棋盘相同的间距、边框和玻璃底板，格子直接复用 CellView。
    private let gap: CGFloat = 3
    private let border: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let n = max(replay.boardSize, 1)
            let maxSide = min(proxy.size.width, proxy.size.height)
            let side = max(0, (maxSide - border * 2 - gap * CGFloat(n - 1)) / CGFloat(n))
            let boardDimension = side * CGFloat(n) + gap * CGFloat(n - 1) + border * 2
            let lastMove = frame > 0 ? replay.moves[safe: frame - 1] : nil
            VStack(spacing: gap) {
                ForEach(0..<n, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<n, id: \.self) { c in
                            let raw = replay.cell(frame: frame, row: r, column: c)
                            let cell = Cell(owner: raw.count > 0 ? raw.owner : nil, count: raw.count)
                            CellView(
                                cell: cell,
                                color: cell.owner.flatMap { replay.colors[safe: $0] }.map { Color(hex: $0) },
                                emoji: cell.owner.flatMap { replay.emojis?[safe: $0] ?? nil },
                                active: false
                            )
                            .equatable()
                            .frame(width: side, height: side)
                            .overlay {
                                // 只在复盘里用方框标出这一步下的格子
                                if lastMove?.row == r && lastMove?.column == c {
                                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                                        .stroke(Color.white.opacity(0.45), lineWidth: 2)
                                        .padding(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(border)
            .glassEffect(.regular, in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
            .frame(width: boardDimension, height: boardDimension)
            .allowsHitTesting(false)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: 卡片 3：排行榜

private struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(entry.rank <= 3 ? .yellow : .white)
                .frame(width: 30)
            AvatarView(avatar: entry.avatar, name: entry.username, size: 30)
            Text(entry.username).foregroundStyle(.white).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.wins ?? 0) 胜 · 平均 \(String(format: "%.1f", entry.avgMoves)) 步")
                    .font(.caption.bold()).foregroundStyle(.white)
                Text("\(entry.games) 局").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// 排行榜默认周期：没手动选过周期时，周榜没人就自动看月榜，再空就季榜、年榜。
/// 手动选了周期就只查那个周期（空也照样显示）。
@MainActor
func loadLeaderboardWithFallback(store: AccountStore, period: LeaderboardPeriod, isAuto: Bool,
                                 aiKey: String?, boardSize: Int?, limit: Int) async throws -> (LeaderboardPeriod, LeaderboardResponse) {
    guard isAuto else {
        return (period, try await store.leaderboard(period: period, aiKey: aiKey, boardSize: boardSize, limit: limit))
    }
    var first: LeaderboardResponse?
    for candidate in LeaderboardPeriod.allCases {
        let response = try await store.leaderboard(period: candidate, aiKey: aiKey, boardSize: boardSize, limit: limit)
        if first == nil { first = response }
        if !response.entries.isEmpty { return (candidate, response) }
    }
    return (.week, first!)
}

/// 手动选周期：之后不再自动切换，棋盘大小回到该周期的默认（和以前一样）。
private func manualPeriodBinding(_ period: Binding<LeaderboardPeriod>, isAuto: Binding<Bool>, boardSize: Binding<Int?>) -> Binding<LeaderboardPeriod> {
    Binding(get: { period.wrappedValue }, set: { value in
        guard value != period.wrappedValue else { return }
        isAuto.wrappedValue = false
        boardSize.wrappedValue = nil
        period.wrappedValue = value
    })
}

private struct LeaderboardControls: View {
    @Binding var period: LeaderboardPeriod
    @Binding var aiKey: String?
    @Binding var boardSize: Int?
    let levels: [LeaderboardLevel]
    let boardSizes: [LeaderboardBoardSize]

    var body: some View {
        Picker("", selection: $period) {
            ForEach(LeaderboardPeriod.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if !levels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(levels) { level in
                        Button { aiKey = level.aiKey; boardSize = nil } label: {
                            Text(displayAILabel(level.aiLabel ?? level.aiKey))
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Capsule())
                                .glassEffect(.regular.tint(aiKey == level.aiKey ? .darkNavyBlue : .clear).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !boardSizes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(boardSizes) { size in
                        Button { boardSize = size.boardSize } label: {
                            Text("\(size.boardSize)×\(size.boardSize)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Capsule())
                                .glassEffect(.regular.tint(boardSize == size.boardSize ? .darkNavyBlue : .clear).interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct LeaderboardPreviewCard: View {
    @ObservedObject var store = AccountStore.shared
    @State private var period: LeaderboardPeriod = .week
    @State private var isAutoPeriod = true
    @State private var aiKey: String?
    @State private var boardSize: Int?
    @State private var data: LeaderboardResponse?
    @State private var error: String?

    var body: some View {
        AccountGlassCard {
            HStack {
                Label("排行榜", systemImage: "trophy.fill").font(.headline).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            LeaderboardControls(period: manualPeriodBinding($period, isAuto: $isAutoPeriod, boardSize: $boardSize), aiKey: $aiKey, boardSize: $boardSize, levels: data?.levels ?? [], boardSizes: data?.boardSizes ?? [])
            if let entries = data?.entries, !entries.isEmpty {
                ForEach(entries.prefix(5)) { LeaderboardRow(entry: $0) }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else {
                Text(data == nil ? "加载中…" : "这段时间还没有人上榜（和 AI 打满 3 局即可上榜）")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .task(id: "\(period.rawValue)-\(aiKey ?? "")-\(boardSize ?? 0)") { await load() }
    }

    private func load() async {
        do {
            let (shown, response) = try await loadLeaderboardWithFallback(store: store, period: period, isAuto: isAutoPeriod,
                                                                           aiKey: aiKey, boardSize: boardSize, limit: 5)
            if shown != period { period = shown }
            data = response
            if aiKey == nil { aiKey = response.aiKey }
                if boardSize == nil { boardSize = response.boardSize }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct LeaderboardFullView: View {
    @ObservedObject var store = AccountStore.shared
    @State private var period: LeaderboardPeriod = .week
    @State private var isAutoPeriod = true
    @State private var aiKey: String?
    @State private var boardSize: Int?
    @State private var data: LeaderboardResponse?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AccountGlassCard {
                    LeaderboardControls(period: manualPeriodBinding($period, isAuto: $isAutoPeriod, boardSize: $boardSize), aiKey: $aiKey, boardSize: $boardSize, levels: data?.levels ?? [], boardSizes: data?.boardSizes ?? [])
                    if let rule = data?.rule {
                        Text(rule).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                AccountGlassCard {
                    if let entries = data?.entries, !entries.isEmpty {
                        ForEach(entries) { entry in
                            LeaderboardRow(entry: entry)
                            if entry.id != entries.last?.id { Divider().overlay(.white.opacity(0.15)) }
                        }
                    } else if let error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(data == nil ? "加载中…" : "还没有人上榜").foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("排行榜 · 前 100 名")
        .task(id: "\(period.rawValue)-\(aiKey ?? "")-\(boardSize ?? 0)") {
            do {
                let (shown, response) = try await loadLeaderboardWithFallback(store: store, period: period, isAuto: isAutoPeriod,
                                                                               aiKey: aiKey, boardSize: boardSize, limit: 100)
                if shown != period { period = shown }
                data = response
                if aiKey == nil { aiKey = response.aiKey }
                if boardSize == nil { boardSize = response.boardSize }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: 卡片 4：好友

private struct FriendsPreviewCard: View {
    @ObservedObject var store = AccountStore.shared
    var body: some View {
        AccountGlassCard {
            HStack {
                Label("好友", systemImage: "person.2.fill").font(.headline).foregroundStyle(.white)
                if !store.friendRequests.isEmpty {
                    Text("\(store.friendRequests.count)")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            if store.friends.friends.isEmpty {
                Text("加好友后可以直接邀请对方联机。").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            } else {
                HStack(spacing: -8) {
                    ForEach(store.friends.friends.prefix(8)) { AvatarView(avatar: $0.avatar, name: $0.username, size: 32) }
                }
                Text("\(store.friends.friends.count) 位好友").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct FriendsView: View {
    @ObservedObject var store = AccountStore.shared
    @State private var newFriend = ""
    @State private var recordFriend: FriendUser?

    var body: some View {
        List {
            Section("添加好友") {
                HStack {
                    TextField("输入对方的用户名", text: $newFriend)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("发送申请") {
                        let name = newFriend
                        newFriend = ""
                        Task { await store.addFriend(username: name) }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.darkNavyBlue)
                    .disabled(newFriend.trimmingCharacters(in: .whitespaces).count < 2)
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            if !store.friends.incoming.isEmpty {
                Section("好友申请") {
                    ForEach(store.friends.incoming) { user in
                        HStack {
                            AvatarView(avatar: user.avatar, name: user.username, size: 32)
                            Text(user.username)
                            Spacer()
                            Button("接受") { Task { await store.respondFriend(user, accept: true) } }
                                .buttonStyle(.glassProminent)
                                .tint(.darkNavyBlue)
                            Button("拒绝") { Task { await store.respondFriend(user, accept: false) } }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            Section("我的好友") {
                if store.friends.friends.isEmpty {
                    Text("还没有好友").foregroundStyle(.secondary)
                }
                ForEach(store.friends.friends) { user in
                    HStack {
                        Button { recordFriend = user } label: {
                            HStack {
                                AvatarView(avatar: user.avatar, name: user.username, size: 32)
                                Text(user.username).foregroundStyle(.primary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button {
                            store.requestHostAndInvite(user)
                        } label: {
                            Label("邀请联机", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.darkNavyBlue)
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await store.removeFriend(user) } } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            if !store.friends.outgoing.isEmpty {
                Section("等待对方同意") {
                    ForEach(store.friends.outgoing) { user in
                        HStack {
                            AvatarView(avatar: user.avatar, name: user.username, size: 28)
                            Text(user.username).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("好友")
        .navigationDestination(item: $recordFriend) { FriendRecordView(friend: $0) }
        .refreshable { await store.refreshFriends() }
        .task {
            store.errorMessage = nil
            await store.refreshFriends()
        }
    }
}

// MARK: - 邀请横幅和提示（盖在所有标签页上面）

struct AccountOverlay: View {
    @ObservedObject var store = AccountStore.shared

    var body: some View {
        VStack(spacing: 8) {
            if let invite = store.incomingInvite {
                HStack(spacing: 12) {
                    AvatarView(avatar: invite.from.avatar, name: invite.from.username, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(invite.from.username) 邀请你联机").font(.subheadline.bold()).foregroundStyle(.white)
                        Text("房间 \(invite.roomCode)").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Button("加入") { Task { await store.respondInvite(invite, accept: true) } }
                        .buttonStyle(.glassProminent)
                        .tint(.darkNavyBlue)
                    Button("拒绝") { Task { await store.respondInvite(invite, accept: false) } }
                        .buttonStyle(.glass)
                }
                .padding(12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: PlayerPreset.cardCornerRadius))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let toast = store.toast {
                Text(toast)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if store.toast == toast { store.toast = nil }
                    }
            }
            Spacer()
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.incomingInvite)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.toast)
    }
}


// MARK: 打赏（微信收款码）
// 换图：把 Resources/wechat-pay.png 替换成你的微信收款码（文件名不变）。
private struct TipCard: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            AccountGlassCard {
                HStack {
                    Label("打赏作者", systemImage: "heart.fill").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                }
                Text("喜欢 Color War 的话，可以用微信扫码请作者喝杯奶茶。")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { TipSheet() }
    }
}

private struct TipSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var image: UIImage? {
        // 不用 Bundle.module：资源包没打进 IPA 时它会直接 fatalError 闪退。手动找，找不到就显示提示。
        if let data = Data(base64Encoded: WeChatPayImage.base64), let image = UIImage(data: data) { return image }
        if let url = Bundle.main.url(forResource: "wechat-pay", withExtension: "png") { return UIImage(contentsOfFile: url.path) }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)) ?? []
        for dir in bundles where dir.pathExtension == "bundle" {
            if let url = Bundle(url: dir)?.url(forResource: "wechat-pay", withExtension: "png") { return UIImage(contentsOfFile: url.path) }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text("收款码还没放进来").foregroundStyle(.secondary)
                }
                Text("微信扫一扫，或截图后在微信里识别").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle("微信收款码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}


// MARK: 好友近一个月战绩
struct FriendMatchStats: Codable { var games: Int; var wins: Int; var losses: Int }
struct FriendMatchesResponse: Codable {
    var user: FriendUser
    var stats: FriendMatchStats
    var matches: [MatchRecord]
}

private struct FriendRecordView: View {
    let friend: FriendUser
    @State private var data: FriendMatchesResponse?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AvatarView(avatar: friend.avatar, name: friend.username, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(friend.username).font(.headline)
                        if let st = data?.stats {
                            Text("\(st.games) 局 · \(st.wins) 胜 \(st.losses) 负").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("近一个月") {
                if let error {
                    Text(error).foregroundStyle(.orange)
                } else if let matches = data?.matches {
                    if matches.isEmpty { Text("近一个月没有对局").foregroundStyle(.secondary) }
                    ForEach(matches) { m in
                        HStack(spacing: 10) {
                            Text(m.resultText).font(.subheadline.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .background(m.resultColor, in: Capsule())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.summary)
                                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("加载中…").foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("\(friend.username) 的战绩")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let id = friend.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? friend.id
            data = try await AccountAPI.send("GET", "/api/friends/\(id)/matches", token: AccountStore.shared.token)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}


// MARK: 注销账号
private struct DeleteAccountCard: View {
    @ObservedObject var store = AccountStore.shared
    @State private var showWarning = false
    @State private var showPassword = false
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 6) {
            Button(role: .destructive) { showWarning = true } label: {
                Label("注销账号", systemImage: "person.crop.circle.badge.xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.red)
            .disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .alert("注销账号？", isPresented: $showWarning) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { password = ""; showPassword = true }
        } message: {
            Text("注销后会永久删除你的账号、全部战绩、好友和邀请，也会从排行榜上移除。别人战绩里你的名字会显示为“已注销用户”。此操作无法撤销。")
        }
        .alert("输入密码确认", isPresented: $showPassword) {
            SecureField("密码", text: $password)
            Button("取消", role: .cancel) {}
            Button("永久注销", role: .destructive) {
                let pw = password
                Task {
                    busy = true
                    do { try await store.deleteAccount(password: pw); error = nil }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        }
    }
}
