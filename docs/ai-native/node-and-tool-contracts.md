# 节点、能力与交互协议

设计版本 1.0 · 2026-10-03。**目标合同，尚未全部实现。** 产品规则见[总架构](../ai-native-architecture.md)，实施门槛见[实施与验收](implementation-and-validation.md)。

本协议优先解决任务可恢复、数据口径一致、用户少重复操作。采用静态 Dart 类型与有界解释器，不引入通用工作流平台。

## 1. 标识、上下文与数据结果

### 标识职责

| 字段 | 含义与生命周期 |
| --- | --- |
| walletId / ledgerEpoch | 账本身份 / 恢复或替换账本后变化的世代；旧计划、游标、授权随世代失效 |
| taskId | 一次用户目标；跨页面、消息与重试稳定，由应用生成 |
| sessionId / messageId | 聊天归属与来源；任务可没有聊天，不以 messageId 充当 taskId |
| requestId / attemptId | 一次模型请求 / 一次节点尝试；取消和网络重试使用 |
| operationId | 一次预期业务效果的幂等键；重试保留，参数变更不能沿用 |
| planId / planRevision | 方案身份与内容版本；修改、排除、依赖变化递增 |
| interactionId / revision | 一次补充或批准请求；防止旧卡、重复提交、跨任务响应 |
| receiptId | 真实提交回执；与业务变更同事务落盘 |
| sourceRef / evidenceRef | 文件、通知、用户原话、查询结果的引用；来源原文不重复保存 |

自然语言“把刚才那项改成…”通过当前任务和有效计划关联；找不到唯一任务才询问，不默认创建新任务。

### TaskContext（应用构造，模型不能覆盖）

~~~json
{
  "taskId": "task_example",
  "walletId": "local",
  "ledgerEpoch": "epoch_example",
  "source": {"kind": "billsPage", "selectedIds": ["tx_example"]},
  "scope": {
    "startInclusive": "2026-09-01T00:00:00+08:00",
    "endExclusive": "2026-10-01T00:00:00+08:00",
    "timezone": "Asia/Shanghai",
    "currency": "CNY"
  },
  "surface": {"kind": "chat", "supportsCards": true},
  "verbosity": "normal",
  "versions": {
    "appSpec": "1",
    "capabilities": "1",
    "prompt": "1",
    "ledger": 42
  }
}
~~~

上述值仅为示例。时间由运行环境注入，不在提示词写死。页面选择只是任务初始范围，不自动授予修改权限。模型只可请求调整范围，由应用按用户意图和允许范围处理。

### QueryResult

~~~json
{
  "ok": true,
  "data": {"expenseCents": 123400, "transactionCount": 26},
  "scope": {
    "startInclusive": "2026-09-01T00:00:00+08:00",
    "endExclusive": "2026-10-01T00:00:00+08:00",
    "timezone": "Asia/Shanghai",
    "currency": "CNY",
    "metric": "expenseGross"
  },
  "snapshot": {"ledgerEpoch": "epoch_example", "revision": 42},
  "coverage": {
    "status": "complete",
    "matchedRows": 26,
    "returnedRows": 1,
    "sourceCoverage": "recordedLedgerOnly"
  },
  "asOf": "2026-10-03T10:00:00+08:00",
  "nextCursor": null,
  "evidenceRef": "result_example"
}
~~~

约束：

- complete 表示覆盖指定范围内的已记录账本，不代表掌握用户全部真实财务。
- partial 必须给原因与可继续查询方式；预算耗尽不能返回无标记的部分 sum。
- 分页明细的 returnedRows 与 matchedRows 不同，aggregate 另外标记其 coverage。
- snapshot 是账本及相关域的逻辑版本。多次调用要组合分析时保持同版；无法继续旧版本就返回 SNAPSHOT_EXPIRED 并重新整体查询。
- 当前余额不能自动回答“上月底余额”。只有实现且定义历史余额口径的查询才能提供该数字；回补历史与校正期初余额会影响可解释性。
- 新能力只返回分字段金额；旧工具兼容元字段时显式标记单位，由适配器承担转换。
- 结果默认返回必要字段，备注、附件、记忆按需投影；密钥、签名配置和原始数据库路径不在数据集内。

## 2. 能力注册表

一个 CapabilityDefinition 同时生成模型工具 schema、运行时路由、说明和测试清单。内部 ID 可用点分名；对供应商输出使用兼容的函数名（如 ledger_query），双向映射由注册表维护，不交给模型猜测。

