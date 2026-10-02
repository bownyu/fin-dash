# GitHub 发布内容与隐私

公开仓库只保存当前 Flutter 应用源码、Android/Web 平台源码、品牌图标、第三方许可、合成数据测试、可复现的构建脚本和公开使用说明。

下列内容留在本地：账本、SQLite 文件、聊天记录、通知收件箱、备份、真实账单文件、录音、用户截图、模型网关密钥、签名私钥与 key.properties、构建缓存、IDE 状态、调试日志、本机环境记录以及旧工程归档。大型离线模型由带 SHA-256 的下载脚本准备，不放入 Git 历史。APK、更新清单和校验文件作为 GitHub Release 附件上传。

私人账单验收测试移入被忽略的 test/private；公开测试使用合成数据。公开发布使用单独的干净源码快照，不把本地旧提交和作者私人邮箱上传。准备脚本采用白名单并再次检查敏感文件名、密钥格式和私人路径；扫描结果保存在被忽略的本地输出目录，不公开匹配值。

OTA 只请求公开更新文件和安装包，不读取或上传账本、画像、聊天、通知、录音、API 密钥或用户身份。下载放入应用私有缓存，大小和 SHA-256 校验通过后才可安装。Android 层再次校验应用 ID、递增的构建号及相同签名；系统仍需用户确认安装。

未来更新必须使用相同签名私钥。私钥在本机或 CI Secret 中保存，公钥证书随 APK 分发属于正常签名信息。公开仓库没有私钥或 GitHub 访问令牌。

接口参考：[GitHub Release 固定下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)、[Android FileProvider](https://developer.android.com/reference/androidx/core/content/FileProvider)、[Android 安装来源权限](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls())。
