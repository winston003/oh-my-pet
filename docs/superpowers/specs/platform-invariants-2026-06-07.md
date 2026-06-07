# Platform Invariants — 跨平台不变量契约

Date: 2026-06-07  
Owner: 全项目（所有 rein / agent 必读）  
Companion: `architecture-overview-2026-06-07.md` · `data-model-and-protocols-2026-06-07.md` · `AGENTS.md`  
Status: agent contract — 新平台、新语言、新壳层都必须遵守

---

## 0. 一句话给所有 agent

> **宠物是一份可移植的本地 profile 包；应用是各平台原生壳，只负责把同一份契约渲染出来。**

换平台时：**改壳，不改魂。**  
魂 = 产品承诺 + 数据模型 + 协议边界 + 模块依赖方向。  
壳 = 透明窗、点击穿透、系统托盘、安全存储、权限弹窗。

当前 MVP 用 Swift + AppKit 实现 macOS 壳，**不是**因为 Swift 是永恒答案，而是因为壳必须原生。其他平台应各自写原生壳，接入同一套不变量。

---

## 1. 产品不变量（任何平台、任何版本都不破）

这些来自 `AGENTS.md`，优先级高于技术选型：

| # | 不变量 | 含义 | 破例后果 |
|---|---|---|---|
| P1 | **情感陪伴优先** | 不是聊天机器人、不是高压效率工具、不是自主电脑控制 agent | 产品定位漂移 |
| P2 | **安静在场** | 默认低打扰；不强迫说话、不焦虑循环、不喂食惩罚 | 用户很快关掉 |
| P3 | **用户真正拥有宠物** | 本地 profile、本地资产、可导入导出、可删除 | 信任崩塌 |
| P4 | **诚实感知** | 宠物可以「感觉」懂你，但**不能欺骗**自己能访问什么 | 隐私红线 |
| P5 | **默认不偷看** | 无秘密录屏、无秘密麦克风、无自动读文件/浏览器/聊天/选区 | 法律与口碑风险 |
| P6 | **BYOK + 本地优先** | 用户自带 provider key；无强制账户、无托管 AI、无默认云同步 | 架构被锁死 |
| P7 | **五通道立体化** | Voice / Action / Expression / Humor / Story 可独立替换、跨 pet 复用 | 定制变 cosmetic |
| P8 | **权限分层** | Base → App-aware → Selected Text → Screen；逐级开启、可解释、可关闭 | 首启吓跑用户 |

**agent 判据**：若某「跨平台方案」要求破 P1–P8 中任一条以换取「一套代码多平台」，**拒绝该方案**。

---

## 2. 领域模型不变量（可跨语言、跨 OS 移植）

### 2.1 宠物身份与状态

```text
PetState（冻结枚举）: idle | focus | happy | tired | celebrate
```

- 全平台 UI、动画、行为映射**必须用同一套 state 名**。
- 新增 state 走 schema minor 版本（`0.2.x`），老 profile 仍可加载。

### 2.2 行为映射（纯逻辑，零 UI）

```text
PetTrigger → PetState   （BehaviorMap）
```

| Trigger | 默认目标 state | 说明 |
|---|---|---|
| `focusStarted` | `focus` | 用户开始专注 |
| `focusCompleted` | `celebrate` | 专注完成 |
| `taskCompleted` | `happy` | 任务完成 |
| `longWorkSession` | `tired` | 长时间工作 |
| `userReset` | `idle` | 用户重置 |

**不变量**：触发器语义全球一致；各平台 Runtime **只消费** `BehaviorMap`，不硬编码 state 跳转。

### 2.3 五通道编排（表达契约）

```text
ChannelKind 优先级: expression < action < audio
调度顺序: expression → action → audio（同一次事件内）
```

| 通道 | 职责 | 典型载体 |
|---|---|---|
| `expression` | 脸 / 情绪脸切换 | 最便宜，先切 |
| `action` | 姿态 / 弹簧 / 点击反应 | 动画 |
| `audio` | TTS / 口头禅 / 音效 | 最重，可降级跳过 |

**不变量**：

- AI 或用户事件 → **一次编排**多通道，不是三次独立调用。
- `ChannelSink` 是平台无关的**输出契约**；macOS 用 `PetPanel`，Windows 用自有 sink，**接口语义相同**。
- 通道 pack 可跨 pet 拆换（Mitu 声音 + Zorp 幽默 + Pako 身体）。

### 2.4 PetProfile 包（产品真正的「源代码」）

```text
.ohmpet/
├── manifest.json          # PetProfile v0.1.0+
├── assets/visual/         # 五 state 图（或 sprite/live2d 引用）
└── house/                 # memories / stickers（运行时写入）
```

**不变量**：

