import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct ColorWarLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ColorWarActivityAttributes.self) { context in
            VStack(spacing: 8) {
                HStack {
                    Text(context.state.status).font(.headline)
                    Spacer()
                    Text("房间 \(context.attributes.roomCode)").font(.caption).foregroundStyle(.secondary)
                }
                ActivityBoard(state: context.state, maxHeight: 220)
                Text("当前：\(context.state.currentPlayerName)")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Color War").font(.caption.bold()).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isMyTurn ? "你的回合" : "对手回合")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 5) {
                        ActivityBoard(state: context.state, maxHeight: 78)
                        Text("\(context.state.currentPlayerName) · 房间 \(context.attributes.roomCode)")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Text("CW").font(.caption2.bold())
            } compactTrailing: {
                Text(context.state.isMyTurn ? "轮到你" : "对手")
                    .font(.caption2).lineLimit(1)
            } minimal: {
                Text(context.state.isMyTurn ? "CW" : "·")
                    .font(.caption2.bold())
            }
            .keylineTint(.cyan)
        }
    }
}

@available(iOS 16.1, *)
private struct ActivityBoard: View {
    let state: ColorWarActivityAttributes.ContentState
    let maxHeight: CGFloat

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 1), count: max(1, state.boardSize))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, maxHeight)
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(0..<(state.boardSize * state.boardSize), id: \.self) { index in
                    let row = index / max(1, state.boardSize)
                    let col = index % max(1, state.boardSize)
                    let value = cellValue(row: row, col: col)
                    ZStack {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(cellColor(value))
                        if value > 0 {
                            Text("\((value - 1) % 4 + 1)")
                                .font(.system(size: max(4, 31 / CGFloat(max(1, state.boardSize))), weight: .bold))
                                .minimumScaleFactor(0.4)
                                .foregroundStyle(.white)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: maxHeight)
        .accessibilityLabel("当前棋盘")
    }

    private func cellValue(row: Int, col: Int) -> Int {
        guard row < state.boardRows.count else { return 0 }
        let chars = Array(state.boardRows[row])
        guard col < chars.count else { return 0 }
        return Int(String(chars[col]), radix: 36) ?? 0
    }

    private func cellColor(_ value: Int) -> Color {
        guard value > 0 else { return Color.white.opacity(0.08) }
        let owner = (value - 1) / 4
        guard owner < state.colors.count else { return .gray }
        let hex = state.colors[owner].trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let number = UInt64(hex, radix: 16) else { return .gray }
        let hasAlpha = hex.count == 8 // SwiftUI's Color.toHex uses RRGGBBAA.
        let redShift = hasAlpha ? 24 : 16
        let greenShift = hasAlpha ? 16 : 8
        let blueShift = hasAlpha ? 8 : 0
        return Color(.sRGB,
                     red: Double((number >> redShift) & 0xff) / 255,
                     green: Double((number >> greenShift) & 0xff) / 255,
                     blue: Double((number >> blueShift) & 0xff) / 255,
                     opacity: 1)
    }
}

@available(iOS 16.1, *)
@main
struct ColorWarWidgetBundle: WidgetBundle {
    var body: some Widget {
        ColorWarLiveActivity()
    }
}
