param([string]$DevEcoHome, [string]$SdkHome, [switch]$ReinstallDependencies)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Environment.ps1')
$qg = Initialize-QgEnvironment -DevEcoHome $DevEcoHome -SdkHome $SdkHome
Push-Location $qg.Root
try {
  & $qg.Node (Join-Path $PSScriptRoot 'configure-project.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'Portable project configuration failed.' }
  $missing = -not (Test-Path -LiteralPath 'oh_modules/@ohos/hypium/oh-package.json5') -or
    -not (Test-Path -LiteralPath 'oh_modules/@ohos/hamock/oh-package.json5') -or
    -not (Test-Path -LiteralPath 'entry/oh_modules/libqgmodule.so/index.d.ts')
  if ($ReinstallDependencies -or $missing) {
    & $qg.Ohpm install
    if ($LASTEXITCODE -ne 0) { throw 'ohpm install failed. Check SDK and network, then retry.' }
    Push-Location 'entry'
    try { & $qg.Ohpm install; if ($LASTEXITCODE -ne 0) { throw 'entry ohpm install failed.' } }
    finally { Pop-Location }
  }
  @{ DevEcoHome=$qg.DevEcoHome; SdkHome=$qg.SdkHome } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'local-env.json') -Encoding UTF8
  Write-Output 'Setup complete. Packaged signing and dependency files are ready; no global signing files were replaced.'
} finally { Pop-Location }
