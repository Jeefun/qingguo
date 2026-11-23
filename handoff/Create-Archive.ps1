param(
  [Parameter(Mandatory=$true)][string]$ProjectPath,
  [Parameter(Mandatory=$true)][string]$DestinationPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
$destination = [IO.Path]::GetFullPath($DestinationPath)
if ($destination.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Put the ZIP outside the staged project to avoid including itself.'
}
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object {
  $rel = $_.FullName.Substring($root.Length + 1).Replace('\','/')
  $rel -notmatch '^entry/(build|\.cxx)/' -and $rel -notmatch '^\.hvigor/' -and
    $rel -ne 'handoff/local-env.json' -and $rel -ne 'MANIFEST.sha256'
} | Sort-Object FullName)
$manifest = foreach ($file in $files) {
  $rel = $file.FullName.Substring($root.Length + 1).Replace('\','/')
  (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $rel
}
$manifestPath = Join-Path $root 'MANIFEST.sha256'
[IO.File]::WriteAllLines($manifestPath, [string[]]$manifest, [Text.UTF8Encoding]::new($false))
$files += Get-Item -LiteralPath $manifestPath
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
$out = [IO.File]::Open($destination, [IO.FileMode]::Create)
$zip = [IO.Compression.ZipArchive]::new($out, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
try {
  foreach ($file in $files) {
    $rel = $file.FullName.Substring($root.Length + 1).Replace('\','/')
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName,
      ('qingguoapp/' + $rel), [IO.Compression.CompressionLevel]::Optimal)
  }
} finally { $zip.Dispose(); $out.Dispose() }
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($destination + '.sha256.txt'),
  ($hash + '  ' + [IO.Path]::GetFileName($destination) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ Archive=$destination; Files=$files.Count; Bytes=(Get-Item -LiteralPath $destination).Length; SHA256=$hash } | ConvertTo-Json
