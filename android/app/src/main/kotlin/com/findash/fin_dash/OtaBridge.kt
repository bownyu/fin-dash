package com.findash.fin_dash

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class OtaBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val worker = Executors.newSingleThreadExecutor()
    private val channel = MethodChannel(messenger, "findash/ota")
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf("canInstall" to canInstall(), "sdk" to Build.VERSION.SDK_INT))
                "openInstallPermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !canInstall()) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}")))
                        }
                        result.success(null)
                    } catch (_: Exception) { result.error("permission", "无法打开安装权限设置，请在系统设置中允许 FinDash 安装应用", null) }
                }
                "install" -> {
                    val path = call.argument<String>("path")
                    val expectedHash = call.argument<String>("sha256")
                    val build = call.argument<Number>("buildNumber")?.toLong()
                    worker.execute {
                        try {
                            require(path != null && expectedHash != null && build != null) { "更新信息不完整" }
                            val file = File(path).canonicalFile
                            val base = File(activity.cacheDir, "findash-updates").canonicalFile
                            require(file.path.startsWith(base.path + File.separator) && file.name.endsWith(".apk") && file.isFile) {
                                "安装包路径无效，请重新下载"
                            }
                            require(file.length() in 1..1024L * 1024 * 1024) { "安装包大小无效" }
                            val digest = MessageDigest.getInstance("SHA-256")
                            file.inputStream().use { stream ->
                                val buffer = ByteArray(128 * 1024)
                                while (true) {
                                    val size = stream.read(buffer)
                                    if (size < 0) break
                                    digest.update(buffer, 0, size)
                                }
                            }
                            val hash = digest.digest().joinToString("") { "%02x".format(it) }
                            require(hash == expectedHash) { "安装包校验失败，请重新下载" }
                            @Suppress("DEPRECATION")
                            val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                            @Suppress("DEPRECATION")
                            val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
                            @Suppress("DEPRECATION")
                            val archive = activity.packageManager.getPackageArchiveInfo(file.path, flags)
                            require(archive != null) { "无法读取安装包，请重新下载" }
                            OtaPolicy.validate(activity.packageName, archive.packageName, version(installed),
                                version(archive), build, signers(installed), signers(archive))
                            activity.runOnUiThread {
                                try {
                                    check(canInstall()) { "请先允许 FinDash 安装应用" }
                                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.ota.files", file)
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, "application/vnd.android.package-archive")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        clipData = ClipData.newRawUri("FinDash update", uri)
                                    }
                                    activity.startActivity(intent)
                                    result.success(null)
                                } catch (e: Exception) { result.error("install", e.message ?: "无法打开系统安装器", null) }
                            }
                        } catch (e: Exception) {
                            activity.runOnUiThread { result.error("validation", e.message ?: "安装包验证失败", null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun canInstall() = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()
    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }
    fun destroy() { channel.setMethodCallHandler(null); worker.shutdown() }
}
