# Windows: put the original SSDT-EC.aml (EC0 hidden from macOS) back on the macOS ESP.
# Run in an Administrator PowerShell:  powershell -ExecutionPolicy Bypass -File restore-ec-windows.ps1
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$b = [Convert]::FromBase64String('U1NEVMQAAAAC8ENPUlAgAFNzZHRFQwAAABAAAElOVEwnCSQgoCoAFVwvA19TQl9QQzAwTFBDQgYAFVwvBF9TQl9QQzAwTFBDQkVDMF8GABAwXC8EX1NCX1BDMDBMUENCRUMwXxQbX1NUQQCgD19PU0kNRGFyd2luAKQAoQSkCg8QQwRcLwNfU0JfUEMwMExQQ0JbgjBFQ19fCF9ISUQNQUNJRDAwMDEAFBtfU1RBAKAQX09TSQ1EYXJ3aW4ApAoPoQOkAA==')
$sha = '04a94d552659ca57acc8859c3e85712e6fd867693fe3090d84193f934d1afea1'
function Sha([byte[]]$x) { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($x) | ForEach-Object { $_.ToString('x2') }) }
if ((Sha $b) -ne $sha) { throw 'embedded data corrupt' }
if (-not $env:ESP_GUID) { throw 'set $env:ESP_GUID to the partition GUID of the macOS ESP first' }
$p = Get-Partition | Where-Object { $_.Guid -eq ('{' + $env:ESP_GUID.Trim('{}') + '}') }
if (-not $p) { throw "macOS ESP (partition GUID $env:ESP_GUID) not found" }
$vol = $p.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
$used = (Get-PSDrive -PSProvider FileSystem).Name
$L = (@('Q','R','S','T','U','V','W') | Where-Object { $used -notcontains $_ } | Select-Object -First 1) + ':'
mountvol $L $vol
try {
  $f = "$L\EFI\OC\ACPI\SSDT-EC.aml"
  if (-not (Test-Path $f)) { throw "$f not found" }
  Copy-Item $f "$env:TEMP\SSDT-EC.patched.aml" -Force
  [IO.File]::WriteAllBytes($f, $b)
  if ((Sha ([IO.File]::ReadAllBytes($f))) -ne $sha) { throw 'read-back differs' }
  Write-Host 'OK: original SSDT-EC.aml restored. Reboot into macOS.'
} finally { mountvol $L /D }