建议合同（Dart 类型草图，不是当前编译接口）：

~~~text
CapabilityDefinition<Input, Output>
  id, version, description, userLabel
  inputSchema, outputSchema
  effect: read | prepare | preferenceWrite | ledgerCommit | external
  scopeResolver(Input, TrustedContext) -> EffectiveScope
  validate(Input) -> ValidatedInput
  execute(ValidatedInput, CapabilityContext) -> Output
  authorizationPolicy
  limits, freshnessPolicy, invalidationDomains
~~~

注册表传入的上下文只能暴露该 effect 所需的接口。例如读取能力只有 QueryRepository，prepare 只有 ProposalRepository；不能都注入完整 WalletStore 再靠自觉限制。

### 核心能力目录

| 能力 ID | effect | 模型是否可调用 | 用途 |
| --- | --- | --- | --- |
| app.describe | read | 是 | 应用语义、功能支持、指标解释、限制 |
| capabilities.search | read | 是 | 搜索允许范围内的能力及 schema |
| ledger.query / ledger.aggregate | read | 是 | 分页明细 / 全范围整数分汇总 |
| accounts.overview / categories.list | read | 是 | 账户、分类与稳定 ID |
| tasks.get / plans.get | read | 是，限有效范围 | 查询真实任务、方案、回执 |
| plans.prepare / plans.revise | prepare | 是 | 准备和修正同一方案 |
| interaction.request | prepare | 是 | 请求缺失字段或选择；不能创建真实授权 |
| recipes.validate / recipes.run | read | 是 | 校验与运行模型编写的查询程序 |
| memory.search | read | 是，受隐私范围约束 | 检索稳定事实与偏好 |
| memory.proposeChange | prepare | 是 | 准备需要持久化的记忆改动 |
| preferences.applyExplicitRequest | preferenceWrite | 仅有应用签发的对应用户事件时 | 明确的“记住 / 忘记”操作 |
| ledger.commitPlan / ledger.undoReceipt | ledgerCommit | 否 | 原生交互控制器执行、撤销 |
| maintenance.unlock / restore | ledgerCommit | 否 | 明确的维护流程 |
| export.create / share | external | 默认否 | 文件生成与外部分享，单独策略 |

查询、草稿和财务执行不混用同一个“任意操作”工具。授权策略覆盖记忆、目标、预算和配置，不能把非交易数据当作无权限要求的数据。

现有 get_app_settings、query_tx、propose_changes、revise_changes 等保留兼容适配器。外部旧名称映射到新能力；先双向契约测试，再淘汰旧 switch。新增能力不再要求修改 AiService 的分派代码。

### 校验和权限顺序

1. 解析工具名和参数；拒绝未知工具、未知字段、非法类型、超长文本与超限数组。
2. 由宿主合成 taskId、walletId、权限范围、请求 ID；模型同名字段不能覆盖。
3. 检查当前锁定状态、可用能力、用户数据范围和任务状态。
4. 能力处理器进行领域校验；写入在串行提交时再检查一次最新状态。
5. 返回带类型的结果 / 错误，由运行时决定后续路由。

记忆中的句子、附件文字和模型自报“用户已经同意”不能制造 TrustedUserEvent。对无法确定是否具有明确长期保存意图的自然语言，先形成轻量记忆卡；不以另一个模型的 intent=true 作为强授权凭证。

首版 TrustedUserEvent 来自实际原生按钮 / 表单动作，或应用能无歧义识别的有限显式命令（例如“记住：”后面的原文）；将原始内容、允许效果与事件绑定。普通聊天语义无法由宿主明确识别时，由模型准备记忆改动卡，用户一键采用。不能把任意一条真实用户消息都签成任意记忆操作的授权。删除、扩大范围或替换已有事实需要对应事件，不能复用“保存一条偏好”的事件。

## 3. AI 自编工具：QueryRecipe v1

目标是让模型能创造新的数据查询组合，而非只能选择固定报表。实现为受约束的声明式程序：模型编写、宿主检查、本地执行、按需复用。

### 生命周期

1. app.describe / capabilities.search 获得真实字段、指标、允许数据集和语言版本。
2. 模型构造 QueryRecipe，声明参数与输出。
3. recipes.validate 做类型、范围、代价和权限检查，返回短期 recipeId、内容 digest、输出 schema、依赖与诊断。
4. recipes.run 使用 recipeId 和参数；执行前重新检查范围、版本与权限。
5. 会话内可反复运行同一 recipeId。默认不长期保存，模型不能修改通用能力目录。
6. 用户选择“保存为常用分析”才保存程序；重新运行时重新验证，不把一次校验永久当作授权。

