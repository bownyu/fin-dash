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

顾问入口和基础 API 接入已保留。**顾问重构与真实模型验收留到后续**。

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

## 常用命令

在项目目录的 PowerShell 中运行：

```powershell
.\scripts\dev.ps1 doctor
.\scripts\dev.ps1 deps
.\scripts\dev.ps1 analyze
.\scripts\dev.ps1 test
.\scripts\dev.ps1 preview -Demo
.\scripts\dev.ps1 build-apk
.\scripts\dev.ps1 run -Device <设备ID>
```

`-Demo` 使用独立内存示例数据，不写入真实账本。正式 APK 不含示例数据。

APK 位置：`build/app/outputs/flutter-apk/app-release.apk`。默认 ARM64，供现代手机测试安装；当前使用开发签名，商店发布签名另行配置。

## 数据一致性与限制

金额以整数“分”保存。余额由期初余额和账单推导，编辑、删除和转账同步更新。净资产等于资产减负债；转账和信用卡还款不计入收支。

本机账本先写临时文件再替换，带校验和与上一份有效副本；保存失败不更新内存。浏览器预览使用本地浏览器存储。导入先验证，确认后替换当前账本。当前支持人民币账户。

应用 ID 为 `com.findash.fin_dash`，与旧原生 `com.findash.app` 分开安装。通过备份迁移数据，不自动读取另一应用的私有数据库。

测试覆盖账本一致性、日期边界、备份兼容、损坏恢复、手机布局和主要表单。未连接真机时，相册、原生文件保存、系统返回手势和不同品牌手机显示仍需真机验收。
