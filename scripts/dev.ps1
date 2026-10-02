param(
  [ValidateSet('doctor', 'deps', 'analyze', 'test', 'test-native', 'voice-assets', 'build-apk', 'run', 'preview', 'studio')]
  [string]$Action = 'doctor',
  [string]$Device = '',
  [switch]$Demo
)
. "$PSScriptRoot\environment.ps1"
Push-Location $taskProject
try {
  $taskDemoArgs = @()
  if ($Demo) { $taskDemoArgs = @('--dart-define=DEMO=true') }
  if ($Action -in @('voice-assets', 'test-native', 'build-apk', 'run', 'studio')) {
    & "$PSScriptRoot\prepare-offline-voice.ps1"
  }
  switch ($Action) {
    'doctor' { & flutter doctor -v; & flutter devices }
    'deps' { & flutter pub get }
    'voice-assets' { return }
    'analyze' { & flutter analyze }
    'test' { & flutter test }
    'test-native' { & .\android\gradlew.bat -p android :app:testDebugUnitTest --console=plain --no-daemon }
    'build-apk' { & flutter build apk --release --target-platform android-arm64 @taskDemoArgs }
    'preview' { & flutter run -d chrome @taskDemoArgs }
    'run' {
      if ($Device) { & flutter run -d $Device @taskDemoArgs }
      else { & flutter run @taskDemoArgs }
    }
    'studio' {
      if (Get-Process studio64 -ErrorAction SilentlyContinue) {
        throw '请先保存修改并退出 Android Studio，再使用此入口打开工程，以便读取项目依赖缓存配置。'
      }
      . "$PSScriptRoot\prepare-studio.ps1"
      Start-Process -FilePath 'D:\TOOL\AndroidStudio\bin\studio64.exe' -ArgumentList ('"' + $taskProject + '"')
      return
    }
  }
  if ($LASTEXITCODE -ne 0) { throw "Development command failed: $LASTEXITCODE" }
} finally { Pop-Location }
