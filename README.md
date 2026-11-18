# Color War

Color War 是一款以连锁反应为核心的 iOS 棋盘策略游戏，使用 SwiftUI 构建，支持 iPhone 和 iPad。你可以在本地双人或多人对局中游玩，也可以通过局域网或远程房间与其他玩家联机；另有独立的棋局分析器。

## 游戏模式

- **对弈**：双人模式，可选择 6×6、9×9 或 12×12 棋盘，并设置红、蓝双方由真人或 Bot 控制。
- **派对**：在多人本地对局和远程联机之间切换。多人模式支持最多 8 个座位，可配置玩家、棋盘与先手；远程模式可创建或加入六位数房间码。
- **分析器**：使用 6×6、9×9 或 12×12 棋盘编辑局面、启动或暂停分析、撤销操作及切换我方颜色。可以手动设置红蓝棋子，并回应 AI 的建议走法。

游戏设置和背景图片保存在本机；对局存档可从菜单导入，也可在游戏内保存和恢复。

## AI

- **Bot 1**：基础算法对手。
- **Bot 2**：加强版算法对手。
- **Bot 3**：基于 Drive 双人算法移植的对手，仅用于双人模式；多人或联机设置不提供 Bot 3。

不同 Bot 使用不同的走子实现。项目还包含可复用的搜索引擎代码；具体搜索预算和行为以当前 Swift 实现为准。

## 联机

- **局域网**：使用 Apple Multipeer Connectivity 发现并连接附近设备。
- **远程房间**：使用 WebSocket 房间进行远程联机，由房主配置棋局并管理大厅。

联机需要双方设备具备可用的网络连接。房间连接和同步状态以应用内显示为准。

## 项目结构

- `ContentView.swift`：SwiftUI 页面、棋盘交互、模式导航、分析器及网络界面。
- `GameModel.swift`：棋局状态、玩家配置、回合与连锁反应处理、存档及联机同步。
- `AIEngine.swift`：AI 搜索与评估相关实现。
- `Resources/DotsAnalyzer.html`：网页端棋局分析器资源。
- `Resources/AISolverTrainer2536.py`：AI 求解器相关 Python 资源。
- `Tests/`：Python 静态集成与行为回归测试。
- `.github/workflows/build_ipa.yml`：GitHub Actions 的 iOS Archive、未签名 IPA 和 Release 工作流。

## 检查与构建

运行仓库中的 Python 测试：

```bash
python3 -m unittest discover -s Tests -v
```

本项目的 `Package.swift` 使用 Swift Package Manager 的 Apple app manifest，目标平台为 iOS 26，设备系列为 iPhone 和 iPad。构建 iOS 应用需要配置了相应 Apple 开发工具的 macOS 环境。推送至 `main` 或 `master` 会触发仓库工作流构建未签名 IPA 并发布 Release。

## 许可

本项目采用仓库根目录 `LICENSE` 中注明的许可。
