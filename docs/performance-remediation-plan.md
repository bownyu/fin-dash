# 性能整改计划（2026-10-04）

状态：2026-10-05 已完成第 1–5 步源码修改与自动化验证，按步骤分别提交，最终源码版本 0.7.1。自动化基线与验证结果见 [整改记录](performance-remediation-results.md)。当前未连接 Android 手机，第 0 节及各阶段的真机 profile、长按选择与复制验收仍待执行；未生成安装包。

依据为 2026-10-04 的代码审查：写入链路在 UI 线程上按元数据总量做深拷贝和深比较，订阅范围过宽导致不可见页面重建，渲染层存在叠加的离屏层。审查时没有真机 profile 数据。

## 目标

- 每次写入的 UI 线程成本与改动量成正比，不再随聊天历史和元数据总量增长。
- AI 回复期间，不可见的标签页不重建；AI 状态文字变化不重建消息列表。
- 120Hz 设备上主要交互的 UI 帧与 raster 帧 p90 不超过 8ms、p99 不超过 16ms。这是目标值，验收以与基线的对比为准。
- 数据安全规则保持不变：事务完成后再发布、行校验和、旧实例拒写、迁移失败可重试。镜像改为异步后的行为变化，在第 4 步单独定义。

## 执行顺序

1 → 2 → 3 → 4；第 5 步与其他步骤独立，可以穿插执行。

- 第 3 步依赖第 2 步的结构共享：只有改动路径上的对象换新，worker 增量才能按引用判断变化。
- 第 4 步依赖第 3 步的常驻 worker：镜像同步在 worker 内调度。
- 第 5 步的首访预构建（5.2）依赖第 1 步；否则预构建出的后台页会被 AI 写入反复触发重建。

每步单独提交、单独验证。

## 0. 基线测量

环境：先加载 `scripts/environment.ps1`，在用户手机上用 `flutter run --profile` 运行，DevTools Performance 记录 UI / raster 帧时间与掉帧数。

| 场景 | 操作 | 记录 |
| --- | --- | --- |
| S1 | 冷启动后首次切到统计、账单；再来回切换 | 切换期间帧时间；点击到画面开始变化的延迟 |
| S2 | 首页点快捷交易打开记一笔；点账单行弹出详情 | 打开过程帧时间 |
| S3 | 首页切换隐藏金额 | 点击到金额变化的延迟 |
| S4 | 在长历史会话中发送一条会调用工具的消息，直到回复完成 | 全程掉帧数、最长帧 |
| S5 | 长会话上下滚动 | 滚动帧时间 |
| S6 | 记一笔点保存，到页面关闭 | 耗时 |

同时记录数据规模：账单数、聊天条数、数据库文件大小。

自动化基线：在 `tool/benchmarks/` 新增一个元数据较重的基准，构造 2,000 条聊天、每条带 3 个约 8KB 工具结果，测量 `changeMetadata(chats.add)` 在 UI isolate 上的耗时，与现有 `sqlite_save_benchmark_test.dart` 一起作为前后对比。

## 第 1 步：UI 订阅收敛与派生数据缓存

目标：AI 写入只触发真正读取对话、任务数据的组件；运行时状态变化只触发显示状态的组件。

### 1.1 AppScope 接口

文件：`lib/ui/design.dart`

- 新增 `AppScope.aiOf(context)`：通过 `getInheritedWidgetOfExactType` 取 `AiService`，不建立依赖。凡是只为调用服务方法、读取服务对象而写的 `AppScope.of(context).ai`，都改用它。
- 新增 `RuntimeBuilder`：只监听 `store.runtimeUpdates`，用于显示 `aiStatus`、依赖 `ai.busy` 的按钮。
- 在注释中写明：`storeOf(context, domains: const {})` 表示只读、不订阅。
- `AppScope.of(context)` 仅保留给确实需要“任意变化都重建”的位置。逐个审查现有 38 处调用。

