# Color War AI 🔴🔵🟢🟠

一个基于 **SwiftUI** 开发的极简玻璃质感棋盘连锁反应策略游戏。项目集成了 **CoreML (NPU/GPU) 深度神经网络**（暂时移除） 与 **多线程并发 MCTS / Minimax 数学算法**

---

## ✨ 核心特性

* **双 AI 驱动引擎**：
  * **CoreML / NPU 神经网络**：支持 `[1, 5, 12, 12]` 与 `[1, 4, 12, 12]` 张量输入的端侧深度学习模型，支持毫秒级 NPU/GPU 硬件加速推理。
  * **经典数学算法**：涵盖简单、正常、困难、专家、终极到噩梦 6 种难度，内置 **Alpha-Beta 剪枝的 Minimax** 与 **并行蒙特卡洛树搜索（MCTS + UCB1）**。
* **实时硬件诊断 (Performance Overlay)**：
  * 基于 Darwin `mach_task_self_` API 实现多核 CPU 占用的实时精确采样。
  * 监测 CoreML 模型在 NPU/GPU 上的单次推理耗时（ms）。
* **流畅 UI & 视效**：
  * 全 SwiftUI 构建，采用 Glassmorphism 现代玻璃拟态视觉风格。
  * 基于 `Swift Concurrency` 的连锁爆炸与粒子飞跃动画。
* **灵活对局配置**：
  * 支持 2 ~ 4 人对局（真人与各类 AI 自由组合）。
  * 棋盘尺寸支持 $5 \times 5$ 至 $12 \times 12$ 动态自定义。
  * 内置随机抽取先手轮盘。

---

## 🤖 AI 算法架构

| AI 类型 | 难度/标识 | 算法原理 | 计算硬件 / 引擎 |
| :--- | :--- | :--- | :--- |
| **神经网络 AI** | `ColorWarAI` | 5 通道输入状态评估与 Policy Logits 概率输出 | CoreML (NPU / GPU 加速) |
| **神经网络 AI** | `12x12` | 4 通道通用棋盘推理模型 | CoreML (NPU / GPU 加速) |
| **数学 AI** | `噩梦 / 困难` | 深度 Alpha-Beta 剪枝 Minimax 搜索与战术估值 | 多核 CPU 并行 |
| **数学 AI** | `终极 / 专家` | 4 任务并发蒙特卡洛树搜索（MCTS + UCB1） | Swift Concurrency (`TaskGroup`) |
| **数学 AI** | `简单 / 正常` | 基础贪婪启发式选择与随机决策 | CPU 单线程 |

---

## 🛠️ 技术栈

* **语言/框架**：Swift 5.10+ / SwiftUI
* **机器学习**：CoreML (`MLModel`, `MLMultiArray`)
* **底层 API**：Darwin (`mach_task_self_`, `thread_info`)、QuartzCore (`CACurrentMediaTime`)
* **支持平台**：iOS 17.0+ / macOS 14.0+ (Designed for iPad/Mac)

---

## 🚀 快速开始

### 1. 克隆仓库
```bash
git clone [https://github.com/wujiyan09/Color-War-AI.git](https://github.com/wujiyan09/Color-War-AI.git)
cd Color-War-AI
```

## Dynamic Island / ActivityKit push setup

The app starts one Live Activity for an online room, renders a compact board preview in the expanded Dynamic Island and lock-screen presentation, and registers the ActivityKit push token with the room server over the active room WebSocket. The server sends best-effort `liveactivity` APNs updates after it accepts an authoritative `stateSnapshot`. The token is scoped to the participant seat; it is not an APNs credential and is not written to source control. The host-only room-resume credential is stored in Keychain and sent in an HTTPS WebSocket request header, not the URL.

The Live Activity is display-only. It cannot host a WebSocket or independently fetch game state. iOS can suspend the game process; APNs may update the activity, but cannot guarantee a background socket or a timely app wake. On foreground the app reconnects and requests the authoritative saved snapshot. Room state is retained for two hours after activity, and the last committed snapshot wins if a move was interrupted before it was committed.

To enable real APNs updates on a signed installation:

1. In Apple Developer, enable Push Notifications for the app's App ID and use the same bundle identifier configured in `project.yml` (replace the sample `com.example.ColorWarAI` before distribution). Enable Live Activities for the app as well.
2. Create an APNs authentication key (`.p8`) and note its Key ID and Team ID. Do not commit the `.p8` file, its contents, or token values.
3. Configure Worker secrets with `npx wrangler secret put APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, and `APNS_BUNDLE_ID`. Paste the private key only into the Wrangler secret prompt. The server accepts an optional `APNS_HOST` variable set to exactly `https://api.push.apple.com` (production, default) or `https://api.sandbox.push.apple.com` (development); the device token's environment must match.
4. Build and sign the app with matching Push Notifications entitlement and provisioning profile. The checked-in `ColorWarAI.entitlements` uses the development APNs environment as a template; set it to production for distribution signing. An unsigned IPA cannot register for APNs or provide an operational Live Activity push token.
5. Deploy the server separately after configuring secrets, then test on a physical supported iPhone with Live Activities enabled. GitHub's macOS runner can build an Xcode project, but this repository's workflow and project conversion have not yet been run or verified in this environment.

APNs failures are intentionally non-fatal: the room's authoritative snapshot remains available for reconnection. The Worker deletes a token only when APNs reports it as expired (HTTP 410); APNs credentials, app signing, notification settings, network delivery and iOS scheduling must all be valid for a real update.
