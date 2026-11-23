$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot -Parent)).Path
$manifest = Join-Path $root 'MANIFEST.sha256'
if (-not (Test-Path -LiteralPath $manifest)) { throw 'MANIFEST.sha256 not found. Run from the extracted migration package.' }
$count = 0
foreach ($line in Get-Content -LiteralPath $manifest -Encoding UTF8) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid manifest row.' }
  $expected = $Matches[1]
  $relative = $Matches[2]
  $file = [IO.Path]::GetFullPath((Join-Path $root $relative))
  if (-not $file.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Manifest path is outside the project.'
  }
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing file: $relative" }
  if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw "Checksum mismatch: $relative"
  }
  $count++
}
Write-Output "Verified $count project files. Run this before setup or editing; later local changes are expected to alter checksums."
