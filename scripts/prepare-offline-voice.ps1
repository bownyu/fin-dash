$ErrorActionPreference = 'Stop'
$voiceProject = Split-Path $PSScriptRoot -Parent
$voiceLock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'offline-voice.lock.json') -Raw | ConvertFrom-Json
$voiceCache = Join-Path $voiceProject 'build\offline-voice'
$voiceLibs = Join-Path $voiceProject 'android\app\libs'
$voiceAssets = Join-Path $voiceProject 'android\app\src\main\assets\sensevoice-small'
foreach ($voicePath in @($voiceCache, $voiceLibs, $voiceAssets)) {
  New-Item -ItemType Directory -Path $voicePath -Force | Out-Null
}

function Test-VoiceHash([string]$Path, [string]$Hash) {
  return (Test-Path -LiteralPath $Path -PathType Leaf) -and
    ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash)
}
function Get-VoiceDownload([string]$Url, [string]$Path, [string]$Hash) {
  if (Test-VoiceHash $Path $Hash) { return }
  Write-Host '正在准备安装包内的离线语音资源…'
  $voicePartial = "$Path.part"
  & curl.exe --fail --location --silent --show-error --retry 3 --connect-timeout 30 --max-time 600 $Url -o $voicePartial
  if ($LASTEXITCODE -ne 0) { throw "语音资源下载失败：$Url" }
  if (!(Test-VoiceHash $voicePartial $Hash)) { throw "语音资源校验失败：$Url" }
  Move-Item -LiteralPath $voicePartial -Destination $Path -Force
}

$voiceAar = Join-Path $voiceLibs "sherpa-onnx-$($voiceLock.runtime.version).aar"
$voiceCachedAar = Join-Path $voiceCache "sherpa-onnx-$($voiceLock.runtime.version).aar"
if (!(Test-VoiceHash $voiceAar $voiceLock.runtime.sha256)) {
  Get-VoiceDownload $voiceLock.runtime.url $voiceCachedAar $voiceLock.runtime.sha256
  Copy-Item -LiteralPath $voiceCachedAar -Destination $voiceAar -Force
}
$voiceMissing = @($voiceLock.model.files.PSObject.Properties | Where-Object {
  !(Test-VoiceHash (Join-Path $voiceAssets $_.Name) $_.Value)
})
if ($voiceMissing.Count -gt 0) {
  $voiceArchive = Join-Path $voiceCache 'sensevoice.tar.bz2'
  Get-VoiceDownload $voiceLock.model.url $voiceArchive $voiceLock.model.sha256
  & tar -xjf $voiceArchive -C $voiceCache
  if ($LASTEXITCODE -ne 0) { throw '离线模型解压失败' }
  foreach ($voiceFile in $voiceLock.model.files.PSObject.Properties) {
    $voiceSource = Join-Path (Join-Path $voiceCache $voiceLock.model.archiveDirectory) $voiceFile.Name
    if (!(Test-VoiceHash $voiceSource $voiceFile.Value)) { throw "模型文件校验失败：$($voiceFile.Name)" }
    Copy-Item -LiteralPath $voiceSource -Destination (Join-Path $voiceAssets $voiceFile.Name) -Force
  }
}
$voiceVad = Join-Path $voiceAssets 'silero_vad.onnx'
$voiceCachedVad = Join-Path $voiceCache 'silero_vad.onnx'
if (!(Test-VoiceHash $voiceVad $voiceLock.vad.sha256)) {
  Get-VoiceDownload $voiceLock.vad.url $voiceCachedVad $voiceLock.vad.sha256
  Copy-Item -LiteralPath $voiceCachedVad -Destination $voiceVad -Force
}
Write-Host '离线中文语音资源已就绪，将随 APK 一起安装。'