### 1.2 公共组件

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| `privateMoney` / `privateFinancialText` / `MoneyText` | 订阅全部数据域 | 只订阅 `preferences`；`privateFinancialText` 的正则提为 `static final`；去掉 `MoneyText` 中 begin 与 end 相同、实际不播放的 `TweenAnimationBuilder` |
| `TransactionRow` | 订阅全部域；每行线性查找分类；每行新建 `DateFormat` | 订阅 `{ledger, preferences}`；改用 `store.category(name, type)` 索引；`DateFormat` 提为顶层 `final` |
| `Avatar` | 每次 build 都 `base64Decode`，生成新字节数组，图片缓存失效 | 按头像字符串缓存解码结果（小容量 LRU）；`Image.memory` 设置 `cacheWidth` / `cacheHeight` 按显示尺寸解码，并加 `gaplessPlayback` |

### 1.3 页面

| 位置 | 现状 | 改为 |
| --- | --- | --- |
| `HomePage` | 指定了 3 个域，但 build 中的 `privateMoney(context)` 又订阅了全部域；`store.suggestions` 每次 build 计算 4 次 | 1.2 完成后自然收敛为 3 个域；`suggestions` 用局部变量算一次 |
| `StatsPage` | `query(range, type)` 计算两次，`total` 计算多次 | 各算一次 |
| `BillsPage` | 每次 build（包括选择模式下的每次点击）都全量 query、按天分组 | 在 State 内记忆 list、groups、entries、dailyExpenses；键为 transactions / accounts 的引用、筛选条件和搜索词 |
| `ProfilePage` | 订阅全部域，并用了 `AppScope.of` | 订阅 `{ledger, preferences, memory}`；`aiStatus` 副标题用 `RuntimeBuilder`；模型名通过 `aiOf` 读取 |
| `AgentActionCard` / `AgentBatchCard` / `TaskCard` | `AppScope.of` 加上订阅全部域 | 按实际读取的字段订阅（主要是 `tasks`、`ledger`）；`busy` 用 `RuntimeBuilder`；服务对象用 `aiOf` |
| `PaymentEntryReminder` | `didChangeDependencies` 订阅全部域，实际只需要 store 对象本身 | 改为只读不订阅 |

### 1.4 ChatPage

文件：`lib/ui/ai_pages.dart`

1. **派生结果缓存。** messages、proposalOwners、batches、batchOwners、unlinked、actions 统一缓存，键为 `identical(store.data)`、`activeSessionId`、`liveMessage?['id']`。运行时状态变化直接复用缓存。
2. **消息 Widget 列表随派生结果一起缓存。** 同一组实例交给 `_LazyChatList`，状态变化时可见行在 Element 层被短路，不会重建。
3. **页面仍订阅运行时变化**（`liveMessage`、`error`、`busy` 依赖它），但有了第 1、2 点，每次运行时变化的成本只剩重建少量组件。页面的数据域订阅收敛为 `{conversations, tasks, memory, preferences}`。
4. **`_Message` 与 `_AssistantContent`。** `_Message` 头部的顾问名称只订阅 `memory`；`_AssistantContent` 去掉 `AppScope.of`，其中依赖 `busy` 的重试按钮改用 `RuntimeBuilder`。

### 1.5 派生数据缓存

文件：`lib/data/wallet_store.dart`、`lib/services/agent_actions.dart`

- `query()` 不带任何筛选时，直接返回 `UnmodifiableListView(_ordered)`，不再复制全表。执行前确认调用方都不修改返回列表。
- `total` / `breakdown` 按 `(type, range.start, range.end)` 缓存，`suggestions` 按（快照，当天）缓存，统一在 `_checkDerivedData` 中失效。
- 新增 `category(name, type)` 索引。
- `AgentActions.items` / `batches` 按 `store.data` 引用缓存，与 `review()` 共用同一个失效点。
- propose 工具结果中的 `proposalId` 解析结果，用 `Expando` 按消息 Map 缓存。第 2 步完成后，未改动的消息引用保持稳定，这个缓存可以跨提交命中。