recipeId 在首次版本仅由 recipes.run 分派，无须每次给模型动态添加新的函数定义。后续如果暴露语义名称，也仅是同一验证过的程序别名。

### 最小语法与类型

程序格式：languageVersion、name、description、parameters、steps、output。steps 形成有序无环引用，每步只引用前面的输出。

首版数据集目录如下；app.describe 返回实际可用字段与类型，迁移未完成时不得提前开放目标字段。

| 数据集 | 最小目标字段 | 范围 |
| --- | --- | --- |
| ledger.transactions | id、type、amountCents、currency、occurredAt、timePrecision、accountId、transferFromId、transferToId、categoryId、sourceType、sourceId、originalTransactionId | 当前授权账本与任务范围；note 按需投影 |
| ledger.accounts | id、name、category、openingBalanceCents、balanceCents、archived、includeInTotal | balanceCents 由宿主按同一快照计算，不是第二份权威余额 |
| ledger.categories | id、name、type | 分类只读目录 |
| ledger.budgets | id、period、amountCents、currency | 明确的预算范围，不当作余额 |
| sources.index | sourceRef、type、capturedAt、availability | 仅任务相关来源索引；原文通过单独受控能力读取 |

任务、聊天、记忆使用各自受控能力，不开放任意 scan 所有私密历史。旧字段名由兼容适配器映射；程序只能使用实际 schema 中的规范字段。

| 算子 | 输入 → 输出 | 语义 |
| --- | --- | --- |
| scan | dataset + fields + where → RowSet | 通过 QueryRepository 读取授权数据，不直接访问文件或 SQL |
| filter | RowSet + predicate → RowSet | 允许 eq/ne/in/inRange/lt/lte/gt/gte/isNull/contains 与 and/or |
| calendar | RowSet + 日期字段 + timezone + components → RowSet | 增加 weekday、localHour、day、month 等类型化字段 |
| group | RowSet + keys + aggregates → RowSet | count、sumCents、minCents、maxCents；整范围计算 |
| derive | RowSet + 结构化算术树 → RowSet | 分数、差值、占比；无任意字符串表达式 |
| compare | 两个聚合 RowSet + keys → RowSet | 绝对差、分母明确的变化率；缺失与零分母区分 |
| sort / take | RowSet → RowSet | 稳定排序、展示截取；take 不能改变此前 aggregate 的口径 |
| project | RowSet + fields → RowSet | 输出必要字段与证据引用 |

基础类型：String、Bool、ID、Int、Cents、Instant、LocalDate、TimeRange、DecimalString、RowSet。参数只支持有限的标量、数组与这些领域类型；不执行任意用户 JSON Schema 扩展。

时间计算通过统一 TimePolicy。首版至少支持实际设备时区及 UTC，capability manifest 明确列出支持范围；任意 IANA 时区未实现时返回不支持，不能只替换标签。日期边界由同一实现生成和测试，包含跨月、闰日及适用时区的夏令时。日期精度来自来源事实，不能由记录看起来包含秒就推断来源提供了精确购买时刻。

金额聚合检查溢出，不能自动改成浮点数。平均数和比例输出带 scale、单位与舍入说明的十进制字符串，分母为零返回 null 与原因。Web 数值超出安全整数范围时拒绝或使用经测试的精确实现。

v1 不开放任意 join。账户名称、分类、原退款关联等只通过宿主预定义关系投影，避免任意连接导致重复计数和组合爆炸。需要新的关系由代码新增算子与覆盖测试。

### 示例：按月份比较工作日午间餐饮记录

这份程序统计“餐饮分类 + 工作日 + 11:00–14:00”的记录，不能无证据把它命名为真实午餐。categoryIds 必须来自 categories.list；时间精度不足的记录单独计数并说明。

