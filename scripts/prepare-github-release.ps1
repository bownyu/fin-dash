param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskPublish = Join-Path $taskRoot 'output/github-publication'
$taskSource = Join-Path $taskPublish 'source'
$taskAssets = Join-Path $taskPublish 'assets'
$taskVersionText = [IO.File]::ReadAllText((Join-Path $taskRoot 'pubspec.yaml'))
$taskVersion = [regex]::Match($taskVersionText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (!$taskVersion.Success) { throw 'Invalid application version' }
$taskName = $taskVersion.Groups[1].Value
$taskBuild = [int]$taskVersion.Groups[2].Value
New-Item -ItemType Directory -Path $taskSource,$taskAssets -Force | Out-Null
# Remove only the old exported snapshot, preserving its separate Git history.
foreach ($taskChild in Get-ChildItem -LiteralPath $taskSource -Force) {
    if ($taskChild.Name -eq '.git') { continue }
    $taskChecked = [IO.Path]::GetFullPath($taskChild.FullName)
    if (!$taskChecked.StartsWith([IO.Path]::GetFullPath($taskSource) + [IO.Path]::DirectorySeparatorChar)) { throw 'Export path escaped' }
    Remove-Item -LiteralPath $taskChecked -Recurse -Force
}
$taskFiles = & git -C $taskRoot -c core.quotepath=false ls-files --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate source files' }
$taskAllowedRoots = '^(lib/|android/|web/|assets/|test/|tool/benchmarks/|\.github/workflows/)'
$taskRootFiles = @('.gitignore','.metadata','analysis_options.yaml','pubspec.yaml','pubspec.lock','CHANGELOG.md')
$taskDocFiles = @('docs/agent-batch-design.md','docs/publication-privacy.md','docs/ota-release.md',"docs/releases/$taskName.md")
$taskScriptFiles = @('scripts/prepare-offline-voice.ps1','scripts/offline-voice.lock.json','scripts/prepare-github-release.ps1','scripts/publish-github-release.ps1')
$taskDeny = '(?i)(^|/)(build|\.gradle|\.cxx|\.kotlin|\.dart_tool|\.pub-cache|private|\.idea|captures|sensevoice-small)(/|$)|(^|/)(key\.properties|local\.properties|\.env(?:\..*)?|gradlew(?:\.bat)?|gradle-wrapper\.jar)$|\.(db|sqlite3?|jks|keystore|p12|pem|xlsx?|csv|apk|aab|aar|onnx|log)$'
$taskCopied = @()
foreach ($taskFile in ($taskFiles | Sort-Object -Unique)) {
    if (!(($taskFile -match $taskAllowedRoots) -or $taskRootFiles.Contains($taskFile) -or $taskDocFiles.Contains($taskFile) -or $taskScriptFiles.Contains($taskFile))) { continue }
    if ($taskFile -match $taskDeny) { continue }
    $taskOriginal = Join-Path $taskRoot $taskFile
    if (!(Test-Path -LiteralPath $taskOriginal -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $taskOriginal).Length -gt 5MB) { throw "Oversized source file: $taskFile" }
    $taskDestination = Join-Path $taskSource $taskFile
    New-Item -ItemType Directory -Path (Split-Path $taskDestination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $taskOriginal -Destination $taskDestination -Force
    $taskCopied += $taskFile
}
Copy-Item -LiteralPath (Join-Path $taskRoot 'README.github.md') -Destination (Join-Path $taskSource 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'android/key.properties.example') -Destination (Join-Path $taskSource 'android/key.properties.example') -Force
foreach ($taskLinkFile in @('CHANGELOG.md','docs/agent-batch-design.md')) {
    $taskLinkPath = Join-Path $taskSource $taskLinkFile
    if (Test-Path -LiteralPath $taskLinkPath) {
        $taskLinkText = [IO.File]::ReadAllText($taskLinkPath)
        $taskLinkText = $taskLinkText -replace '\]\((?:docs/)?releases/0\.1\.0\.md\)', "](https://github.com/$Repository/releases/latest)"
        $taskLinkText = $taskLinkText -replace '\]\((?:docs/)?releases/0\.2\.0\.md\)', "](https://github.com/$Repository/releases/latest)"
        [IO.File]::WriteAllText($taskLinkPath, $taskLinkText, (New-Object System.Text.UTF8Encoding($false)))
    }
}
$taskUtf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $taskSource 'AGENTS.md'), "# Project instructions`nRead Agent.md before modifying this project.`n", $taskUtf8)
[IO.File]::WriteAllText((Join-Path $taskSource 'Agent.md'), "# FinDash project conventions`n`n当前发布版本：``$taskName```n`nPreserve transactional ledger writes, migrations, backup compatibility and signing identity. Increment the app version and Android build number together. Run tests, analysis and Android release build before publishing. Never commit runtime data, private test fixtures, credentials, signing keys or local caches.`n", $taskUtf8)
$taskFindings = @()
foreach ($taskFile in Get-ChildItem -LiteralPath $taskSource -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    if ($taskFile.Extension -match '^\.(png|webp|jpg|ico)$') { continue }
    $taskLines = [IO.File]::ReadAllLines($taskFile.FullName)
    for ($taskIndex=0; $taskIndex -lt $taskLines.Length; $taskIndex++) {
        if ($taskLines[$taskIndex] -match ('gh[pousr]_[A-Za-z0-9_]{25,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-|nvapi-)?[A-Za-z0-9_-]{25,}|(?i)[A-Z]:[\\/]Users[\\/][^\\/\s]+|' + '/Us' + 'ers/[^/\s]+|' + '/ho' + 'me/[^/\s]+')) {
            $taskFindings += [pscustomobject]@{file=$taskFile.FullName.Substring($taskSource.Length+1);line=$taskIndex+1;kind='credential-or-private-path'}
        }
    }
}
$taskFindings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $taskPublish 'privacy-findings.json') -Encoding utf8
if ($taskFindings.Count -gt 0) { throw 'Privacy scan failed; inspect local findings without publishing them' }
$taskApkSource = Join-Path $taskRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (!(Test-Path -LiteralPath $taskApkSource)) { throw 'Build the release APK first' }
$taskSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
$taskBuildTools = Get-ChildItem -LiteralPath (Join-Path $taskSdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$taskBadging = & (Join-Path $taskBuildTools.FullName 'aapt.exe') dump badging $taskApkSource
if ($LASTEXITCODE -ne 0 -or !($taskBadging -match ("^package: name='com\.findash\.fin_dash' versionCode='$taskBuild' versionName='$([regex]::Escape($taskName))'"))) {
    throw 'APK application identity or version does not match the source; rebuild first'
}
$taskApkName = "FinDash-$taskName+$taskBuild-arm64.apk"
$taskApk = Join-Path $taskAssets $taskApkName
Copy-Item -LiteralPath $taskApkSource -Destination $taskApk -Force
$taskHash = (Get-FileHash -LiteralPath $taskApk -Algorithm SHA256).Hash.ToLowerInvariant()
$taskReleaseNotes = [IO.File]::ReadAllText((Join-Path $taskRoot "docs/releases/$taskName.md"))
$taskManifest = [ordered]@{schemaVersion=1;applicationId='com.findash.fin_dash';version=$taskName;buildNumber=$taskBuild;
    sizeBytes=(Get-Item -LiteralPath $taskApk).Length;sha256=$taskHash;
    downloadUrl="https://github.com/$Repository/releases/download/v$taskName/" + [Uri]::EscapeDataString($taskApkName);
    notes="新增应用内检查更新、下载与升级。包含 Agent 批量确认、SQLite 账本与离线语音。升级保留现有账本。"}
[IO.File]::WriteAllText((Join-Path $taskAssets 'ota-manifest.json'), ($taskManifest | ConvertTo-Json -Depth 4), $taskUtf8)
[IO.File]::WriteAllText((Join-Path $taskAssets 'SHA256SUMS.txt'), "$taskHash  $taskApkName`n", $taskUtf8)
[IO.File]::WriteAllText((Join-Path $taskAssets 'release-notes.md'), $taskReleaseNotes, $taskUtf8)
Write-Output ("Prepared public snapshot: {0} source files; no matching credentials or private paths. Release v{1}, build {2}." -f $taskCopied.Count,$taskName,$taskBuild)