### 验证

- 在 `chat_performance_test.dart` 中补一个用例：依次访问首页、统计、账单后进入 ChatPage，执行一次 `changeMetadata(chats.add)` 和一次 `setAiStatus`。断言 `HomePage`、`StatsPage`、`BillsPage` 重建 0 次；状态变化时 `_Message` 重建 0 次。
- 运行 `chat_performance_test`、`page_performance_test`、`navigation_test`。订阅改动面广，最后再跑一次全量测试。

## 第 2 步：写入链路去掉 UI 线程上的全量操作（不改存储格式）

目标：`change` / `changeMetadata` 在 UI 线程上只做 O(改动) 的工作。

### 2.1 写时复制 JSON 视图

新文件：`lib/domain/cow_json.dart`

- **`FrozenMap` / `FrozenList`。** 不可变视图类，替代 `Map.unmodifiable` / `List.unmodifiable`，通过 `is FrozenMap` 在 O(1) 内识别已冻结的子树。对它们写入仍会抛错，已提交数据的保护不变。
- **`CowMap` / `CowList`。** 包装 Frozen 容器，读取直接穿透到原数据：
  - 首次写入，或首次读取子容器时，才浅复制本层，成本只与本层大小有关。
  - 读出的子容器替换成同样的包装并留在槽位里，保证重复读取拿到同一个对象。
  - 调用方赋入的普通值原样保存。
- **`materialize()` 物化规则。**
  - 槽位是包装：递归物化。
  - 槽位仍是原来的 Frozen 值：直接复用。
  - 槽位是普通值：与原位置的旧值做结构比较后冻结，内容相同的子树复用旧引用。
  - 本层所有槽位都与原值相同（标量用 `==` 比较）：返回原对象。
  - 效果：写入相同的值不产生新对象，只有改动路径上的容器换新。
- **统一冻结入口 `freezeValue`。** 遇到包装就物化，遇到 Frozen 值原样返回，遇到普通容器递归冻结。`freezeMetadata` 改用它，已冻结的字段只需 O(1)。
- **必须覆盖的写法**（代码中都已存在）：
  - 嵌套原地修改，例如 `_saveRun` 中的 `task['state'] = ...`、`recoverInterrupted` 中的 `m['status'] = ...`
  - 对包装调用 `Json.from(...)`，修改副本后整体赋回，例如 `d.extras['tasks'] = list`
  - `removeWhere` / `insert` / `sort` / `remove` / `clear`
  - 同一个包装被放到另一个位置（别名）

### 2.2 模型与提交顺序

文件：`lib/domain/models.dart`、`lib/data/ledger_changes.dart`、`lib/data/wallet_store.dart`

- 新增 `WalletMetadata.draftMetadata()`：把顶层字段换成 Cow 包装，成本 O(字段数)。用它替换 `LedgerChangeSet.draft` 和 `changeMetadata` 中的 `cloneMetadata()`。
- `clone()`：数据已冻结时，元数据使用 Cow 包装，`AgentActions` 中 6 处 `d.clone()` 随之降为只复制列表指针；数据未冻结时保留原来的深拷贝。
- `_commit` 的新顺序：prepare → 物化元数据（UI 线程，O(改动)）→ 判断财务变化 → 落盘 → `_publish`。
  - 财务列表的冻结时机不变，仍在 `_publish` 中进行：`LedgerChangeSet.from` 依赖列表是 `LedgerList` 类型来判断改动。
- `LedgerChangeSet.from` 不再调用 `cloneMetadata()`：元数据已冻结，可以直接共享。

### 2.3 `_publish` 改为按引用判断变化

