param([string]$DevEcoHome, [string]$SdkHome, [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Environment.ps1')
$qg = Initialize-QgEnvironment -DevEcoHome $DevEcoHome -SdkHome $SdkHome
Push-Location $qg.Root
try {
  & $qg.Node (Join-Path $PSScriptRoot 'configure-project.cjs')
  if ($LASTEXITCODE -ne 0) { throw 'Run Setup-Project.ps1 before building.' }
  if (-not $SkipTests) {
    & $qg.Node 'scripts/run-tests.cjs' 2>&1 | Tee-Object -FilePath (Join-Path $PSScriptRoot 'regression.log')
    if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed.' }
  }
  # Windows PowerShell 5.1 represents native stderr warnings as ErrorRecord.
  # Preserve the output but decide success by the compiler exit code.
  $previousPreference = $ErrorActionPreference
  $buildStatus = -1
  try {
    $ErrorActionPreference = 'Continue'
    & $qg.Hvigor assembleHap --mode module -p product=default --no-daemon 2>&1 |
      ForEach-Object { $_.ToString() } | Tee-Object -FilePath (Join-Path $PSScriptRoot 'build.log')
    $buildStatus = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($buildStatus -ne 0) { throw 'HAP build or signing failed. See handoff/build.log.' }
  $output = Join-Path $qg.Root 'entry/build/default/outputs/default/entry-default-signed.hap'
  if (-not (Test-Path -LiteralPath $output)) { throw 'Signed HAP was not generated.' }
  Write-Output "Signed HAP: $output"
} finally { Pop-Location }
