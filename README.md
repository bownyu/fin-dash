# FinDash

[![Release](https://img.shields.io/github/v/release/bownyu/fin-dash?include_prereleases)](https://github.com/bownyu/fin-dash/releases/latest)
![Platform](https://img.shields.io/badge/platform-Android%20arm64-3DDC84)
![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B?logo=flutter)
![License](https://img.shields.io/badge/license-MIT-blue)

本地优先的 Android 个人记账应用，基于 Flutter 构建。账本保存在设备上的 SQLite 中，不依赖账号和服务端。

内置的 AI Agent 接入用户自配的 OpenAI 兼容接口。它可以通过受控工具查询账本，但所有写操作都要由用户在本地审阅后才提交。语音记账使用 sherpa-onnx 和 SenseVoice 在端侧完成识别。

## 功能

- **记账**：支持支出、收入和转账。账户分为资金、信用、充值、投资四类，共 37 种预设，可设置信用卡账单日和还款日。另有月预算，以及按日、周、月、年的统计和分类明细；账单支持搜索、组合筛选、批量操作和 CSV 导出。
- **AI Agent**：
  - 兼容 Chat Completions 与 Responses 两种协议，支持 SSE 流式输出，并展示推理和工具调用轨迹。
  - 账户和账单可分页查询、汇总，复杂分析交给受限的声明式查询程序，支持截图输入。
  - 记账、账户、预算、记忆、目标和约定的变更一律先生成方案，经用户审阅后提交，事后可以撤销。
  - 每轮请求附带用户简报（目标、偏好、观察、约定、本月预算），支持约定回访；交流风格以固定规则注入。
- **离线语音记账**：语音识别在端侧完成，模型随 APK 分发。转写出的文字交给 LLM 解析为待确认的账单草稿。支持桌面小部件录音。
- **支付通知识别**：采集微信和支付宝的支付通知，生成待确认记录，人工选择账户后才入账。退款和疑似重复记录需要逐笔核对。
- **导入与备份**：可导入微信支付导出的 `.xlsx` 账单，按交易单号去重，退款单独入账。支持完整 JSON 备份与恢复，恢复前会自动保存快照。
- **OTA**：从 GitHub Releases 拉取更新清单，下载后先校验，再执行覆盖安装。

## 架构

```text
Flutter / Dart
  ui/            页面；AppScope（InheritedModel）按数据域订阅
  services/      AiService · OpenAiTransport · AgentActions · 语音 · 支付通知 · 微信导入 · OTA
  agent/         TaskRuntime · CapabilityHost · QueryRecipe · ModelQueue
  application/   LedgerCommands · LedgerQueries · CapabilityRegistry
  domain/        模型 · LedgerOperations（交易规则）· 审阅与查询契约
  data/          WalletStore ─┬─ SQLite（原生，提交在后台 isolate）
                              └─ SharedPreferences（Web 预览）
      │
      │ MethodChannel
      ▼
Android / Kotlin
  SpeechCapture（sherpa-onnx）· VoiceWidget + WidgetVoiceService
  PaymentNotificationListener + NotificationInbox（SQLite）
  OtaBridge + OtaPolicy
```

### 账本与存储

- **单一写入口**：`WalletStore` 是唯一的写入口，所有写操作进入串行提交队列。持久化成功后才发布新快照并通知 UI；失败时整笔回滚，内存状态保持不变。
- **不可变快照**：已提交的快照不可修改。数据按域划分为 `ledger`、`tasks`、`conversations`、`preferences`、`memory`、`sources`，UI 只订阅自己用到的域。例如 AI 写入对话记录时，账单页面不会重建。
- **两条提交通道**：账务记录和元数据（对话、偏好、记忆、任务）分开提交，元数据通道不能修改账务记录。
- **SQLite 表结构**：原生端使用 `wallet_rows(bucket, id, position, kind, body, checksum)` 按行增量提交，交易记录按日期、类型、账户等字段建立表达式索引，提交在后台 isolate 执行。
- **金额与余额**：金额以整数“分”存储，余额由期初余额和交易记录推导得出。

### AI Agent

- **调用循环**：`AiService` 驱动多轮 tool calling，单次请求最多 12 轮。`OpenAiTransport` 负责解析两种协议的 SSE 流。流式 token 由独立的 `ValueNotifier` 每 80 ms 合并刷新，只重建当前这条回复。
- **能力注册**：工具注册在 `CapabilityRegistry` 中，每项能力声明 JSON Schema 入参和副作用等级（`read` / `prepare` / `preferenceWrite` / `ledgerCommit` / `external`）。执行前会校验参数和账本锁定状态。
- **写操作必须经过审阅**：模型无法直接写入账本。`propose_*` 工具只生成提案，由 `AgentActions` 按任务聚合成批次；用户可以在批次中排除或调整单项，确认后在一个事务内执行并写入回执。操作 ID 加上载荷哈希保证重试幂等；批次在没有后续冲突时可以撤销。授权对象 `AuthorizationGrant` 只能由宿主 UI 创建，不存在从模型输出反序列化的路径。
- **提示词与上下文**：`PromptAssembler` 把关系与情感原则、语气规则和 AppSpec 放在可信规则区。`AiService` 每轮生成有界的用户简报，与按关键词召回的记忆一起放在资料区 JSON，总量受 16 KB 上限约束；人设中的自由文本只作为表达偏好，不能改变规则。
- **查询程序**：复杂分析使用 `QueryRecipe`，这是一种声明式查询程序，提供 `scan` / `filter` / `group` / `derive` / `compare` / `sort` / `take` / `project` 等算子，限制了程序大小和执行预算，不执行任意代码或 SQL。
- **任务状态**：`TaskRuntime` 持久化任务状态（`preparing` → `needsInput` / `ready` → `applying` → `completed`，以及 `interrupted`、`cancelled`、`failed`），中断后可以恢复，每个任务都有模型调用轮次预算。

批次的审阅与提交流程见 [docs/agent-batch-design.md](docs/agent-batch-design.md)。

### 语音

- **识别**：`SpeechCapture` 把 PCM 音频写入私有临时文件。模型在录音期间由后台线程加载，录音结束后由 Silero VAD 切分语音段，再交给 SenseVoiceSmall INT8 在 CPU 上推理。音频在转写完成或取消后删除。
- **手动起止**：录音由用户手动开始和结束，静音不会自动结束录音。录音时每 100 ms 推送一次音量，用于显示音量条和静音提示。
- **纠错**：提示词说明文字来自语音识别，允许按读音匹配账户和商家；同时附上最多 5 笔标题相近的已确认账单（只含标题、类型、分类和账户 ID）。模型标出推测的字段，核对卡片会标记这些字段。核对时可以再说一句修改，App 和小部件都通过 `VoiceBookkeeping` 把这句话和当前草稿一起交给模型，只改动提到的字段。
- **桌面小部件**：小部件通过前台服务（`foregroundServiceType=microphone`）录音，并复用同一个 `FlutterEngine` 调用 Dart 侧的解析逻辑。
- **联网要求**：ASR 离线完成；把文字解析成账单需要联网调用 LLM。

### 支付通知

- **采集**：`NotificationListenerService` 按包名和规则筛选通知，写入原生 SQLite 收件箱。
- **同步与 ACK**：App 回到前台时同步收件箱。账本提交成功后才 ACK 并删除原生事件；如果提交前崩溃，下次启动会按事件 ID 幂等重放。
- **批量确认**：批量确认在同一次提交中重新校验账户、锁定状态、金额、时间和重复项。

### OTA

更新清单 `ota-manifest.json` 随 GitHub Release 发布，构建时通过 `--dart-define=OTA_MANIFEST_URL` 注入地址。下载后先校验文件大小和 SHA-256；安装前 `OtaPolicy` 再校验三项：包名一致、versionCode 与清单一致且比当前版本新、签名证书与已安装版本一致。

## 隐私

- 仓库中不包含用户数据、密钥或签名文件。
- 运行时只会发起两类网络请求：发往用户配置的 AI 接口，以及访问本仓库的 Release。
- API 密钥存放在系统安全存储（`flutter_secure_storage`）中，导出备份时会剔除。

详见 [docs/publication-privacy.md](docs/publication-privacy.md)。

## 构建

依赖：Flutter 3.41.1（Dart 3.11）、Android SDK、JDK 17+、PowerShell（`pwsh`）。

```powershell
flutter pub get
./scripts/prepare-offline-voice.ps1   # 下载语音模型与 sherpa-onnx AAR，按锁定文件校验 SHA-256
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

- 没有 `android/key.properties` 时，release 构建会回退到调试签名。正式签名的配置方式见 `android/key.properties.example`。
- 加上 `--dart-define=DEMO=true` 会使用内存示例数据启动，不读写真实账本。
- 发布与 OTA 流程见 [docs/ota-release.md](docs/ota-release.md)，CI 配置在 `.github/workflows/release.yml`。

## 限制

- 仅支持 Android arm64。Web 构建只用于开发预览，不包含语音、通知采集等原生能力。
- 仅支持人民币。
- 没有多设备同步，换设备需要通过备份文件迁移。
- 语音模型打包在 APK 内，安装包约 345 MB。

## 许可证

[MIT](LICENSE)。第三方组件的许可文本位于 [assets/licenses](assets/licenses)。

## 致谢

[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) · [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) · [Silero VAD](https://github.com/snakers4/silero-vad) · [ONNX Runtime](https://github.com/microsoft/onnxruntime)