| 域 | 比较对象 |
| --- | --- |
| ledger | 现有 `_financialChange` 逻辑；其中 goals 改为引用比较 |
| conversations | `chats`，以及 extras 中的 `chatSessions` / `activeChatSessionId` / `chatDrafts` |
| preferences | `settings`、`profile`、`providerConfigs` |
| memory | `agent` |
| tasks | extras 中的 `tasks` / `agentActions` / `agentActionBatches` |
| sources | extras 中的 `paymentNotifications` / `paymentReminderSeen` |

结构共享保证“内容没变 = 引用相同”。调用方重建了一份内容相同的列表时，结构比较也会复用旧引用，不会多发通知。`jsonEquals` 只保留给非热点路径使用。

### 2.4 合并 AI 回复中的写入

文件：`lib/services/ai_service.dart`、`lib/agent/task_runtime.dart`、`lib/services/agent_actions.dart`

- `tasks.start` 与写入用户消息合并为一次 `changeMetadata`。`TaskRuntime` 提供一个在给定 draft 上执行的静态方法，供合并调用。
- 逐个批次执行的 `actions.setGeneration` 循环合并为一次写入。
- `tasks.consume` 的轮次和工具调用计数改为先在内存中累加，上限也在内存中检查，然后随本轮 `_saveRun` 或 `checkpoint` 一起写入。
  - 代价：应用崩溃时最多丢失一轮计数，上限因此最多放宽一轮。需在代码注释中注明。
- `WalletStore.execute` 不再对 `operationReceipts` 逐条 `Json.from` 复制全表，改为直接在包装上查找并 `add`。
- 预期：一次 2 轮、3 个工具的回复，提交次数从约 12 次降到 4-5 次，以测试计数为准。

### 验证

- 新增 `test/cow_json_test.dart`，只写最少用例：
  - 未改动时返回原引用
  - 嵌套写入只替换路径上的容器
  - 写入相同值后引用不变
  - `Json.from` 后整体赋回时复用未变的子树
  - `insert` / `removeWhere` / `sort`
  - 别名
- 回归 `chat_performance_test` 中的域通知用例，以及 `sqlite_storage_test`、`wallet_snapshot_test`、agent 系列测试。
- 跑一次全量 `flutter test`。
- 用第 0 节的元数据基准对比改动前后。

## 第 3 步：常驻存储 worker 与行级增量协议（存储格式不变）

### 3.1 常驻 worker

新文件：`lib/data/sqlite_worker.dart`

- **生命周期。** 首次使用时 `Isolate.spawn`，所有 `LocalWalletStorage` 实例共享同一个 worker。
- **通信。** 通过 SendPort 发请求、收应答，用请求 id 对应。worker 内按顺序执行，保持现有的串行语义。
- **错误传递。** 同一 isolate group 内可以直接发送异常对象（`FormatException`、`StateError`、`UnsupportedError`、`SqliteException`），UI 侧原样抛出，现有测试对异常类型的断言不受影响。
- **异常退出。** worker 意外退出（onError / onExit）时，让所有挂起请求失败，下次请求时重建 worker。单个请求设 30 秒超时。
- **连接策略。**
  - 基线：每个请求打开一次连接，但建表、建索引、PRAGMA 对每个数据库路径只做一次，由 worker 记录已初始化的路径。
  - 暂不保持长连接：Windows 下测试在 tearDown 中删除临时目录，未关闭的数据库文件会让删除失败。
  - 如果测量显示打开连接的成本明显，再加空闲超时关闭和显式 `close()`。
- **覆盖范围。** load、commit、query、restore 全部改走 worker，替换现有的 `compute` 调用。

### 3.2 行级增量协议

文件：`lib/data/storage_sqlite.dart`、`lib/data/storage_base.dart`

