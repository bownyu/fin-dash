$ErrorActionPreference = 'Stop'
$taskProject = Split-Path $PSScriptRoot -Parent
$env:ANDROID_HOME = 'D:\PC\ENV\Android\SDK'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:JAVA_HOME = 'D:\TOOL\AndroidStudio\jbr'
$env:PUB_CACHE = Join-Path $taskProject '.pub-cache'
$env:GRADLE_USER_HOME = Join-Path $taskProject '.gradle-home'
$env:ANDROID_USER_HOME = 'D:\PC\ENV\Android\user-home'
$env:ANDROID_AVD_HOME = 'D:\PC\ENV\Android\avd'
$env:STUDIO_PROPERTIES = 'D:\PC\ENV\Android\Studio\studio.properties'
$env:TEMP = Join-Path $taskProject '.dart_tool\temp'
$env:TMP = $env:TEMP
$env:Path = 'D:\PC\ENV\Flutter\bin;' + $env:JAVA_HOME + '\bin;' + $env:ANDROID_HOME + '\platform-tools;' + $env:Path
foreach ($taskPath in @($env:PUB_CACHE, $env:GRADLE_USER_HOME, $env:ANDROID_USER_HOME, $env:ANDROID_AVD_HOME, $env:TEMP)) {
  New-Item -ItemType Directory -Path $taskPath -Force | Out-Null
}
