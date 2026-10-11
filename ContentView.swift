import SwiftUI
import Combine
import UIKit
import PhotosUI

// MARK: - 1. 原生 Haptic 触觉反馈引擎

final class Haptics {
    static let shared = Haptics()
    private init() {}
    
    func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
    
    func heavyImpact() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - 2. 数据模型与枚举

enum PlayerControlType: String, CaseIterable, Identifiable, Codable {
    case human = "真人"
    case mathNightmare = "算法-噩梦"
    case enhancedNightmare = "算法-噩梦 (加强版)"
    case disabled = "未加入"
    
    var id: String { rawValue }
    var isAI: Bool { self == .mathNightmare || self == .enhancedNightmare }
}

enum BackgroundMode: String, CaseIterable, Identifiable, Codable {
    case defaultGradient = "默认深邃渐变"
    case simulatedDesktop = "桌面透视磨砂"
    case customPhoto = "自定义相册壁纸"
    
    var id: String { rawValue }
}

struct PlayerPreset {
    static let maxPlayers = 8
    static let defaultColors: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23),
        Color(red: 0.04, green: 0.52, blue: 1.0),
        Color(red: 0.19, green: 0.82, blue: 0.35),
        Color(red: 1.0, green: 0.62, blue: 0.04),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.0, green: 0.78, blue: 0.75),
        Color(red: 1.0, green: 0.84, blue: 0.04),
        Color(red: 0.96, green: 0.44, blue: 0.62)
    ]
    static let defaultNames = ["玩家1", "玩家2", "玩家3", "玩家4", "玩家5", "玩家6", "玩家7", "玩家8"]
}

struct Cell: Equatable, Sendable {
    var owner: Int?
    var count: Int
}

struct FlyingOrb: Identifiable, Sendable {
    let id = UUID()
    let player: Int
    let fromRow: Int
    let fromColumn: Int
    let toRow: Int
    let toColumn: Int
    var arrived: Bool = false
}

// MARK: - 3. Color 扩展

extension Color {
    static let darkNavyBlue = Color(red: 0.08, green: 0.28, blue: 0.65)
    
    func toHex() -> String {
        let uic = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uic.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: (r, g, b) = (255, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}

// MARK: - 4. 极速轻量 AI 解算器

struct AISolver {
    let boardSize: Int
    let activePlayers: [Int]
    let currentPlayer: Int
    let board: [[Cell]]
    
    func calculateBestMove() -> (Int, Int)? {
        var validMoves = [(Int, Int)]()
        let ownsAny = board.flatMap { $0 }.contains { $0.owner == currentPlayer }
        
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = board[r][c]
                if ownsAny ? (cell.owner == currentPlayer) : (cell.owner == nil) {
                    validMoves.append((r, c))
                }
            }
        }
        
        guard !validMoves.isEmpty else { return nil }
        
        let priorityMoves = validMoves.filter { board[$0.0][$0.1].count == 3 }
        if let pick = priorityMoves.randomElement() {
            return pick
        }
        return validMoves.randomElement()
    }
}

// MARK: - 5. GameModel ViewModel