- **行模型不变。** bucket / id / kind / position / body / checksum 与现有 `_rows()` 完全一致。行 key 的生成规则提取为 UI 侧和 worker 共用的函数。
- **UI 侧按引用生成元数据增量。**
  - 顶层容器（goals、chats、profile、settings、agent、providerConfigs、extras，以及其中的列表型子桶）引用相同：整桶跳过。
  - 引用不同：逐行比较引用，产出三类内容：upserts（新增行或值有变化的行）、deletes，以及被触及列表桶的有序 id 列表（worker 计算排名稳定性时需要）。
- **财务记录**沿用 `LedgerChangeSet` 的 before / after 和 moved id。
- **worker 在同一事务内完成：**
  - revision / generation 检查
  - 财务行校验（沿用现有逻辑）
  - 读取被触及桶的位置，计算排名
  - 只对变化行做 JSON 编码和 sha256 校验和，然后写入
- **跨 isolate 只传变化值。** 例如 AI 一轮保存只传一条消息和该会话桶的 id 列表，切换设置只传一行。
- **兼容性。** `lastChangedRows` / `lastScannedRows` 的语义保持不变，`sqlite_storage_test`、`ai_native_test` 依赖这两个值。
- **低频路径不改。** `commitSnapshot`（显式重排）和 `replaceSnapshot`（恢复、迁移）继续传整份数据。

### 验证

- 运行 `sqlite_storage_test`（全部）、`ai_native_test` 中的万行用例、`storage_test`、`wallet_snapshot_test`，再跑全量测试。
- 用 `tool/benchmarks/sqlite_save_benchmark_test.dart` 对比改动前后。

## 第 4 步：存储结构调整

### 4.1 主库 WAL 与异步镜像（已确认采用）

**存储版本**

- `user_version` 从 1 升到 2。旧版应用遇到 2 时会按现有逻辑拒绝打开并提示更新，不会因镜像不一致而误判。
- 不支持降级。发布说明须写明，OTA 回退时也要注意。

**主库**

- `journal_mode=WAL`，`synchronous=FULL`。每次提交只需要对 WAL 做一次 fsync，提交后仍然立即持久化。
- 普通提交不再 ATTACH 镜像库。

**生成镜像**

1. worker 执行 `VACUUM INTO '<db>.bak.tmp-<时间戳>'`，得到一份一致的快照。
2. 写完后用 rename 覆盖 `.bak`，替换是原子的。
3. 如果现有 `.bak` 的 revision 已不低于本次快照，就放弃替换，避免多进程、多实例竞争时把镜像换成更旧的版本。

执行前确认应用打包的 SQLite 版本不低于 3.27（`VACUUM INTO` 从 3.27 起支持）。

**同步时机**

- 提交后空闲 3 秒执行（去抖）。
- 应用进入 paused / hidden 时立即同步：`_FinDashAppState` 增加 `AppLifecycleListener`，调用新增的 `store.flushMirror()`。
- 恢复备份、旧 JSON 迁移、损坏修复完成后，先同步镜像，再报告成功。

**同步失败**

- 不回滚已提交的数据。记录日志，在下一次提交或回到前台时重试。
- 可选：连续失败时，在设置页“数据管理”中显示提示。

**启动流程**

1. 主库通过 `quick_check` 和校验和检查：直接使用。镜像只检查 generation 一致、revision 不高于主库；落后就安排一次同步。不再做两库的 EXCEPT 全量对比，启动也会更快。
2. 主库损坏：把主库连同 `-wal` / `-shm` 一起改名为 `.damaged-<时间戳>`，校验镜像，复制为新主库并启用 WAL。
   - 如果镜像的 revision 落后，向用户提示：已从恢复副本恢复，副本之后的修改可能丢失，可以从恢复点或备份恢复。这是非致命提示，不设置 `startupError`。
3. 主库和镜像都损坏：保持现有的 `startupError` 流程。

**旧实例拒写**

- `BEGIN IMMEDIATE` 内的 revision / generation 检查保留，改在主库上进行。
- WAL 的 `-shm` 支持同一应用的多个进程（例如桌面小部件引擎）同时访问。