~~~json
{
  "languageVersion": 1,
  "name": "weekday_midday_food_by_month",
  "description": "按月份汇总工作日午间的餐饮记录",
  "parameters": {
    "range": {"type": "TimeRange", "required": true},
    "categoryIds": {"type": "Array<ID>", "required": true},
    "timezone": {"type": "String", "required": true}
  },
  "steps": [
    {
      "id": "rows",
      "op": "scan",
      "dataset": "ledger.transactions",
      "fields": ["id", "occurredAt", "timePrecision", "amountCents"],
      "where": {
        "and": [
          {"field": "type", "eq": {"literal": "expense"}},
          {"field": "occurredAt", "inRange": {"param": "range"}},
          {"field": "categoryId", "in": {"param": "categoryIds"}},
          {"field": "timePrecision", "in": {"literal": ["minute", "second"]}}
        ]
      }
    },
    {
      "id": "calendar",
      "op": "calendar",
      "from": "rows",
      "field": "occurredAt",
      "timezone": {"param": "timezone"},
      "components": ["weekday", "localHour", "month"]
    },
    {
      "id": "midday",
      "op": "filter",
      "from": "calendar",
      "where": {
        "and": [
          {"field": "weekday", "in": {"literal": [1, 2, 3, 4, 5]}},
          {"field": "localHour", "gte": {"literal": 11}},
          {"field": "localHour", "lt": {"literal": 14}}
        ]
      }
    },
    {
      "id": "monthly",
      "op": "group",
      "from": "midday",
      "keys": ["month"],
      "aggregates": {
        "totalCents": {"sumCents": "amountCents"},
        "count": {"count": "*"}
      }
    },
    {"id": "ordered", "op": "sort", "from": "monthly", "by": [{"field": "month", "direction": "asc"}]}
  ],
  "output": {"from": "ordered", "fields": ["month", "totalCents", "count"]}
}
~~~

TimeRange 的 inRange 固定为 startInclusive/endExclusive。weekday 为 ISO 周一=1 至周日=7。timePrecision 为 day/minute/second/unknown；这里筛除不足分钟精度的记录是查询条件，必须在结果 limitations 中显式记录；若未知数量影响结论，可另一次查询统计这些记录，不能从“没返回”推断不存在。

语法约束：值节点必须且只能是 {literal: value} 或 {param: name}；predicate 为 {field, operator: valueNode} 或 {and: predicates}/{or: predicates}；算术树为 {op: add/subtract/multiply/divide, args: valueOrFieldNodes}，字段引用使用 {field: name}。不得使用字符串表达式。count 仅允许 *，sumCents 仅接受 Cents 字段；sort 的 direction 为 asc/desc。每个算子拒绝不属于该算子的字段，output 必须引用已有步骤及真实输出字段。compare 固定输出 left/right/delta/ratio，并显式区分缺项与零值。实现时从这些规则定义 sealed Dart AST 与 schema，不增加未写入合同的隐式 coercion。

### 执行预算（起始默认值，测量后调整）

- 最多 24 步、表达式深度 8、单次扫描上限 50,000 行、输出最多 200 行和 64 KiB。
- 每个任务执行段最多 12 个模型轮次、40 次能力调用、3 次程序修复尝试；预算跨自动重试累计，不能通过 retry 无限重置。用户明确选择继续才可开始新的有界执行段，保留 taskId 和累计成本记录。
- 一次程序本地执行预算 2 秒，取消应在算子边界 / 分页边界及时生效；阻塞数据库查询须有中断或进度机制，不能只包一层 Future.timeout 后放任继续运行。
- 聚合涉及更多数据时，可由有索引的宿主聚合执行器完整计算并报告真实成本；超过当前执行器预算返回 LIMIT_EXCEEDED，要求缩小范围或选择受支持的汇总。
- 禁止循环、递归、任意 UDF、eval、动态 import、shell、PRAGMA、ATTACH、网络、文件读写和写账能力。
- 保存后权限不固化；锁定、恢复账本、能力升级、字段变更均使运行前校验重新执行。

## 4. 节点框架与任务状态机

### 持久化 Task

Task 保存 taskId、目标、来源引用、允许范围、ledgerEpoch、state、当前 checkpoint、有效 planId、pendingInteractionId、有限的尝试计数与错误信息。正文方案、附件和查询结果通过引用关联，不在每个节点保存整本账本。

TaskState：preparing / needsInput / ready / applying / completed / interrupted / cancelled / failed。

