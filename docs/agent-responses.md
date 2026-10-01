# 自定义 OpenAI 接口与 Agent 对话

实现日期：2026-10-01。

## 配置与迁移

「我的 → AI 设置」只提供自定义 OpenAI 兼容接口，不再提供 GLM / 智谱、NVIDIA 预设，也不再自动生成智谱 JWT。API 密钥按 Bearer 原样发送。填写 Base URL、实际模型名称、API 密钥，再选择服务支持的 Responses 或 Chat Completions 协议。基础地址和完整端点地址都可填写；程序按所选协议统一端点后缀。

默认启用流式与工具调用。仅支持普通对话的模型可以关闭工具；不支持 SSE 的服务可以关闭流式。思考强度默认不传参数；Responses 的思考摘要需显式打开。图片能力仍需显式启用。

旧配置中明确保存的地址、模型、图片能力以及安全存储中的密钥可以继续读取，保存后切换到 custom 槽位。旧配置若只依赖被移除的供应商默认值，需要补全地址和模型，不会把旧服务密钥自动发送到 OpenAI 默认地址。密钥不会写入账本或备份；配置保存失败会尝试恢复原密钥。

「测试连接」使用当前表单发送简短探测，不读取账本、画像或记忆，也不写入聊天记录。连通不代表图片和工具能力已经验证。

## 对话执行

- `openai_transport.dart` 负责协议转换、增量 UTF-8/SSE 解析、普通 JSON 响应、思考摘要、函数调用参数分片、完成与失败事件。
- `ai_service.dart` 负责上下文、工具循环、取消、重试、记忆注入和持久化。一次请求最多连续运行 12 轮；完成的工具调用与结果配对保存。后续模型请求失败时，重试从已完成的工具轮次继续。
- `ai_pages.dart` 在正文旁只显示一行工具调用摘要；思考、参数、结果与用量统一放在可选的处理记录中，失败和停止状态仍在摘要中提示。仅展示 API 实际返回的思考或摘要，不推测未公开的模型推理。
- 账户、账单和预算的确认卡片直接显示在对话里，默认展示账户、金额、时间及关键变更，完整差异通过“查看详情”查看。点击确认、拒绝或撤销后，用户选择与本地执行结果和账本原子保存；失败保留待确认状态并在卡片内提示。重复提案只展示一张卡片，历史提案或中断后未关联消息的提案也能在对话中处理。操作管理页保留为辅助入口。
- Responses 使用 `store: false`，随输入重放 output items 与 function_call_output；保留推理条目的 encrypted_content 供同一接口与模型续接。工具 ID 使用 call_id，工具定义使用 Responses 的扁平格式并显式关闭 strict，保留原有可选工具参数。
- Chat Completions 保留 assistant/tool 消息配对，支持 reasoning_content / reasoning。工具收到完整响应后才执行；流中断时不会执行尚未完成的工具调用。
- 取消关闭连接、拒绝过期输出，保留已收到的内容；已经开始的本地原子写入会先完成，再允许下一轮对话。账本变更仍通过原有待确认提案机制执行。
- 对话跨日期连续使用。上下文按完整用户轮次截取，最多 15 轮、约 60,000 字符（最近一轮完整保留）；更多历史通过 get_chat_history 查询。历史查询不返回内部协议记录，避免重复嵌套。聊天按原有规则保留 365 天，长期记忆独立保存。
- 错误展示 HTTP 状态、服务 message/type/code/param、端点、模型、协议与可获得的 request ID。网络、超时、非 JSON 响应、截断和 Responses incomplete/failed 均展示具体原因并保留部分输出；错误文本隐藏当前密钥。

架构参考 [pi agent-core](https://github.com/badlogic/pi-mono/tree/main/packages/agent) 的事件驱动工具循环与 UI 消息 / 模型消息分离思想，在 Dart 内实现，未引入 Node 运行时。

协议参考：[OpenAI 流式响应](https://developers.openai.com/api/docs/guides/streaming-responses)、[函数调用](https://developers.openai.com/api/docs/guides/function-calling)。

## 记忆优化

保留 agent.memories、画像、标签、偏好、目标和旧备份结构，新增 `agent_memory.dart`：

1. 每次提问按中文二字片段 / 英文关键词、重要性和更新时间选取记忆，默认最多 12 条、6,000 字符。当前进行中的目标一并进入上下文。
2. add_memory 按忽略空白与大小写的事实去重，返回稳定 ID；新写入记录来源消息 ID 和更新时间。兼容旧 description 字段与其他扩展字段。
3. search_memories / update_memory / forget_memory 支持查询、用户纠正与遗忘；原有页面仍可删除、重置记忆。修改会失效分析缓存。
4. 提示明确区分事实与指令、历史快照与当前状态，不把推测自动当作事实保存。

下一阶段值得优化的是记忆的有效期、矛盾候选审阅，以及长对话摘要。目前是有界关键词召回，不是语义向量检索；没有引入额外模型费用或迁移现有记忆库。

## 验证边界

测试覆盖两种协议、UTF-8 与参数分片、推理条目续接、断流、超时、重试续接、错误脱敏、图片不持久化、旧配置迁移、配置失败回滚、记忆兼容及 320px 大字体界面。检查日志位于 build/agent-responses-analyze.log 和 build/agent-responses-tests.log。

本轮完整 Flutter 回归为 98 项通过，静态检查无问题。最终生命周期调整另外复测协议与 Agent 回归；日志为 build/agent-responses-lifecycle-tests.log。ARM64 release 构建日志为 build/agent-responses-apk.log，APK 位于 build/app/outputs/flutter-apk/app-release.apk（约 22.3 MB，沿用工程现有开发签名）。

对话内确认与工具记录精简调整后，执行 `flutter test --no-pub`，105 项通过；`flutter analyze --no-pub` 无问题。新增覆盖点击后的持久化反馈、拒绝与撤销、失败重试、重复提案去重，以及 320px 大字体下 12 次工具调用只占一行。

尚未使用用户实际网关与密钥联调，也未替代真机图片、工具与网络环境验收。请先在设置页测试连接，再进行真实多轮对话；服务特有的不兼容参数会显示在错误详情中。