**从旧版本升级**

- 首次以新版本打开时，主库为 `user_version` 1，且按现有逻辑与镜像一致。只需设置 WAL 和 `user_version` 2，不搬迁数据。

**需要改写的测试**（`test/sqlite_storage_test.dart`）

| 现有用例 | 改为 |
| --- | --- |
| 副本写入失败时回滚主库和内存 | 镜像同步失败不影响已提交的数据，之后重试成功 |
| 关闭未提交的 ATTACH 事务后两库恢复 | 未提交的 WAL 事务在重新打开后被丢弃 |
| 物理损坏时恢复最新副本 | 先显式同步镜像，再制造损坏；另加一个用例：镜像落后时能恢复，并给出可能丢失的提示 |
| 未来 schema 不会被静默降级 | 改用 `user_version` 3 |

**需要更新的文档**

- `Agent.md`“数据与迁移”一节中关于副本的规则
- `docs/performance-audit.md` 中“不采用 WAL”的段落
- Release Notes：说明镜像改为异步、不支持降级

### 4.2 聊天压缩（已确认采用“压缩冗余 + 留存上限”）

- **新写入只保留当前协议需要的回放副本。** chat 协议只存 `modelMessages`，responses 协议只存 `responseItems`。回放时本来就只使用与当前协议一致的那份。
- **压缩回放窗口外的消息。**
  - 每次 `_saveRun` 时，找出同一会话中不在最近 15 个用户轮次内（`ContextAssembler.maxTurns`）、且 status 为 complete 的消息，去掉它们的 `modelMessages` / `responseItems`。
  - 回放逻辑在缺少这两项时，本就会退回 `_historyText`，读取端不用改。
  - status 为 error / cancelled 的消息保留不动，以免影响 `retryMessage` 的断点续跑。
- **截断窗口外的长工具结果。**
  - 窗口外消息中，非 `propose_` 工具的结果超过 8KB 时截断为预览，并标记 `resultTruncated`。
  - `propose_` 工具先把 `proposalId` 提到 block 字段上；`_proposalIds` 和 `_allBatches` 优先读这个字段。
- **存量数据。** 新版本首次启动后，在空闲时执行一次全量压缩（单次 `changeMetadata`），之后随写入增量进行。
- **备份格式不变。** 这些字段本来就是可选的。

### 4.3 留存上限

以下为默认值，执行时可以调整。

| 数据 | 现状 | 上限 |
| --- | --- | --- |
| `extras.operationReceipts` | 无上限，每次 `execute` 线性扫描 | 只保留 30 天内的记录，且最多 1,000 条。幂等只需要覆盖短时间内的重试 |
| `extras.tasks` | 无上限 | 进行中的全部保留；已结束的保留最近 200 条 |
| `extras.agentActions` / `agentActionBatches` | 只限制待确认数量（2,000） | 待确认的全部保留；已处理的保留最近 500 条。撤销入口只对保留下来的记录显示 |
| `chats` | 保留 365 天 | 不变 |

修剪放在各自写入点的同一事务内，不单独做迁移。首次启动时随 4.2 的全量压缩一起执行一次。

### 验证

- 运行改写后的 `sqlite_storage_test`（全部），以及迁移相关用例：旧 JSON 迁移、迁移中断后重试、两个实例首次打开、旧实例拒写。
- 运行 `backup_test`、`ai_streaming_test` 和 agent 系列测试，确认压缩后回放和重试正常。
- 跑全量测试。
- 用基准对比提交耗时；在真机上复测 S6（保存到页面关闭）。

## 第 5 步：渲染层

文件：`lib/main.dart`、`lib/ui/design.dart`、`lib/ui/finance_pages.dart`、`lib/ui/ai_pages.dart`

