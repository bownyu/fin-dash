# AI Native 0.4.0 实施记录

日期：2026-10-03。应用版本：0.4.0+7。本文件记录实际实现和验证，不替代目标设计。

## 接入范围

| 责任 | 实际实现 |
| --- | --- |
| 业务与提交 | LedgerOperations、LedgerCommands、CommandContext；共同校验、锁重验、稳定幂等回执、编辑冲突 |
| 数据 | 深层只读快照、六域通知、metadata 通道、LedgerChangeSet、SQLite 主库与恢复副本同事务、索引查询 |
| 能力 | CapabilityRegistry 生成 schema 与路由；旧工具通过兼容适配注册；未知字段与不可执行效果被拒绝 |
| 查询 | QueryScope / QuerySnapshot / QueryResult / ErrorEnvelope；原生 SQL 聚合分页，内存语义对照 |
| 查询编程 | 版本 1 解析校验与执行；scan/filter/calendar/group/derive/compare/sort/take/project；步数、行数、输出、时间及取消预算 |
| 任务 | 独立身份、持久化状态、补充卡、方案与回执关联、重启中断恢复、用户继续/放弃 |
| 授权 | Host-only AuthorizationGrant；批准绑定方案、世代与选中集合，旧方案和条件撤销重验 |
| AI 上下文 | AppSpec、PromptAssembler、按完整轮次和字节预算组装上下文、有限记忆投影 |
| 界面 | 原生补充卡、任务中心、查询表格、常用分析、语音队列及草稿恢复 |

## 迁移与兼容

- 应用版本、备份 schema 和 SQLite user_version 独立。备份 schema=2；底层表结构仍为 v1，增加可重建表达式索引。
- 分类按类型与名称唯一匹配，不猜测历史交易来源或精确时刻；旧批次映射独立 taskId。恢复更换 ledgerEpoch。
- 保留现有退款累计、导入保余额、来源 ACK、批次依赖与条件撤销规则。手动流程不调用模型。
- 旧测试中“解锁与改账同一个任意回调”的夹具拆为显式解锁再改账；旧模型自动写记忆的测试改为审阅前不写入，传输测试用只读能力继续覆盖协议配对和重试。

## 验证记录

- 加载 scripts/environment.ps1 后，Flutter 全量回归 **248 项通过、1 项私人样本跳过**。新增 21 项 AI Native 回归；原有通知、退款、保余额导入、SQLite 恢复与批次撤销回归保留。
- 静态检查 flutter analyze --no-pub：**无问题**；最终补充回归（ai_native_test + version_test）**22 项通过**。
- Android testDebugUnitTest **22 项通过、0 失败**。
- ARM64 Android release 构建成功；aapt 核验 com.findash.fin_dash / versionName 0.4.0 / versionCode 7；apksigner 验签通过且证书与 0.3.0 一致。
- 安装包：output/releases/0.4.0/FinDash-0.4.0+7-arm64.apk，361,012,720 字节；SHA-256：9307aa6d06c6e19694d72c2447d4bbef0a49afafb1ada45d5f44b62f1a2485b0。该包为本地交付，未上传公开 Release。
- 合成基准 1千 / 1万 / 10万笔，**3 项通过**。基准入口为 tool/benchmarks/ai_native_benchmark_test.dart；以下为 Windows Flutter test 模式的一次测量，不是手机 p95。
- Android 设备列表为空；没有真机帧率、权限、杀进程实验。没有调用真实模型网关；PromptAssembler v1 / AppSpec v1 / capability v1 的实际模型 E01–E26 仍未验证。
- 未新增依赖；所有 Flutter 插件路径均位于项目 .pub-cache（越界路径 0）。

| 记录数 | 初始化导入 ms | 冷启动 ms | 新对话 ms / 比较行数 | 单笔保存 ms / 比较行数 | SQL 全量汇总 ms | 主库字节 | 进程 RSS / 峰值字节 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1,000 | 186 | 70 | 31 / 57 | 34 / 67 | 11 | 675,840 | 152,989,696 / 181,067,776 |
| 10,000 | 730 | 422 | 31 / 57 | 33 / 67 | 20 | 6,193,152 | 182,083,584 / 191,660,032 |
| 100,000 | 6,836 | 4,072 | 30 / 57 | 43 / 67 | 120 | 62,312,448 | 416,047,104 / 483,688,448 |

比较行数包含元数据载荷与位置读取，不等于磁盘扫描数。聊天提交的财务载荷为零，正常交易只传受影响记录；任意列表替换仍使用完整兼容路径。RSS 是整个测试进程，三种规模依次运行，不能解释为独立启动的应用常驻内存。

启动优化在同一读取事务中校验主库并用 SQL 比较恢复副本，避免重复解码三份账本；原有损坏恢复和未来 schema 拒绝测试继续通过。

## 仍然存在的实现边界

- 旧页面仍使用内存查询适配，启动仍装载完整账本；不是所有 UI 已改成 SQL 按需分页。任意替换列表的兼容写法走完整快照验证，正常记录命令走 ChangeSet。
- 旧工具分派保留兼容 switch，新增能力无需修改它。legacy batch/message 引用保留，任务中心使用独立任务身份。
- 不提供任意 IANA 时区、任意 join、SQL/脚本执行或真实银行转账。查询程序只处理实际注册的数据集。
- 未做真实模型网关评测，E01–E26 的语言行为不能因单元测试通过而宣称完成；未连接设备时不声称通过真机性能和后台生命周期验收。

后续工作需继续按目标设计收敛旧页面查询、全量启动与兼容 mutation 入口；本版不把这些遗留边界标记成已经消失。
