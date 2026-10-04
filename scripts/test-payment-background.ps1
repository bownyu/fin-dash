param(
  [Parameter(Mandatory=$true)][ValidatePattern('^emulator-\d+$')][string]$Device,
  [switch]$SkipBuild
)
. "$PSScriptRoot\environment.ps1"
Push-Location $taskProject
try {
  function Invoke-CaptureAdb([string[]]$Arguments) {
    $taskOutput = & adb -s $Device @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($taskOutput -join "`n") }
    return $taskOutput
  }
  function Invoke-CapturePhase([string]$Phase) {
    $taskOutput = Invoke-CaptureAdb @('shell','am','instrument','-w','-e','mode',$Phase,
      'com.findash.fin_dash.validation.test/com.findash.fin_dash.PaymentCaptureInstrumentation')
    if (($taskOutput -join "`n") -notmatch "result=$Phase passed") { throw ($taskOutput -join "`n") }
    Write-Output "Capture device check passed: $Phase"
  }
  function Get-CaptureProbe([string]$Mode = 'status') {
    return (Invoke-CaptureAdb @('shell','am','broadcast','-n',
      'com.findash.fin_dash.validation/com.findash.fin_dash.PaymentCaptureProbeReceiver',
      '--es','mode',$Mode)) -join "`n"
  }
  if (((Invoke-CaptureAdb @('shell','getprop','ro.kernel.qemu')) -join '').Trim() -ne '1') {
    throw 'Run capture validation on a disposable emulator only.'
  }
  if (!$SkipBuild) {
    & "$PSScriptRoot\prepare-offline-voice.ps1"
    & .\android\gradlew.bat -p android :app:assembleDebug :app:assembleDebugAndroidTest -PfindashBackgroundValidation=true '-Dorg.gradle.jvmargs=-Xmx1536m' --max-workers=1 --console=plain --no-daemon
    if ($LASTEXITCODE -ne 0) { throw 'Validation APK build failed.' }
  }
  Invoke-CaptureAdb @('install','-r','build/app/outputs/apk/debug/app-debug.apk') | Out-Null
  Invoke-CaptureAdb @('install','-r','build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk') | Out-Null
  Invoke-CapturePhase 'seed'
  Invoke-CapturePhase 'ipc'
  Invoke-CaptureAdb @('shell','cmd','notification','allow_listener',
    'com.findash.fin_dash.validation/com.findash.fin_dash.PaymentNotificationListener') | Out-Null
  Invoke-CapturePhase 'enable'
  Invoke-CaptureAdb @('shell','am','start','-W','-n',
    'com.findash.fin_dash.validation/com.findash.fin_dash.MainActivity') | Out-Null
  Invoke-CaptureAdb @('shell','input','keyevent','KEYCODE_HOME') | Out-Null
  $taskBefore = Get-CaptureProbe
  if ($taskBefore -notmatch 'connected=true,queued=0,pid=(\d+)') { throw $taskBefore }
  $taskCapturePid = $Matches[1]
  $taskMainPid = ((Invoke-CaptureAdb @('shell','pidof','com.findash.fin_dash.validation')) -join '').Trim()
  if ($taskMainPid -notmatch '^\d+$' -or $taskMainPid -eq $taskCapturePid) { throw 'Expected separate main and capture processes.' }
  Invoke-CaptureAdb @('shell','run-as','com.findash.fin_dash.validation','kill','-9',$taskMainPid) | Out-Null
  $taskAfter = Get-CaptureProbe
  if ($taskAfter -notmatch "connected=true,queued=0,pid=$taskCapturePid") { throw 'Capture did not survive main-process termination.' }
  $taskInjected = Get-CaptureProbe 'inject'
  if ($taskInjected -notmatch 'synthetic payment saved') { throw $taskInjected }
  Start-Sleep -Seconds 12
  $taskMaps = (Invoke-CaptureAdb @('shell','run-as','com.findash.fin_dash.validation','cat',"/proc/$taskCapturePid/maps")) -join "`n"
  if ($taskMaps -match 'libflutter\.so|sherpa') { throw 'Capture process loaded a heavy runtime.' }
  $taskThreads = (Invoke-CaptureAdb @('shell',"run-as com.findash.fin_dash.validation sh -c 'cat /proc/$taskCapturePid/task/*/comm'")) -join "`n"
  # Linux thread names may retain the first or last 15 characters of the Java name.
  if ($taskThreads -match 'payment-capture|capture-worker') { throw 'Capture worker did not release after idle timeout.' }
  $taskMemory = (Invoke-CaptureAdb @('shell','dumpsys','meminfo',$taskCapturePid)) -join "`n"
  $taskPss = [regex]::Match($taskMemory, 'TOTAL PSS:\s*(\d+)').Groups[1].Value
  Write-Output "Capture survived main PID $taskMainPid termination; no Flutter/ASR library or idle capture worker. Capture PSS: $taskPss KiB."
  Invoke-CapturePhase 'capture'
  # Shell UID must not be able to read the production-style private provider.
  $taskPrivate = & adb -s $Device shell content call --uri content://com.findash.fin_dash.validation.payment_capture --method status 2>&1
  if (($taskPrivate -join "`n") -notmatch 'Permission Denial|SecurityException') { throw 'Capture provider was accessible from shell UID.' }
  Write-Output 'Private provider rejects another UID. All capture device checks passed.'
} finally {
  Pop-Location
}
