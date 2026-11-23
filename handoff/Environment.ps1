function Initialize-QgEnvironment {
  param([string]$DevEcoHome, [string]$SdkHome)
  $ErrorActionPreference = 'Stop'
  $root = Split-Path $PSScriptRoot -Parent
  $saved = Join-Path $PSScriptRoot 'local-env.json'
  if (-not $DevEcoHome -and (Test-Path -LiteralPath $saved)) {
    $local = Get-Content -LiteralPath $saved -Raw | ConvertFrom-Json
    $DevEcoHome = $local.DevEcoHome
    if (-not $SdkHome) { $SdkHome = $local.SdkHome }
  }
  if (-not $DevEcoHome) { $DevEcoHome = $env:DEVECO_STUDIO_HOME }
  if (-not $DevEcoHome) {
    foreach ($candidate in @('D:\DevEco Studio', 'C:\Program Files\Huawei\DevEco Studio', 'C:\Program Files\DevEco Studio')) {
      if (Test-Path -LiteralPath (Join-Path $candidate 'tools/hvigor/bin/hvigorw.bat')) { $DevEcoHome = $candidate; break }
    }
  }
  if (-not $DevEcoHome -or -not (Test-Path -LiteralPath $DevEcoHome)) {
    throw 'Provide -DevEcoHome with the installed DevEco Studio directory.'
  }
  $DevEcoHome = (Resolve-Path -LiteralPath $DevEcoHome).Path
  if (-not $SdkHome) { $SdkHome = Join-Path $DevEcoHome 'sdk' }
  if (-not (Test-Path -LiteralPath $SdkHome)) { throw 'HarmonyOS SDK not found. Install SDK API 26 or provide -SdkHome.' }
  $SdkHome = (Resolve-Path -LiteralPath $SdkHome).Path
  $node = Join-Path $DevEcoHome 'tools/node/node.exe'
  $hvigor = Join-Path $DevEcoHome 'tools/hvigor/bin/hvigorw.bat'
  $ohpm = Join-Path $DevEcoHome 'tools/ohpm/bin/ohpm.bat'
  foreach ($tool in @($node, $hvigor, $ohpm)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required tool not found: $tool" }
  }
  foreach ($part in @('default/openharmony/ets/oh-uni-package.json', 'default/openharmony/native/oh-uni-package.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SdkHome $part))) { throw "Required SDK component missing: $part" }
  }
  $env:DEVECO_STUDIO_HOME = $DevEcoHome
  $env:DEVECO_SDK_HOME = $SdkHome
  $env:NODE_HOME = Split-Path $node -Parent
  $env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
  $extra = @($env:NODE_HOME, (Join-Path $env:JAVA_HOME 'bin'),
    (Join-Path $DevEcoHome 'tools/ohpm/bin'),
    (Join-Path $SdkHome 'default/openharmony/previewer/common/bin'),
    (Join-Path $SdkHome 'default/hms/toolchains/lib'))
  $env:Path = ($extra -join ';') + ';' + $env:Path
  return [pscustomobject]@{ Root=$root; DevEcoHome=$DevEcoHome; SdkHome=$SdkHome; Node=$node; Hvigor=$hvigor; Ohpm=$ohpm }
}
