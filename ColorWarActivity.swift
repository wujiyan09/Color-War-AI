import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct ColorWarActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// One compact base-36 digit per board cell; `0` is empty, others encode owner * 4 + count.
        var boardRows: [String]
        var boardSize: Int
        var currentPlayer: Int
        var currentPlayerName: String
        var colors: [String]
        var isMyTurn: Bool
        var status: String
    }

    var roomCode: String
    var seatIndex: Int
}
