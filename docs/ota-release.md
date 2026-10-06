# GitHub Release 与 OTA

## 更新入口

应用设置中的“检查更新”读取公开 GitHub Release 附件 ota-manifest.json。固定入口使用 releases/latest/download，下一次发布新附件后无需修改已安装应用的更新链接。

首次安装 OTA 版本需要手动下载安装包；之后在应用内检查、下载并安装。这里只自动下载安装包，不绕过 Android 的安装来源许可或系统确认。

## 发布步骤

1. 按 Agent.md 同步应用版本与递增构建号，完成测试。
2. 本机 android/key.properties 指向现有私有签名；更新必须使用相同证书。仅首次开发构建可用本机 debug 签名。
3. 构建 release APK；运行 scripts/prepare-github-release.ps1 -Repository owner/repo，扫描全部受版本控制的文件并在 output/github-publication/assets 生成安装包、更新清单和校验文件。
4. 提交本次版本并推送到 GitHub 的 main 分支。
5. 运行 scripts/publish-github-release.ps1 -Repository owner/repo，上传已经准备的附件并发布版本。脚本验证 APK 和更新清单哈希，拒绝覆盖已有发布版本。

## 更新清单

schemaVersion、applicationId、version、buildNumber、sizeBytes、sha256、downloadUrl、notes 均来自本次构建。下载地址绑定同一仓库、版本标签及 APK 文件名，不接受其他主机或降级版本。下载流在应用私有缓存中存储，完整校验后才可交给系统。

GitHub 接口和下载不会收到用户账本、录音、聊天或模型密钥。公开内容范围见 [隐私说明](publication-privacy.md)。

## 后续发布

GitHub Actions 提供手动 release 工作流。首次配置仓库 Secret：ANDROID_KEYSTORE_BASE64、ANDROID_STORE_PASSWORD、ANDROID_KEY_PASSWORD、ANDROID_KEY_ALIAS；私钥不得放入源码。手动 workflow_dispatch 使用同一签名，构建并上传 APK／OTA 清单／SHA256SUMS。仓库访问使用 GitHub 提供的临时 GITHUB_TOKEN，不写入应用。

当前应用的更新来源可在构建时通过 OTA_MANIFEST_URL 定义覆盖，源码仓库私有时可以将安装包与更新清单发布到单独公开的分发仓库。