~~~mermaid
stateDiagram-v2
  [*] --> preparing
  preparing --> needsInput: 关键字段缺失
  needsInput --> preparing: 有效用户响应
  preparing --> ready: 方案可审阅
  preparing --> completed: 只读结果完成
  ready --> preparing: 修改或相关版本变化
  ready --> applying: 原生确认事件核验成功
  applying --> completed: 原子提交成功且无剩余项
  applying --> ready: 部分已选项成功且仍有剩余项
  applying --> ready: 确定回滚并保留方案
  preparing --> interrupted: 取消请求或进程中断
  applying --> interrupted: 进程消失待回执对账
  interrupted --> preparing: 继续准备
  interrupted --> completed: 已查得完整提交回执
  interrupted --> ready: 回执对账后仍有待审阅项
  needsInput --> cancelled: 用户放弃任务
  ready --> cancelled: 用户放弃任务
  preparing --> failed: 不可恢复错误或预算耗尽
~~~

这是主路径，所有非终态均可按取消规则结束；状态变更由确定性 runtime 决定，不能照收模型返回的 state 字符串。

### Node 合同

~~~text
NodeInput:
  taskRef, checkpointRef, trustedContext, typedPayload, requestCancellation
NodeOutcome:
  Continue(nextNode, outputRef)
  NeedInput(interactionRef)
  Ready(planRef)
  Complete(resultRef)
  Interrupt(reason, checkpointRef)
  Fail(errorCode, retryable, recoveryOptions)
~~~

节点没有 BuildContext，不弹窗，不持有页面对象，不把模型推理文本当检查点。

| 节点 | 处理方式 | 输入 / 输出及失败行为 |
| --- | --- | --- |
| Receive | 确定性 | 绑定来源、用户输入、稳定 taskId；去重用户事件 |
| Context | 确定性 | AppSpec、能力、页面范围、版本、相关记忆引用；加载失败保留任务 |
| Decide | 必要时模型 | 请求查询 / 澄清 / 准备 / 回答；不决定是否已经授权或已写入 |
| Query | 确定性 | 能力查询或 QueryRecipe；版本与完整性可追溯 |
| Clarify | 模型组织问题，宿主校验 | 结构化缺项请求；保留已知字段，进入 needsInput |
| Prepare | 确定性 | 候选变更 → 领域校验 → 版本化 ReviewPlan；歧义项不默选 |
| AwaitUser | 确定性 | 持久化有效问题或方案，关闭模型流并释放资源 |
| Commit | 确定性 | 核验本地用户事件 → UnitOfWork → 回执；禁止模型直接调用 |
| Present | 确定性为主 | 查询卡、问题卡、回执；分析措辞可用模型，保存反馈无需模型 |

Receive → Context → Decide → Query → Decide 是有预算的循环。不是每次都要访问所有节点。手动表单直接进入应用命令；确定性查询也可直接呈现结果。不要实现“九个节点 = 九次模型请求”。

### 重试、取消与崩溃

- 每个有副作用的步骤先有稳定 operationId / payloadHash；执行记录与实际效果原子保存。网络 tool_call_id 只用于协议配对。
- 查询可重试；方案准备按 taskId、客户端项 key 和内容版本幂等；不同内容不能误当成重复成功。
- 新请求取消旧 requestId，旧响应不得发布或继续执行工具。用户切会话不会改变旧任务归属。
- 等用户时不占模型请求配额或数据库锁；应用重启恢复同一个 interactionId。
- 已开始的本地事务允许完成或回滚。取消模型不宣称已取消数据库提交。
- 恢复 applying 状态先按 operationId 查回执：已提交则恢复成功；确定无提交才返回 ready；账本不可读时停在 interrupted，不盲目重放。
- 确认、业务变更、相关来源状态和回执共事务保存。卡片渲染失败可重读回执，不重写交易。
- 工具执行成功但模型下一轮失败，不撤销真实结果，不重复执行；继续对话重放已保存的结果与原始 call 配对。
- “停止生成”通常是 interrupted；“放弃任务”是 cancelled，关闭未执行方案。已有回执仍有效；撤销需要独立用户动作。
- 批次部分执行后取消，只取消剩余待执行项，不改变已经执行的部分。

## 5. 用户交互是协议对象

### InteractionRequest

~~~json
{
  "interactionId": "interaction_example",
  "taskId": "task_example",
  "revision": 2,
  "kind": "clarify",
  "title": "这笔支出从哪个账户扣款？",
  "reason": "支付渠道不能唯一确定扣款账户。",
  "fields": [
    {
      "key": "accountId",
      "type": "accountChoice",
      "required": true,
      "options": [
        {"value": "account_bank", "label": "招商银行卡"},
        {"value": "account_cash", "label": "现金"}
      ]
    }
  ],
  "allowFreeText": true,
  "submitLabel": "继续准备",
  "cancelLabel": "暂不处理"
}
~~~