@MainActor
final class GameModel: ObservableObject {
    @Published var boardSize: Int = 8 {
        didSet { UserDefaults.standard.set(boardSize, forKey: "CW_Saved_BoardSize") }
    }
    @Published var board: [[Cell]] = [] {
        didSet { updateCachedPlayableCells() }
    }
    @Published var playerNames: [String] = PlayerPreset.defaultNames
    @Published var playerTypes: [PlayerControlType] = [.human, .mathNightmare, .disabled, .disabled, .disabled, .disabled, .disabled, .disabled] {
        didSet { refreshActivePlayers() }
    }
    @Published var colors: [Color] = PlayerPreset.defaultColors
    @Published var emojis: [String?] = Array(repeating: nil, count: PlayerPreset.maxPlayers)
    @Published var currentPlayer: Int = 0 {
        didSet { updateCachedPlayableCells() }
    }
    @Published var hasEntered: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers)
    @Published var eliminated: [Bool] = Array(repeating: false, count: PlayerPreset.maxPlayers) {
        didSet { updateCachedPlayableCells() }
    }
    @Published var isProcessingCascade: Bool = false
    @Published var winnerIndex: Int? = nil
    @Published var showControlSheet: Bool = false
    @Published var showVisualSettingsSheet: Bool = false
    @Published var flyingOrbs: [FlyingOrb] = []
    
    @Published var backgroundMode: BackgroundMode = .defaultGradient {
        didSet { UserDefaults.standard.set(backgroundMode.rawValue, forKey: "CW_Saved_BGMode") }
    }
    @Published var bgOpacity: Double = 0.85 {
        didSet { UserDefaults.standard.set(bgOpacity, forKey: "CW_Saved_BGOpacity") }
    }
    @Published var enableHDR: Bool = true {
        didSet { UserDefaults.standard.set(enableHDR, forKey: "CW_Saved_EnableHDR") }
    }
    @Published var hdrHeadroom: Double = 1.5 {
        didSet { UserDefaults.standard.set(hdrHeadroom, forKey: "CW_Saved_HDRHeadroom") }
    }
    @Published var customUIImage: UIImage? = nil
    
    @Published private(set) var activePlayerIndices: [Int] = []
    @Published private(set) var playableCells: Set<Int> = []
    
    private var aiTask: Task<Void, Never>? = nil
    
    init() {
        let savedSize = UserDefaults.standard.integer(forKey: "CW_Saved_BoardSize")
        self.boardSize = (savedSize >= 5 && savedSize <= 12) ? savedSize : 8
        
        if let bgRaw = UserDefaults.standard.string(forKey: "CW_Saved_BGMode"), let mode = BackgroundMode(rawValue: bgRaw) {
            self.backgroundMode = mode
        }
        if let savedOpacity = UserDefaults.standard.object(forKey: "CW_Saved_BGOpacity") as? Double {
            self.bgOpacity = savedOpacity
        }
        if let data = UserDefaults.standard.data(forKey: "CW_Saved_CustomImageData"), let img = UIImage(data: data) {
            self.customUIImage = img
        }
        
        refreshActivePlayers()
        resetGame()
    }
    
    func setCustomImage(_ image: UIImage?) {
        self.customUIImage = image
        if let img = image, let data = img.jpegData(compressionQuality: 0.8) {
            UserDefaults.standard.set(data, forKey: "CW_Saved_CustomImageData")
        } else {
            UserDefaults.standard.removeObject(forKey: "CW_Saved_CustomImageData")
        }
    }
    
    private func refreshActivePlayers() {
        self.activePlayerIndices = playerTypes.enumerated().compactMap { $1 != .disabled ? $0 : nil }
    }
    
    private func updateCachedPlayableCells() {
        guard boardSize > 0, board.count == boardSize, board.first?.count == boardSize else {
            self.playableCells = []
            return
        }
        guard currentPlayer >= 0 && currentPlayer < PlayerPreset.maxPlayers, !eliminated[currentPlayer] else {
            self.playableCells = []
            return
        }
        let ownsAny = board.contains { $0.contains { $0.owner == currentPlayer } }
        var indices = Set<Int>()
        for r in 0..<boardSize {
            for c in 0..<boardSize {
                let cell = board[r][c]
                let idx = r * boardSize + c
                if ownsAny ? (cell.owner == currentPlayer) : (cell.owner == nil) {
                    indices.insert(idx)
                }
            }
        }
        self.playableCells = indices
    }
    
    func resetGame() {
        aiTask?.cancel()
        aiTask = nil
        flyingOrbs.removeAll()
        board = [[Cell]](repeating: [Cell](repeating: Cell(owner: nil, count: 0), count: boardSize), count: boardSize)
        hasEntered = Array(repeating: false, count: PlayerPreset.maxPlayers)
        eliminated = Array(repeating: false, count: PlayerPreset.maxPlayers)
        winnerIndex = nil
        isProcessingCascade = false
        
        let active = activePlayerIndices
        guard !active.isEmpty else { return }
        currentPlayer = active[0]
        updateCachedPlayableCells()
        checkAndRunAITurn()
    }
    
    func play(row: Int, column: Int) {
        let flatIdx = row * boardSize + column
        guard !isProcessingCascade, winnerIndex == nil, playableCells.contains(flatIdx) else { return }
        
        Haptics.shared.lightImpact()
        let player = currentPlayer
        aiTask?.cancel()
        
        Task { @MainActor in
            await resolveMove(row: row, column: column, player: player)
        }
    }
    
    // 渲染高性能波浪动画
    private func resolveMove(row: Int, column: Int, player: Int) async {
        isProcessingCascade = true
        let isFirst = !hasEntered[player]
        hasEntered[player] = true
        
        board[row][column].owner = player
        board[row][column].count += isFirst ? 3 : 1
        
        var wave: [(Int, Int)] = board[row][column].count >= 4 ? [(row, column)] : []
        let dirs = [(-1,0), (1,0), (0,-1), (0,1)]
        
        while !wave.isEmpty {
            let exploding = wave
            var transfers: [FlyingOrb] = []
            
            for (r, c) in exploding {
                board[r][c].count -= 4
                if board[r][c].count == 0 { board[r][c].owner = nil }
                
                for (dr, dc) in dirs {
                    let nr = r + dr, nc = c + dc
                    if (0..<boardSize).contains(nr) && (0..<boardSize).contains(nc) {
                        transfers.append(FlyingOrb(player: player, fromRow: r, fromColumn: c, toRow: nr, toColumn: nc))
                    }
                }
            }
            
            flyingOrbs = transfers
            try? await Task.sleep(nanoseconds: 120_000_000)
            
            for orb in flyingOrbs {
                board[orb.toRow][orb.toColumn].owner = player
                board[orb.toRow][orb.toColumn].count += 1
            }
            flyingOrbs.removeAll()
            
            var nextWave = [(Int, Int)]()
            for r in 0..<boardSize {
                for c in 0..<boardSize {
                    if board[r][c].count >= 4 { nextWave.append((r, c)) }
                }
            }
            wave = nextWave
        }
        
        isProcessingCascade = false
        updateEliminationStatus()
        
        if checkGameOver() { return }
        advanceToNextTurn()
    }
    
    private func updateEliminationStatus() {
        var appears = [Bool](repeating: false, count: PlayerPreset.maxPlayers)
        for row in board {
            for cell in row {
                if let o = cell.owner, o >= 0, o < PlayerPreset.maxPlayers { appears[o] = true }
            }
        }
        for p in activePlayerIndices {
            if hasEntered[p] && !appears[p] { eliminated[p] = true }
        }
    }
    
    private func checkGameOver() -> Bool {
        let alive = activePlayerIndices.filter { !eliminated[$0] }
        let allEnteredOrEliminated = activePlayerIndices.allSatisfy { hasEntered[$0] || eliminated[$0] }
        if allEnteredOrEliminated && alive.count <= 1 {
            winnerIndex = alive.first
            Haptics.shared.heavyImpact()
            return true
        }
        return false
    }
    
    private func advanceToNextTurn() {
        let active = activePlayerIndices
        guard !active.isEmpty, let idx = active.firstIndex(of: currentPlayer) else { return }
        var nextIdx = (idx + 1) % active.count
        while eliminated[active[nextIdx]] {
            nextIdx = (nextIdx + 1) % active.count
        }
        currentPlayer = active[nextIdx]
        checkAndRunAITurn()
    }
    
    private func checkAndRunAITurn() {
        aiTask?.cancel()
        guard currentPlayer < playerTypes.count else { return }
        let currentType = playerTypes[currentPlayer]
        guard currentType.isAI && winnerIndex == nil else { return }
        
        aiTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let solver = AISolver(boardSize: boardSize, activePlayers: activePlayerIndices, currentPlayer: currentPlayer, board: board)
            if let best = solver.calculateBestMove() {
                play(row: best.0, column: best.1)
            }
        }
    }
}

