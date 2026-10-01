# Run after closing Studio: an open IDE may save its old project state on exit.
$taskRoot = (Resolve-Path $taskProject).Path
# Apply the upstream Dart compatibility release after Studio has closed.
$taskStudioRoot = 'D:\PC\ENV\Android\Studio'
$taskStagedDart = Join-Path $taskStudioRoot 'system\plugins\staged-dart-503\Dart'
if (Test-Path -LiteralPath $taskStagedDart) {
  if (Get-Process studio64 -ErrorAction SilentlyContinue) { throw 'Close Android Studio before updating its Dart plugin.' }
  $taskDartPath = Join-Path $taskStudioRoot 'plugins\Dart'
  $taskDartBackup = Join-Path $taskStudioRoot ('system\plugins\Dart-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  foreach ($taskPluginPath in @($taskStagedDart, $taskDartPath, $taskDartBackup)) {
    $taskPluginAbsolute = [System.IO.Path]::GetFullPath($taskPluginPath)
    if (-not $taskPluginAbsolute.StartsWith($taskStudioRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected plugin path' }
  }
  if (Test-Path -LiteralPath $taskDartPath) {
    Move-Item -LiteralPath $taskDartPath -Destination $taskDartBackup
  }
  try { Move-Item -LiteralPath $taskStagedDart -Destination $taskDartPath }
  catch {
    if (Test-Path -LiteralPath $taskDartBackup) { Move-Item -LiteralPath $taskDartBackup -Destination $taskDartPath }
    throw
  }
}
$taskIdea = Join-Path $taskRoot '.idea'
New-Item -ItemType Directory -Path $taskIdea -Force | Out-Null
$taskOldSettings = Join-Path $taskRoot 'legacy_android\idea_before_flutter'
New-Item -ItemType Directory -Path $taskOldSettings -Force | Out-Null
foreach ($taskFileName in @('AndroidProjectSystem.xml', 'compiler.xml')) {
  $taskOldPath = Join-Path $taskIdea $taskFileName
  if (Test-Path -LiteralPath $taskOldPath) {
    $taskCheckedPath = (Resolve-Path -LiteralPath $taskOldPath).Path
    if (-not $taskCheckedPath.StartsWith($taskRoot + '\')) { throw 'Unexpected IDE config path' }
    Move-Item -LiteralPath $taskCheckedPath -Destination (Join-Path $taskOldSettings $taskFileName) -Force
  }
}
Copy-Item -LiteralPath "$PSScriptRoot\gradle.project.xml" -Destination (Join-Path $taskIdea 'gradle.xml') -Force
foreach ($taskXmlName in @('workspace.xml', 'misc.xml')) {
  $taskXmlPath = Join-Path $taskIdea $taskXmlName
  if (Test-Path -LiteralPath $taskXmlPath) {
    Copy-Item -LiteralPath $taskXmlPath -Destination (Join-Path $taskOldSettings $taskXmlName) -Force
    $taskXml = [xml](Get-Content -Raw -LiteralPath $taskXmlPath)
    foreach ($taskNode in @($taskXml.SelectNodes('/project/component[@name="ExternalProjectsData" or @name="GradleScriptDefinitionsStorage" or @name="ProjectType"]'))) {
      $taskNode.ParentNode.RemoveChild($taskNode) | Out-Null
    }
    if ($taskXmlName -eq 'workspace.xml') {
      $taskRunManager = $taskXml.SelectSingleNode('/project/component[@name="RunManager"]')
      if ($taskRunManager) { $taskRunManager.SetAttribute('selected', 'Flutter.main.dart') }
    }
    $taskXml.Save($taskXmlPath)
  }
}
$taskJavaConfig = Join-Path $taskRoot 'android\.gradle\config.properties'
New-Item -ItemType Directory -Path (Split-Path $taskJavaConfig -Parent) -Force | Out-Null
[System.IO.File]::WriteAllText($taskJavaConfig, "java.home=D:/TOOL/AndroidStudio/jbr`n", (New-Object System.Text.UTF8Encoding($false)))