- `manifest.json` 是**唯一权威**身份描述；平台壳只读 + 按规则写 `house` 子树。
- 版本 SemVer：`0.1.x` 补字段 · `0.2.x` 加可选字段 · `0.y.0` 破坏性变更拒绝加载。
- Import/Export 产物**必须在平台间互通**——用户在 macOS 创建的 pet，Windows 上应能导入同目录。
- 未知 JSON 字段 → 忽略（前向兼容）。

### 2.5 记忆与 Pet House

```text
Focus 完成 → MemorySticker → house/memories.json（追加，不重写整份 profile）
```

**不变量**：

- 共享记忆来自**用户完成的事**（focus / task），不是 AI 臆造。
- House 写盘**只动 `house/` 子树**，禁止重写 `manifest.json` 顶层字段。
- 记忆是情感空间，不是管理模拟器（无积分、无 decay）。

---

## 3. 协议不变量（语言无关的接口契约）

实现语言可以是 Swift / Rust / TypeScript / C#，但**语义必须同构**。

### 3.1 Provider 三元组（生成类 AI）

```text
ImageProvider  — 文生图 / 图生图 / state 重生成
VoiceProvider  — 风格生成 / 克隆（需 consent）
TextProvider   — 文本补全（Studio / Selection）
```

**不变量**：

- `ProviderRegistry` 注册式发现；**禁止**调用方 `import OpenAI` 等具体 SDK。
- 内置至少 1 个 `Stub*Provider`，保证无网、无 key 时 UI 可跑通。
- 每次调用前 UI **必须**展示：provider id、model、数据类型、发送内容预览。
- 统一 `ProviderError` 分类（keyMissing / rateLimited / contentRefused / …）。
- Provider **不写盘到 profile**；生成结果进本地缓存路径，manifest 记 metadata。

### 3.2 Agent Adapter（执行类外部 agent）

```text
AgentAdapter 平行于 Provider，互不 import
通信: stdio + JSON-RPC 2.0；fallback 仅 127.0.0.1 loopback
禁止: 对外开放 HTTP / WebSocket server
```

**不变量**：

- 没有 Agent Adapter，宠物**完全可用**（可选挂件，非 MVP 硬依赖）。
- 不 link agent runtime SDK；只 spawn 子进程 / loopback。
- `AgentSession` 与 `house/memories` **解耦**；各自落盘。

### 3.3 凭据存储（概念不变，实现 per-OS）

```text
语义:
  service  = "com.oh-my-pet.providers"
  account  = <providerId>     // 例: "openai"
```

| 平台 | 实现 |
|---|---|
| macOS | Keychain (`kSecClassGenericPassword`) |
| Windows | Credential Manager / DPAPI |
| Linux | libsecret / kwallet（降级到加密本地文件需显式标注） |

**不变量**：

- key **永不**进 git、明文文件、profile 包、日志。
- UI 只显示「已配置 · 更新日期」，不显示 key 明文。
- **不做** iCloud / 跨设备 key 同步（本地唯一）。

---

## 4. 架构不变量（模块怎么拆，永远不变）

### 4.1 三层模型

```text
┌─────────────────────────────────────┐
│  Core（平台无关）                    │
│  PetProfile schema · BehaviorMap    │
│  StateMachine · ChannelDispatcher   │
│  Provider / AgentAdapter protocols  │
│  House stores · 校验 / 升级逻辑      │
└──────────────┬──────────────────────┘
               │ 只通过 protocol 边界
┌──────────────▼──────────────────────┐
│  Shell（每平台一份，原生实现）         │
│  透明浮窗 · hitTest · 托盘/菜单栏    │
│  权限 UX · 帧循环 · 平台安全存储     │
└─────────────────────────────────────┘
```

### 4.2 依赖方向（单向，严禁反向）

```text
Host → Runtime(Shell) → Profile(Core) → Providers / Asset → Local Data
```

| 规则 | 说明 |
|---|---|
| Runtime **不** import Providers | 宠物壳不调 AI；Studio 才调 |
| AgentAdapter **不** import Providers | 平行能力 |
| Profile **不**依赖 Runtime | 纯数据 + 校验 |
| House 写 profile 只写 `house/` | 局部更新 |
| Asset schema **不**依赖 Providers | 格式先于实现 |

### 4.3 渲染扩展点

```text
PetRenderer protocol
  ├── static-image   （MVP）
  ├── sprite
  ├── live2d
  ├── spine
  └── video
```

**不变量**：`visualProfile.runtime` 声明能力；壳层按声明选 renderer，**不在代码里写死**「只会 PNG」。

---

## 5. 平台相关量（每 OS 必须重写，禁止假装可共享）

以下**不是**不变量。复制到 Windows/Linux 时，**预期全部重写**，不要试图用 Electron 一层糊过去：