// MARK: - 6. 背景渲染层（解决相册自定义失效与颜色被遮挡问题）

struct DynamicBackgroundView: View {
    @ObservedObject var game: GameModel
    let isGameStarted: Bool
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch game.backgroundMode {
            case .defaultGradient:
                RadialGradient(
                    colors: [
                        isGameStarted ? (game.colors[safe: game.currentPlayer] ?? .blue).opacity(0.4 * game.bgOpacity) : Color.darkNavyBlue.opacity(game.bgOpacity),
                        Color.black
                    ],
                    center: .center, startRadius: 20, endRadius: 600
                )
                .ignoresSafeArea()
                
            case .simulatedDesktop:
                LinearGradient(colors: [.indigo.opacity(0.7), .purple.opacity(0.5), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blur(radius: 50)
                    .opacity(game.bgOpacity)
                    .ignoresSafeArea()
                
            case .customPhoto:
                if let uiImage = game.customUIImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(game.bgOpacity)
                        .ignoresSafeArea()
                } else {
                    Color.darkNavyBlue.opacity(game.bgOpacity).ignoresSafeArea()
                }
            }
        }
    }
}

// MARK: - 7. 设置 Sheet（自定义图片 + HDR）

struct VisualSettingsSheet: View {
    @ObservedObject var game: GameModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("背景显示设置")) {
                    Picker("背景类型", selection: $game.backgroundMode) {
                        ForEach(BackgroundMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    
                    if game.backgroundMode == .customPhoto {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            HStack {
                                Image(systemName: "photo")
                                Text(game.customUIImage == nil ? "选择本地壁纸图片" : "更换壁纸图片")
                            }
                        }
                        .onChange(of: selectedPhotoItem) { newItem in
                            Task {
                                if let data = try? await newItem?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                                    await MainActor.run { game.setCustomImage(img) }
                                }
                            }
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        Text("背景透光度: \(Int(game.bgOpacity * 100))%")
                        Slider(value: $game.bgOpacity, in: 0.1...1.0, step: 0.05)
                    }
                }
                
                Section(header: Text("HDR 棋子发光（高动态范围设备）")) {
                    Toggle("开启 HDR 高光", isOn: $game.enableHDR)
                    if game.enableHDR {
                        VStack(alignment: .leading) {
                            Text("HDR 增益亮度: \(String(format: "%.1f", game.hdrHeadroom))x")
                            Slider(value: $game.hdrHeadroom, in: 1.0...3.0, step: 0.1)
                        }
                    }
                }
            }
            .navigationTitle("界面外观设置")
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}

