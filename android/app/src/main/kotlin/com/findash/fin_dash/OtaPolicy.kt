package com.findash.fin_dash

object OtaPolicy {
    fun validate(applicationId: String, archiveId: String?, installedBuild: Long,
                 archiveBuild: Long, expectedBuild: Long, installedSigners: Set<String>,
                 archiveSigners: Set<String>) {
        require(archiveId == applicationId) { "安装包不属于 FinDash，已拒绝安装" }
        require(archiveBuild == expectedBuild && archiveBuild > installedBuild) { "安装包版本不匹配或不是更新版本" }
        require(installedSigners.isNotEmpty() && installedSigners == archiveSigners) { "安装包签名不匹配，无法覆盖升级" }
    }
}
