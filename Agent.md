# FinDash 项目约定

## 版本管理

- 用户指定的版本管理起点：`0.0.1`。
- 当前发布版本：`0.5.0`（语音记账重做与首页动效）。
- 版本采用三段式 `主版本.次版本.修订版本`：
  1. 每次普通改动，最后一位加 1，例如 `0.1.0 → 0.1.1`。
  2. 大改动，中间一位加 1，最后一位归零，例如 `0.1.3 → 0.2.0`。
  3. 最大改动，第一位加 1，后两位归零，例如 `0.2.3 → 1.0.0`。
- 每次完成一项改动都要发布新版本。一次完整交付算一个版本，过程中连续编辑、格式化和修复测试不逐文件累加。
- 发布必须同步 `pubspec.yaml`、`lib/app_version.dart`、本文件当前版本及 `CHANGELOG.md`；应用内版本展示统一引用 `appVersion`。
- Android 构建号（`+N` / versionCode）独立递增，不能因重设三段版本号而降低；本次递增至 `+9`。
- 完成相关测试和构建验证后，交付版本号、更新内容、验证结果及构建产物路径。构建失败不得宣称已成功发布安装包。
- 不把应用版本号与 SQLite `user_version` 或 JSON 备份 schema 混用；后两者仅在存储结构实际变更时升级。

## 数据与迁移

- 所有持久化变更先完成事务，再更新内存账本和通知 UI。
- 原生端使用 SQLite 增量写入；旧 JSON 迁移成功后仍保留源文件。
- 写入失败必须回滚；不能为了优化速度跳过迁移、恢复和数据一致性测试。
- 浏览器端保留原有存储后端，不宣称其具备原生 SQLite 或 isolate 性能。

## Windows 开发环境

- 所有 Flutter / Dart 依赖操作、测试和构建先加载 `scripts/environment.ps1`，或使用 `scripts/dev.ps1` 对应入口。
- `PUB_CACHE` 必须使用项目内 `.pub-cache`，不能直接使用全局 D 盘缓存。项目位于 E 盘时，跨盘插件路径会导致 Android Studio Gradle Sync 和 Kotlin 增量构建报 `this and base files have different roots`。
- 添加依赖后检查 `.dart_tool/package_config.json` 与 `.flutter-plugins-dependencies` 中的插件路径仍指向项目内缓存。
- Android Studio 使用 `Open-Android-Studio.cmd` 打开，确保 IDE 继承同一套环境；不能在用户未保存编辑时擅自关闭 IDE。