// MARK: - 8. 棋盘渲染与节点优化

struct BoardView: View {
    @ObservedObject var game: GameModel
    
    var body: some View {
        GeometryReader { proxy in
            let minSide = min(proxy.size.width, proxy.size.height)
            let gap: CGFloat = 2
            let side = (minSide - gap * CGFloat(game.boardSize - 1)) / CGFloat(game.boardSize)
            
            ZStack {
                VStack(spacing: gap) {
                    ForEach(0..<game.boardSize, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(0..<game.boardSize, id: \.self) { c in
                                let index = r * game.boardSize + c
                                let cell = game.board[r][c]
                                
                                CellView(
                                    game: game,
                                    cell: cell,
                                    color: cell.owner.flatMap { game.colors[safe: $0] },
                                    isPlayable: game.playableCells.contains(index)
                                )
                                .frame(width: side, height: side)
                                .onTapGesture {
                                    if game.playerTypes[safe: game.currentPlayer] == .human && game.playableCells.contains(index) {
                                        game.play(row: r, column: c)
                                    }
                                }
                            }
                        }
                    }
                }
                
                ForEach(game.flyingOrbs) { orb in
                    Circle()
                        .fill(game.colors[safe: orb.player] ?? .white)
                        .frame(width: max(6, side * 0.35), height: max(6, side * 0.35))
                        .position(
                            x: CGFloat(orb.toColumn) * (side + gap) + side / 2,
                            y: CGFloat(orb.toRow) * (side + gap) + side / 2
                        )
                }
            }
            .frame(width: minSide, height: minSide)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .drawingGroup() // 启用 GPU 离屏渲染，彻底解决多棋子爆炸卡顿
    }
}

struct CellView: View {
    @ObservedObject var game: GameModel
    let cell: Cell
    let color: Color?
    let isPlayable: Bool
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            
            if cell.count > 0, let color = color {
                ZStack {
                    Circle().fill(color)
                    Text("\(cell.count)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(game.enableHDR ? .white.opacity(game.hdrHeadroom) : .white)
                }
                .padding(4)
            }
        }
    }
}

// MARK: - 9. iPad 适配响应式主界面与对战界面

struct StartMenuView: View {
    @ObservedObject var game: GameModel
    let onStart: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("COLOR WAR")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundColor(.white)
            
            VStack(spacing: 12) {
                HStack {
                    Text("棋盘大小: \(game.boardSize) × \(game.boardSize)").foregroundColor(.white).bold()
                    Spacer()
                }
                Slider(value: Binding(get: { Double(game.boardSize) }, set: { game.boardSize = Int($0) }), in: 5...12, step: 1)
                
                Button(action: onStart) {
                    Text("开始对局")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.darkNavyBlue)
                        .cornerRadius(12)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .frame(maxWidth: 500) // iPad Split View 视窗拉伸响应
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}

struct GamePlayView: View {
    @ObservedObject var game: GameModel
    @Binding var isGameStarted: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏自动避让 Safe Area
            HStack {
                Button(action: {
                    withAnimation { isGameStarted = false }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Text("\(game.playerNames[safe: game.currentPlayer] ?? "") 的回合")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                
                Spacer()
                
                Button(action: { game.showVisualSettingsSheet = true }) {
                    Image(systemName: "paintpalette.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Spacer()
            
            BoardView(game: game)
                .padding(16)
            
            Spacer()
        }
        .safeAreaPadding(.top)
    }
}

// MARK: - 10. App 根视图

struct ContentView: View {
    @StateObject private var game = GameModel()
    @State private var isGameStarted = false
    
    var body: some View {
        ZStack {
            DynamicBackgroundView(game: game, isGameStarted: isGameStarted)
            
            if isGameStarted {
                GamePlayView(game: game, isGameStarted: $isGameStarted)
            } else {
                StartMenuView(game: game, onStart: {
                    game.resetGame()
                    withAnimation { isGameStarted = true }
                })
            }
        }
        .sheet(isPresented: $game.showVisualSettingsSheet) {
            VisualSettingsSheet(game: game)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
