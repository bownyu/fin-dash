# 智能体与支付通知验证记录

日期：2026-10-01。分支：`feat/agent-notification`。

## 已完成的实现

- 查询真实账户、设置和分页账单，汇总覆盖全部筛选结果。
- 账户、交易和预算提案由用户确认后保存；确认及撤销检查冲突，保存失败不更新内存，重复确认不会重复写账。
- 账户余额校正保留已有流水，预览展示目标账户、字段差异与余额影响。
- 手动截图附件、图片能力开关、失败重试与取消；图片不进入账本、备份或历史消息。
- 日期按日历与时钟严格校验；缓存包含问题、账本、日期、模型服务地址和提案状态。请求期间更换配置不会将原服务的密钥发送到新服务。
- Android 本地支付规则与 SQLite 收件箱，先保存账本再 ACK，精确事件去重，疑似重复需额外确认。
- 通知候选核对与人工入账，退款保持待核对；同步、清除和开关跨页面串行处理。同步失败仍可查看授权与容量诊断。
- 阿里云 Maven 镜像优先，保留官方仓库；项目缓存中的镜像请求绕过本机代理。

## 自动验证

| 检查 | 结果 | 证据 |
|---|---|---|
| `scripts/dev.ps1 analyze` | 通过，无分析问题 | Flutter 3.41.1 / Dart 3.11.0 |
| `flutter test --reporter expanded` | 80 项通过 | `build/agent-flutter-tests.log` |
| `:app:testDebugUnitTest` | 通过；10 项支付规则测试，0 失败 / 错误 | `build/agent-native-tests.log`、`build/app/test-results/testDebugUnitTest/TEST-com.findash.fin_dash.PaymentRulesTest.xml` |
| ARM64 release APK | 通过，22.2 MB | `build/agent-release-build.log`、`build/app/outputs/flutter-apk/app-release.apk` |

Flutter 测试涵盖原子保存、幂等、修改冲突、撤销、严格日期、转账余额、分页汇总、图片不持久化、配置切换、缓存失效、通知保存失败不 ACK、崩溃重放、同步与清除竞争、普通记账与手机布局。Widget 测试显式模拟 Android MethodChannel，不代表真机服务已经验收。

原生测试涵盖聊天与营销过滤、失败与待处理支付、整数分、千分位、非法金额不截取为有效尾数、重复展开文本、多金额、退款、还款及转账分类。SQLite 服务生命周期与系统授权仍需设备验证。

2026-10-01 镜像检查：截图中的 `org.robolectric:nativeruntime-dist-compat:1.0.18`、AGP 8.11.1 和 Kotlin Android 插件 2.2.20 均返回 HTTP 200；该 JAR 的 1 MiB 分段请求返回 HTTP 206，约 6.6 MB/s。分段测速不代表完整下载或其他网络环境的持续速度。

## 未验证的验收项

`adb devices -l` 未发现连接设备，且未调用真实模型服务。以下不能由上述模拟测试替代：

- 小米 17 Pro 的 Android / HyperOS、微信及支付宝版本与真实通知文案。
- 系统授权、断网采集、熄屏、划掉任务、重启、撤权和强行停止后的恢复。
- 实际扫码、收款、转账、退款、通知更新的捕获率与误判情况。
- 开关采集前后的 CPU、联网、唤醒次数及待机耗电。
- 相册选择、真实模型图片与工具调用兼容性，以及截图金额识别质量。

本轮保持人工核对后入账；个人微信／支付宝账单文件导入继续暂缓。APK 使用工程现有开发签名，供测试安装。