字段规则：最多 3 个密切相关的阻塞问题；选项来自真实数据与有效范围；模型不能塞不存在的账户。默认推荐只是视觉推荐，不自动提交。文本回复仍经字段解析和验证；含糊时保持 needsInput。

kind 为 clarify / choose / review。补字段可在当前页或聊天完成，响应都带 interactionId、revision、taskId 和应用生成的 eventId。离开页面不丢草稿。旧 revision 响应返回 STALE_INTERACTION，保留用户文字供重新应用。

review 卡必须关联 ReviewPlan；模型输出一个同形 JSON 不代表用户确认。没有卡片能力的界面提供纯文本问题；财务批准仍导航到宿主提供的明确确认入口。

### ReviewPlan 与授权

手动表单不必生成 AI 方案：原生 SaveAction 绑定当前字段摘要、目标记录版本和用户事件，应用命令验证该次保存意图后提交。以下 AuthorizationGrant 是模型或导入批量方案的批准合同；不能为了统一接口给每次人工保存额外加一张确认卡。

ReviewPlan 保存：

- planId、taskId、revision、ledgerEpoch、status、scope；
- itemId、稳定目标 ID 或任务内 key、操作类型、before / desired 的必要差异；
- 每项 readSet / expectedVersions、依赖项、来源引用、needsReview / reviewReason；
- 可确定的金额与余额影响、未准备范围、完整性状态。

planDigest 由规范化后的完整业务内容、依赖、范围、证据版本及策略版本计算。不要保存每次审阅的完整交易数组；账户余额校正使用可跟踪的相关账户交易版本 / 聚合版本来检测变动。

本地用户确认事件派生一次性 AuthorizationGrant，绑定：

~~~text
taskId, planId, planRevision, planDigest,
selectedItemIdsDigest, dependencyClosureDigest,
ledgerEpoch, relevantRecordVersions, policyVersion,
trustedUserEventId, operationId
~~~

grant 是应用内部类型或宿主持久化引用，不存在“模型传 approved=true”分支。确认当前 12 项不能授权后续增加的第 13 项。新增依赖也必须已展示并计入批准范围。

运行时校验后的同一点击已经是授权，无须二次口头确认。scope、金额、账户或选中范围变化时重新审阅；无关聊天变化不使财务授权失效。

### 呈现合同

UiBlock 支持 text、metric、table、chart、question、changePreview、receipt。模型可请求 metric / chart 的 evidenceRef 和字段，但数值、字段类型、行数、单位由宿主核验；复杂图形降级到表格或文字。

ProgressEvent 为 taskId、phase、completedUnits、totalUnits?、label。未知总量显示“正在处理”，不猜百分比；只展示对用户有用的进展，工具参数和推理摘要进入可选详情。不得生成或要求模型暴露私有思维过程。

成功回执由宿主文案生成，例如“已保存 12 笔，2 笔仍待核对。”；失败为“本次未保存，选择已保留，可重试。”。这些状态不得由自由生成文本取代。

## 6. 错误、观测与测试边界

统一 ErrorEnvelope：code、userMessage、retryable、phase、fieldErrors?、conflictRefs?、recoveryOptions。至少定义：

| code | 行为 |
| --- | --- |
| INVALID_INPUT / MISSING_FIELD | 保留字段，引导原位修正 |
| LOCKED / FORBIDDEN | 不执行，展示有效的解锁 / 范围入口 |
| STALE_PLAN / STALE_INTERACTION | 保留用户选择，重新审阅当前版本 |
| VERSION_CONFLICT | 指明受影响项，不覆盖最新数据 |
| LIMIT_EXCEEDED / SNAPSHOT_EXPIRED | 缩小范围或重查，不伪造完整结果 |
| STORAGE_FAILED | 回滚，无成功回执，允许原地重试 |
| MODEL_UNAVAILABLE / CAPABILITY_UNAVAILABLE | 保留任务，基础功能照常使用 |
| CANCELLED / INTERRUPTED | 明确已完成和未完成部分，按检查点恢复 |

结构化观测只记录 ID、节点、耗时、扫描与修改行数、复制载荷量、字节预算、重试次数、错误码、版本；不默认记录用户账单原文、密钥或附件。日志有容量与保留上限。

批准、幂等和事务原子性用确定性测试验证；模型理解与语言输出用提示词评测验证；Flutter / Android 生命周期与流畅度分别做 Widget 和真机验证。任何一类通过都不能替代另外两类。

