# FinDash · Flutter

wallet_apk 基础功能的 Flutter 重构。提供白色透明与黑色蓝色两套外观，统一账户、账单、统计和备份的数据逻辑。旧 Kotlin 工程保存在 `legacy_android/`。

## 界面与外观

- 主推「白色 · 透明」：浅色背景、冰蓝与淡紫光感、半透明卡片、悬浮磨砂玻璃导航。
- 备用「黑色 · 蓝色」：深色背景、蓝色资产卡、深色玻璃导航。
- 首页右上角的外观按钮和「我的 → 应用设置」均可切换；选择自动保存到本地账本。
- 新账本默认使用白色透明方案，已有账本保留保存的外观，包括旧版的跟随系统设置。
- 首页采用资产概览、月收入 / 支出、快捷操作与预算卡片组成的方块布局；宽屏将概览分栏，并使用侧边导航。
- 首页直接展示资产与操作，不显示 Logo、品牌标题或宣传问候语。外观、提醒与金额隐藏按钮位于资产卡右上角。
- 玻璃模糊用于悬浮导航；内容卡片采用透明填色、高光边缘和柔和阴影，避免长列表逐项模糊。
- 完整页面各自绘制不透明背景，Android 页面进出使用滑动动画，避免透明页面交叉淡入产生文字重影。
- 底栏直接切换目标页面，首次访问时加载，后续保留统计周期、账单搜索和滚动位置。隐藏页面暂停动画，重复点击不会叠出多份页面。
- 主题配置复用，普通账本更新仅刷新相关内容；余额与账单排序按已保存账本缓存，收支汇总不再先排序整本账单。
- 图标由内置 imagegen 绘制为浅色背景、蓝色玻璃钱包，原图保存在 `assets/brand.png`，完整提示词保存在 `assets/brand-icon.prompt.txt`。Android 各密度图标、适配系统形状的图标资源和网页图标已同步更新。

## 已实现的基础功能

- 首页：净资产 / 总资产 / 总负债切换，金额隐藏，日周月支出，快捷交易，近期账单，预算进度。
- 记账：支出 / 收入 / 转账，独立分类，账户选择，日期时间，备注，数字键盘，修改与删除。
- 账户：资金 / 信用 / 充值 / 投资四类，37 种预设，负余额，信用额度，账单日 / 还款日，资产统计开关，归档，流水和信用卡还款。
- 统计：日 / 周 / 月 / 年，历史周期，收支分布、趋势和分类明细。
- 账单：搜索，日期 / 类型 / 分类 / 账户组合筛选，长按多选、批量删除、CSV 导出。
- 个人：本地档案，昵称 / 邮箱 / 相册头像，快捷交易管理，自定义分类，财务目标，月预算，深浅主题。
- 备份：完整 JSON 导出，旧 wallet JSON / UTF-8 Base64 导入，导入预览和确认，保留旧版当前余额而不重复扣款。
- 提醒：应用内预算和信用卡还款提醒，分别开关。当前不发送系统推送。

## 智能体与支付通知（feat/agent-notification）

- 顾问可读取真实账户设置、按账户和日期分页查询账单，并取得全部匹配账单的收支及分类汇总。
- 新增／修改账户和账单、调整月预算先生成提案，进入「待确认操作」核对后才写入账本；历史可查看结果并在没有后续冲突时撤销。
- 支持手动选择单张 PNG／JPEG 截图。先在「AI 设置」明确启用模型的图片输入能力；发送前可预览和移除，图片只在请求／失败重试的内存中保留。
- 「我的 → 支付通知识别」默认关闭。Android 授予通知使用权后，在本机筛选微信／支付宝支付通知并保存待确认候选；人工选择实际账户、金额和时间后入账。退款保留待核对，疑似重复须额外确认。
- 进入或返回 App、解锁后，同步已保存的通知，并为新出现的待确认记录打开集中核对面板。后台仅保存通知；编辑页未关闭时延后提醒。点「稍后处理」会记住已提醒的记录，同一批不会反复弹出；首页持续展示待确认数量与「去核对」入口，有新记录再提醒。
- 集中核对可逐笔修改、忽略，或选择实际账户后一次确认选中记录。只有用途、金额和类型完整且无重复嫌疑的收支通知可批量处理；退款、转账、还款、未知类型和缺失字段留待逐笔核对。批量确认只写一次账本，提交时重检账户、锁定状态、来源金额、时间、类型与重复项，失败整批不入账，重试按事件 ID 保持幂等。
- 原生 SQLite 收件箱在账本保存成功后才 ACK，重试按事件 ID 去重；关闭采集和清除队列与同步串行处理。网页不提供原生通知采集。

