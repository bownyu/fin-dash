# FinDash

本地优先的 Android 记账应用，使用 Flutter 构建。支持账户与资产、账单、统计、备份、支付通知识别、本地语音与 AI 财务顾问。

## 安装与升级

从本仓库的 Releases 下载 ARM64 安装包。首次安装含 OTA 的版本后，可在“我的 → 应用设置 → 检查更新”下载并升级。更新保留现有账本，安装需在 Android 系统界面确认。

离线语音模型随 APK 安装，因此完整安装包约 344 MB。本地转文字可离线；调用自己配置的 AI 模型解析账单需要联网。

## 核心功能

- 支出、收入、转账，分类、账户、时间与备注编辑。
- 账户余额、信用卡、预算、收支统计、搜索与批量操作。
- Agent 任务级变更方案：汇总、明细调整、例外审阅、批量确认和撤销。
- 微信／支付宝支付通知在本机识别，确认后才入账。
- 本地 SenseVoiceSmall INT8 语音识别与桌面小部件。
- SQLite 增量账本与 JSON 备份恢复。
- GitHub Release OTA：下载进度、校验和同签名覆盖升级。

## 隐私

仓库不包含用户账本、真实账单、截图、录音、密钥、签名私钥或本地提交历史。AI 请求仅发送用户主动要求分析的数据至自己配置的接口；OTA 请求只用于公开版本检查和安装包下载。详见 [公开发布与隐私](docs/publication-privacy.md)。

## 开发

需要 Flutter 3.41.1 / Dart 3.11 或兼容版本、Android SDK、Java 17 以上及 PowerShell。

```powershell
flutter pub get
./scripts/prepare-offline-voice.ps1
flutter test
flutter build apk --release --target-platform android-arm64
```

发布者通过未提交的 android/key.properties 配置私有签名。构建、发布和更新清单步骤见 [发布与 OTA](docs/ota-release.md)。离线模型与运行库由锁定 URL 和 SHA-256 的脚本准备，第三方许可保存在 assets/licenses。