| 能力 | macOS 现实现 | 其他平台 |
|---|---|---|
| 透明置顶窗 | `NSPanel` + `.nonactivatingPanel` | Win32 layered / DWM；X11/Wayland 降级 |
| 点击穿透 + alpha 命中 | `ignoresMouseEvents` + `hitTest` | `WS_EX_TRANSPARENT` + 像素采样；Wayland 常需降级 |
| 跨虚拟桌面跟随 | `collectionBehavior` | 各 OS 窗口管理器差异大 |
| 菜单栏 / 托盘 | `NSStatusItem` | Shell_NotifyIcon / StatusNotifier |
| 帧驱动 | `CADisplayLink` / `CVDisplayLink` | 各平台 vsync API |
| 安全存储 | Keychain | 见 §3.3 |
| 权限 UX | Accessibility 延后请求 | 各 OS 等价分层 |
| 本地数据根目录 | `~/Library/Application Support/oh-my-pet/` | `%AppData%` / `~/.local/share/oh-my-pet/` |

**agent 判据**：若任务落在 §5 表格，交给**该平台 Shell 专家**；不要把 AppKit 代码「 ifdef 一下」就当跨平台完成。

---

## 6. 给各 rein 的分工不变量

| Rein | 只拥有（不变） | 绝不碰（可变壳层） |
|---|---|---|
| **pet-asset** | PetProfile schema、pack 格式、import/export、许可 | 窗口、hitTest、帧率 |
| **pet-brain** | Provider/Agent 协议、prompt 编排、记忆结构、权限分层文案 | NSPanel、菜单栏 |
| **pet-runtime** | Shell 实现、ChannelSink 落地、性能降级 | schema 破坏性变更、provider 内嵌 |
| **pet-product** | 产品承诺分级、免费边界、对外叙事 | 具体窗口 API 选型 |

**跨平台扩展时**：

- `pet-asset` / `pet-brain` 产出**应可直接被非 Swift 复刻**（JSON Schema + 协议文档优先）。
- `pet-runtime` 按平台分叉（`pet-runtime-macos` / `pet-runtime-windows`），**共享 Core 测试向量**。
- `pet-product` 对外只承诺「profile 可迁移」；不承诺「同一安装包全平台」除非已验证。

---

## 7. 新平台接入检查清单（给其他 agent 的执行顺序）

1. **先移植 Core**：能加载 `manifest.json`、跑通 `BehaviorMap`、校验失败不崩溃。
2. **再实现 Shell 最小闭环**：透明窗 + 静态 `idle` + 拖拽 + 托盘退出。
3. **接入 ChannelSink**：expression → action → audio 顺序与 macOS 一致。
4. **映射 SecureStore**：service/account 命名与 macOS 相同。
5. **跑通 House 端到端**：focus 完成 → memory 写入 → 重启后仍在。
6. **最后才接 Provider/Agent**：Stub 先行，真实 adapter 后补。
7. **验收**：macOS 导出的 `.ohmpet` 在新平台 import 后视觉 / 行为 / 记忆一致。

---

## 8. 常见误判（agent 必须避免）

| 误判 | 正确做法 |
|---|---|
| 「用 Tauri/Electron 就不用写 Windows 壳」 | 透明窗 + 穿透仍需原生插件；Core/Shell 分离不变 |
| 「跨平台 = 把 PetProfile 改成 SQLite」 | profile 仍是 JSON + 资产目录；数据库是可选索引层 |
| 「Windows 版可以默认读剪贴板」 | 选区读取属于 Selected Text 层，用户显式触发 |
| 「为了省事把 Provider 塞进 Runtime」 | 破依赖方向；Studio 与壳必须分离 |
| 「新平台改 state 名叫 working/resting」 | 破 schema 契约；用 `focus`/`tired` 或走版本升级 |
| 「Keychain 路径写进 manifest」 | 破安全不变量；凭据只在 SecureStore |

---

## 9. 与现有代码的映射（macOS MVP 参考）

| 不变量层 | 当前仓库位置 |
|---|---|
| Core 数据 | `PetProfileKit/`（零 AppKit） |
| Shell | `PetProfileRuntime/`（AppKit） |
| 编排 | `PetProfileBrain/` + `ChannelDispatcher` |
| 协议 spec | `docs/superpowers/specs/data-model-and-protocols-2026-06-07.md` |
| 壳 spec | `docs/superpowers/specs/runtime-architecture-2026-06-07.md` |

**目标形态**：`PetProfileBrain` 最终应只依赖 Core + `ChannelSink` protocol，**不**直接依赖 `PetProfileRuntime` 具体类型——方便 Windows Shell 注入自己的 sink。

---

## 10. 修订规则

- 破 **§1 产品不变量** → 需 owner 显式批准，并同步 `AGENTS.md` + 中英文 README。
- 破 **§2–§4 技术不变量** → 升 PetProfile major 或新开 ADR，禁止 silent break。
- 新增平台 → 只追加 **§5 实现映射行**，不改 §1–§4。

---

*本文档是所有 agent 的跨平台「宪法」。实现细节看 companion spec；产品边界看 `AGENTS.md`。*