- **5.1 Tab 切换。** 去掉包住 `IndexedStack` 的 `FadeTransition`，只保留首帧后开始计时的 `SlideTransition`（位移 .018，不产生离屏层）。`navigation_test` 中对 `main-tab-transition` 的 `FadeTransition` 断言，改为检查 `SlideTransition`。
- **5.2 首访预构建。** 首页首帧完成后，在空闲时（`SchedulerBinding.scheduleTask` 配合 `Priority.idle`，或延后 1 秒）逐帧依次把统计、账单、我的加入 `_visited`。依赖第 1 步，否则这些后台页会被 AI 写入反复触发重建。
- **5.3 背景层。** `MaterialApp` builder 里的 `WalletBackdrop` 总是被每个路由自带的 `WalletBackdrop` 覆盖，属于纯重复绘制。改为纯色 `ColoredBox`；宽屏（宽度超过 960）时两侧区域仍需要渐变，只在宽屏时绘制。
- **5.4 首页入场动画。** 现在约 10 个分区各自带一个 `FadeTransition`，每个都是离屏层。改为整页一个 `FadeTransition`，各分区只做错峰位移。`navigation_test` 中的 `overviewFade` 断言相应调整。
- **5.5 底部玻璃导航。** 按 `Agent.md` 的视觉约定保留模糊。5.1、5.4 完成后，它不再与全屏透明度层叠加。除非真机 raster 帧仍然超标，否则不调整模糊参数。
- **5.6 聊天。**
  - 用 `SelectionArea` 包住消息列表，`MarkdownBody` 改为 `selectable: false`。
  - 用户消息和错误文本由 `SelectableText` 改为 `Text`，在 `SelectionArea` 内仍可选择、复制。
  - `_LazyChatList` 设置约 1.5 屏的 `cacheExtent`，减少回看时重新解析 Markdown。
  - 需要在真机上确认长按选择、跨段落选择和复制都正常。

### 验证

- 运行 `navigation_test`、`home_first_screen_test`（首屏可见性约定）、`theme_test`、`chat_performance_test`。
- 在真机上复测 S1、S2、S5，与基线对比。
- 确认 `Agent.md` 视觉约定仍满足：竖屏首页初始位置下，“AI 顾问”和“语音记账”完整显示在导航上方且可以点击。

## 版本与交付

- 每步完成后单独提交，按 `Agent.md` 递增修订号，并更新 `CHANGELOG.md`。
- 第 4 步包含存储版本变更，递增次版本号（0.7.0）。如果 1-5 合并为一次交付，整体版本为 0.7.0。
- 默认只交付源码，不打包。
- Release Notes 须注明：第 4 步之后不支持降级到旧版本；恢复副本改为异步同步。

## 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| Cow 视图漏掉某种写法 | 修改丢失，或未提交的修改泄漏 | `cow_json_test` 覆盖代码中已有的写法；物化后 `store.data` 仍是不可变对象，误写会立即抛错；全量测试 |
| 按引用判断漏发域通知 | 页面不刷新 | 结构比较保证内容有变化时引用必然换新；`chat_performance_test` 的域通知用例 |
| worker 崩溃或挂起 | 保存没有响应 | onError / onExit 时让挂起请求失败并重建 worker；请求设 30 秒超时 |
| WAL 下镜像落后 | 主库物理损坏时丢失最近的修改 | 空闲 3 秒同步，退到后台立即同步；恢复时明确提示 |
| 旧版本打开新数据库 | 无法启动 | `user_version` 2 让旧版明确提示更新；发布说明写明 |
| 合并 AI 计数写入 | 崩溃后上限最多放宽一轮 | 代码注释注明；上限仍在内存中强制执行 |

## 不在本计划内

- 聊天独立存储、按会话懒加载（本次已选择不做）。
- 启动时全量加载与数据库分页查询。
- Web 端存储：继续使用原有后端，不宣称具备原生 SQLite 或 isolate 性能。
