param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
$taskAssets = Join-Path $taskRoot 'output/github-publication/assets'
$taskManifest = Get-Content -LiteralPath (Join-Path $taskAssets 'ota-manifest.json') -Raw | ConvertFrom-Json
$taskApkName = "FinDash-$($taskManifest.version)+$($taskManifest.buildNumber)-arm64.apk"
$taskApk = Join-Path $taskAssets $taskApkName
if ($taskManifest.downloadUrl -notlike "https://github.com/$Repository/releases/download/*" -or
    (Get-FileHash -LiteralPath $taskApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskManifest.sha256 -or
    (Get-Item -LiteralPath $taskApk).Length -ne $taskManifest.sizeBytes) { throw 'Release asset verification failed' }
if (& git -C $taskRoot status --porcelain) { throw 'Commit the release source before publishing' }
$taskSha = & git -C $taskRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Missing source commit' }
$taskRemoteSha = & gh api "repos/$Repository/commits/$taskSha" --jq .sha
if ($LASTEXITCODE -ne 0 -or $taskRemoteSha -ne $taskSha) { throw 'Release source commit has not been pushed' }
$taskTag = "v$($taskManifest.version)"
& gh release view $taskTag --repo $Repository --json tagName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'Release already exists; increment version instead of overwriting' }
& gh release create $taskTag $taskApk (Join-Path $taskAssets 'ota-manifest.json') (Join-Path $taskAssets 'SHA256SUMS.txt') --repo $Repository --target $taskSha --title "FinDash $($taskManifest.version)" --notes-file (Join-Path $taskAssets 'release-notes.md') --draft
if ($LASTEXITCODE -ne 0) { throw 'Release upload failed; inspect the draft before retrying' }
& gh release edit $taskTag --repo $Repository --draft=false --latest
if ($LASTEXITCODE -ne 0) { throw 'Draft assets uploaded but publication failed' }
& gh release view $taskTag --repo $Repository --json url,assets