实现方案见 [docs/agent-notification-plan.md](docs/agent-notification-plan.md)。真实模型图片兼容性、小米／HyperOS 后台采集与耗电仍需真机验收。

## 自定义 AI 接口与流式对话

「我的 → AI 设置」仅保留自定义 OpenAI 兼容接口，可选 Responses 或 Chat Completions，支持流式回答、服务返回的思考、工具参数与结果、错误详情、停止及失败重试。提供独立的连接测试；账本变更继续经提案确认。旧记忆与配置兼容方式、记忆召回和协议说明见 [docs/agent-responses.md](docs/agent-responses.md)。

流式增量通过独立通知只刷新当前回复，每 80 ms 合并一次。历史消息按可见范围加载，输入框与其他账本页面不随 token 刷新。接收中的当前文本块使用轻量文字渲染，块完成后显示可选择的 Markdown；思考和工具详情打开时独立刷新。聊天列表从最新消息开始，跟随输出不重启滚动动画，查看旧消息时保持当前位置。

## 本地语音与手动录音

- App 与桌面小部件都需要点开始、说完再点结束；停顿和录音时长不触发自动结束。小部件录音时也可从系统通知结束，删除小部件会取消录音。
- App 内的语音记账是首页上的底部面板，点首页入口直接开始录音。录音时显示时长和音量条；开始 3 秒内一直没有声音时提示靠近麦克风，但不会结束录音。
- 使用 **SenseVoiceSmall INT8 + sherpa-onnx 1.13.8** 在 Android CPU 上本地转文字。模型、词表与 Silero VAD 随 APK 安装，首次使用无需下载，不依赖系统语音服务，不回退到联网 ASR。识别模型在录音期间后台加载，结束录音后只需等待解码。
- Silero 只在手动结束后过滤静音、划分语音片段，不控制录音停止。PCM 写入私有临时文件，转写完成或取消后删除；长录音分段处理，避免把全部音频留在内存中。
- 所有记账文字统一由已配置的 AI 接口解析，移除本地规则分流与规则补全。AI 请求失败保留文字，明确提示重试；生成草稿后仍需人工核对、确认保存。
- 解析时告诉模型文字来自语音识别、可能有同音字，并附上最多 5 笔标题相近的已确认账单（标题、类型、分类、账户 ID，不含金额和备注），用来纠正商家写法和常用账户。SenseVoice 只支持 greedy 解码，不能用热词。
- 核对卡片中缺失的字段标红，主按钮直接跳到需要补的那一项；模型推测的字段标“推测”。识别错一个词时，可以再说一句修改（如“改成招商银行”），App 和小部件都只改动提到的字段，不必整句重说。
- **转文字可离线，AI 解析账单需要联网。** 接口未配置时仍能录音、看到本地转写结果，再配置接口生成账单。

2026-10-02 接入前检索了以下候选，体积为现成 ONNX 权重的近似值，不等于运行内存或最终 APK 体积：

