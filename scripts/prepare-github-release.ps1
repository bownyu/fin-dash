param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskPublish = Join-Path $taskRoot 'output/github-publication'
$taskAssets = Join-Path $taskPublish 'assets'
$taskVersionText = [IO.File]::ReadAllText((Join-Path $taskRoot 'pubspec.yaml'))
$taskVersion = [regex]::Match($taskVersionText, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (!$taskVersion.Success) { throw 'Invalid application version' }
$taskName = $taskVersion.Groups[1].Value
$taskBuild = [int]$taskVersion.Groups[2].Value
New-Item -ItemType Directory -Path $taskAssets -Force | Out-Null
# The repository itself is public: scan every tracked file before releasing.
$taskFiles = & git -C $taskRoot -c core.quotepath=false ls-files
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate source files' }
$taskDeny = '(?i)(^|/)(private|sensevoice-small)(/|$)|(^|/)(key\.properties|local\.properties|\.env(?:\..*)?)$|\.(db|sqlite3?|jks|keystore|p12|pem|xlsx?|csv|apk|aab|aar|onnx|log)$'
$taskFindings = @()
foreach ($taskFile in $taskFiles) {
    if ($taskFile -match $taskDeny) {
        $taskFindings += [pscustomobject]@{file=$taskFile;line=0;kind='private-file'}
        continue
    }
    if ($taskFile -match '\.(png|webp|jpg|ico|jar)$') { continue }
    $taskPath = Join-Path $taskRoot $taskFile
    if (!(Test-Path -LiteralPath $taskPath -PathType Leaf)) { continue }
    $taskLines = [IO.File]::ReadAllLines($taskPath)
    for ($taskIndex=0; $taskIndex -lt $taskLines.Length; $taskIndex++) {
        if ($taskLines[$taskIndex] -match ('gh[pousr]_[A-Za-z0-9_]{25,}|github_pat_[A-Za-z0-9_]{30,}|sk-(?:proj-|nvapi-)?[A-Za-z0-9_-]{25,}|(?i)[A-Z]:[\\/]Users[\\/][^\\/\s]+|' + '/Us' + 'ers/[^/\s]+|' + '/ho' + 'me/[^/\s]+')) {
            $taskFindings += [pscustomobject]@{file=$taskFile;line=$taskIndex+1;kind='credential-or-private-path'}
        }
    }
}
ConvertTo-Json -InputObject @($taskFindings) -Depth 3 | Set-Content -LiteralPath (Join-Path $taskPublish 'privacy-findings.json') -Encoding utf8
if ($taskFindings.Count -gt 0) { throw 'Privacy scan failed; inspect local findings without publishing them' }
$taskApkSource = Join-Path $taskRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (!(Test-Path -LiteralPath $taskApkSource)) { throw 'Build the release APK first' }
$taskSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
$taskBuildTools = Get-ChildItem -LiteralPath (Join-Path $taskSdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$taskBadging = & (Join-Path $taskBuildTools.FullName 'aapt.exe') dump badging $taskApkSource
if ($LASTEXITCODE -ne 0 -or !($taskBadging -match ("^package: name='com\.findash\.fin_dash' versionCode='$taskBuild' versionName='$([regex]::Escape($taskName))'"))) {
    throw 'APK application identity or version does not match the source; rebuild first'
}
$taskUtf8 = New-Object System.Text.UTF8Encoding($false)
$taskApkName = "FinDash-$taskName+$taskBuild-arm64.apk"
$taskApk = Join-Path $taskAssets $taskApkName
Copy-Item -LiteralPath $taskApkSource -Destination $taskApk -Force
$taskHash = (Get-FileHash -LiteralPath $taskApk -Algorithm SHA256).Hash.ToLowerInvariant()
$taskReleaseNotes = [IO.File]::ReadAllText((Join-Path $taskRoot "docs/releases/$taskName.md"))
$taskManifest = [ordered]@{schemaVersion=1;applicationId='com.findash.fin_dash';version=$taskName;buildNumber=$taskBuild;
    sizeBytes=(Get-Item -LiteralPath $taskApk).Length;sha256=$taskHash;
    downloadUrl="https://github.com/$Repository/releases/download/v$taskName/" + [Uri]::EscapeDataString($taskApkName);
    notes=$taskReleaseNotes}
[IO.File]::WriteAllText((Join-Path $taskAssets 'ota-manifest.json'), ($taskManifest | ConvertTo-Json -Depth 4), $taskUtf8)
[IO.File]::WriteAllText((Join-Path $taskAssets 'SHA256SUMS.txt'), "$taskHash  $taskApkName`n", $taskUtf8)
[IO.File]::WriteAllText((Join-Path $taskAssets 'release-notes.md'), $taskReleaseNotes, $taskUtf8)
Write-Output ("Prepared release assets: {0} tracked files scanned; no matching credentials or private paths. Release v{1}, build {2}." -f $taskFiles.Count,$taskName,$taskBuild)
