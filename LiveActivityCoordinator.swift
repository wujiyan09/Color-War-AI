import ActivityKit
import Foundation

@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var pushTokens: [String: String] = [:]
    private var isStarting = false

    private init() {}

    func sync(roomCode: String, seat: Int, state: ColorWarActivityAttributes.ContentState) {
        guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled,
              !roomCode.isEmpty else { return }

        let existing = Activity<ColorWarActivityAttributes>.activities.first {
            $0.attributes.roomCode == roomCode && $0.attributes.seatIndex == seat
        }
        if let activity = existing {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(2 * 60 * 60)))
            }
            observeToken(for: activity)
            return
        }
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            do {
                let attributes = ColorWarActivityAttributes(roomCode: roomCode, seatIndex: seat)
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(2 * 60 * 60)),
                    pushType: .token
                )
                observeToken(for: activity)
            } catch {
                // Live Activities may be disabled by the user or unavailable on this device.
            }
        }
    }

    func end(roomCode: String) {
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<ColorWarActivityAttributes>.activities where activity.attributes.roomCode == roomCode {
            tokenTasks[activity.id]?.cancel()
            tokenTasks[activity.id] = nil
            pushTokens[activity.id] = nil
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func resendTokenIfAvailable() {
        guard #available(iOS 16.1, *) else { return }
        let roomCode = WebSocketNetworkManager.shared.currentRoomCode
        let seat = WebSocketNetworkManager.shared.playerIndex
        guard let activity = Activity<ColorWarActivityAttributes>.activities.first(where: {
            $0.attributes.roomCode == roomCode && $0.attributes.seatIndex == seat
        }), let token = pushTokens[activity.id] else { return }
        send(token, roomCode: activity.attributes.roomCode)
    }

    @available(iOS 16.1, *)
    private func observeToken(for activity: Activity<ColorWarActivityAttributes>) {
        guard tokenTasks[activity.id] == nil else { return }
        if let data = activity.pushToken {
            let token = data.map { String(format: "%02x", $0) }.joined()
            pushTokens[activity.id] = token
            send(token, roomCode: activity.attributes.roomCode)
        }
        tokenTasks[activity.id] = Task {
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                pushTokens[activity.id] = token
                send(token, roomCode: activity.attributes.roomCode)
            }
        }
    }

    private func send(_ token: String, roomCode: String) {
        guard WebSocketNetworkManager.shared.isConnected,
              WebSocketNetworkManager.shared.currentRoomCode == roomCode else { return }
        WebSocketNetworkManager.shared.sendActivityPushToken(token)
    }
}