| 模型 | 权重体积 | 当前选择依据 |
|---|---:|---|
| [SenseVoiceSmall INT8](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html) | 228 MiB | 中文、粤语等，已有 Android 接入，短句记账优先控制体积和延迟 |
| [Qwen3-ASR-0.6B INT8](https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/pretrained.html) | 937 MiB + 词表 | 新一代多语种与方言模型，已有 sherpa Android 支持，内置成本更高 |
| [Fun-ASR-Nano INT8](https://k2-fsa.github.io/sherpa/onnx/funasr-nano/pretrained.html) | 约 949 MiB + 词表 | 支持中文方言，已有 Android 接入，LLM 解码需要更多资源 |
| [FireRedASR2 CTC INT8](https://k2-fsa.github.io/sherpa/onnx/FireRedAsr/pretrained.html) | 740 MiB | 中文、英文和多种口音；CTC 转换不能直接套用完整 AED/LLM 的榜单成绩 |

SenseVoice 是本次手机内置方案的工程选择，不宣称是 2026 年所有中文测试集的 SOTA。最终识别率、录音权限、后台小部件与流畅度需用目标手机和真实记账音频验收。

首次构建执行 `scripts/prepare-offline-voice.ps1`（开发入口会自动执行）；脚本按 `scripts/offline-voice.lock.json` 下载并校验 SHA-256。二进制模型与 AAR 不提交 Git，后续资源有效时不重复下载，构建缺少资源会明确失败。运行许可与模型归属随 App 保存，可在「应用设置 → 开源许可」查看。

## 用 Android Studio 打开

1. 保存修改并退出当前 Android Studio。
2. 双击根目录 **Open-Android-Studio.cmd**。入口加载 D 盘开发工具与项目内依赖缓存，并修正旧工程配置。
3. 打开 `lib/main.dart`，运行配置为 `main.dart`。
4. Flutter SDK 使用 `D:\PC\ENV\Flutter`；Android SDK 使用 `D:\PC\ENV\Android\SDK`。
5. 工程配置、代码检查和 APK 构建无需手机。运行到手机时才启用 USB 调试、连接设备。

本机 Studio 252 搭配 Flutter 插件 96 和 Dart 插件 503。Dart 已换为上游发布的旧版 Studio 兼容修复版本，原插件已备份，插件仍在 D 盘。

若仍看到 Gradle 9.0 milestone 下载，取消旧导入，从上述入口重新打开。安卓子工程应使用 `android/gradle/wrapper/gradle-wrapper.properties` 的 **Gradle 8.14.3**。

## 路径约定

| 内容 | 本机位置 |
|---|---|
| Flutter SDK | `D:\PC\ENV\Flutter` |
| Android SDK、NDK、构建工具 | `D:\PC\ENV\Android\SDK` |
| Java | 复用 `D:\TOOL\AndroidStudio\jbr` |
| Android Studio 本体 | 复用 `D:\TOOL\AndroidStudio` |
| 新插件、Studio 配置 / 索引 / 日志 | `D:\PC\ENV\Android\Studio` |
| 本项目 Dart / Flutter 依赖缓存 | 工程内 `.pub-cache/` |
| 本项目 Gradle 发行版和依赖缓存 | 工程内 `.gradle-home/` |
| 项目产物和临时文件 | 工程内 `build/`、`.dart_tool/`、`android/.gradle/` |

源码、`pubspec.yaml`、`pubspec.lock`、平台配置和脚本随项目保存。生成缓存、`local.properties` 和 IDE 工作区不需要同步到 Git。

Java 下载使用本机已启用的代理 `127.0.0.1:7897`。以后关闭或变更代理时，在工程内 `.gradle-home/gradle.properties` 和 Studio HTTP Proxy 设置中同步调整。

本项目通过 `PUB_CACHE` 和 `GRADLE_USER_HOME` 指定工程内缓存。依赖与构建输出同在 E 盘，避免 Android Studio 生成测试配置时的跨盘相对路径错误；无需关闭 Kotlin 增量编译或修改第三方插件源码。这些是可重新生成的本机缓存，不提交到 Git。使用上述入口和脚本可确保 IDE 与命令行使用相同路径。

### 国内 Maven 镜像与慢速 Sync

Android 的插件与依赖仓库已配置为阿里云镜像优先，保留官方仓库作为未命中时的后备：

- Maven Central：`https://maven.aliyun.com/repository/central`
- Google Maven：`https://maven.aliyun.com/repository/google`
- Gradle 插件：`https://maven.aliyun.com/repository/gradle-plugin`

这会覆盖应用和 Flutter 插件的 Android 依赖（包括 Robolectric 测试包）。Gradle 发行版、Android SDK、Flutter SDK 和 Dart pub 包各有独立下载源，不受 Maven 仓库配置控制；Flutter SDK 自身的 included build 也有独立仓库配置。

修改后取消旧 Sync，再重新同步。若 Studio 的 Gradle user home 仍指向 `D:\PC\ENV\Gradle`，请保存并退出 Studio，再运行根目录 `Open-Android-Studio.cmd`，让 Studio 与命令行统一使用工程内 `.gradle-home`，避免两份缓存重复下载。不需要清空已有缓存。

本机 `.gradle-home/gradle.properties` 已将 `maven.aliyun.com` 加入 `systemProp.http.nonProxyHosts` 和 `systemProp.https.nonProxyHosts`，镜像直连，其余地址保留原代理。更换电脑时可按网络情况设置；本机代理文件不提交到 Git。

## 常用命令

在项目目录的 PowerShell 中运行：

```powershell
.\scripts\dev.ps1 doctor
.\scripts\dev.ps1 deps
.\scripts\dev.ps1 analyze
.\scripts\dev.ps1 test
.\scripts\dev.ps1 test-native
.\scripts\dev.ps1 voice-assets
.\scripts\dev.ps1 preview -Demo
.\scripts\dev.ps1 build-apk
.\scripts\dev.ps1 run -Device <设备ID>
```

`-Demo` 使用独立内存示例数据，不写入真实账本。正式 APK 不含示例数据。

APK 位置：`build/app/outputs/flutter-apk/app-release.apk`。默认 ARM64，供现代手机测试安装；当前使用开发签名，商店发布签名另行配置。

## 数据一致性与限制

「我的 → 导入微信账单」支持微信支付导出的 `.xlsx`。先在本机解析真实表头、Excel 日期和整数分金额，再预览、选择支付方式对应的账户及勾选明细。普通消费归入“其他”，红包收入优先“收红包”，退款收入单独“退款”；原消费与全额/部分退款流水按原文件分别保留，避免重复扣减原金额。充值、提现等不计收支记录和未完成、无效记录明确列出并跳过。

微信账单是追加导入，确认后一次保存，不替换已有账本。根据文本交易单号生成稳定 ID，重复导出/重复点击自动去重；金额与时间相近的已有账单提示人工核对，默认不选中。默认调整期初余额以保持当前账户余额，也可关闭该选项让新账单按收支改变余额。选择文件、取消预览或保存失败均不写入账本。解析在后台执行，明细按可见范围加载；原始微信文件不修改、不上传。

金额以整数“分”保存。余额由期初余额和账单推导，编辑、删除和转账同步更新。净资产等于资产减负债；转账和信用卡还款不计入收支。

本机账本先写临时文件再替换，带校验和与上一份有效副本；保存失败不更新内存。浏览器预览使用本地浏览器存储。导入先验证，确认后替换当前账本。当前支持人民币账户。

应用 ID 为 `com.findash.fin_dash`，与旧原生 `com.findash.app` 分开安装。通过备份迁移数据，不自动读取另一应用的私有数据库。

测试覆盖账本一致性、日期边界、备份兼容、损坏恢复、手机布局和主要表单。未连接真机时，相册、原生文件保存、系统返回手势和不同品牌手机显示仍需真机验收。
