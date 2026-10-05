<#
.SYNOPSIS
    Regenerates the base64 icon embedded in Peek.ahk.

.DESCRIPTION
    Peek.ahk carries its own icon so that running the script - rather than the
    compiled executable - still shows Peek in the tray and on every window. The
    copy lives in IconData() at the bottom of Peek.ahk, as base64.

    Only the sizes something asks for at run time are embedded, 16 through 64.
    The 128 and 256 pixel images in Peek.ico are for Explorer's larger views and
    would more than double the blob for nothing.

    Run this after changing Peek.ico, then replace the lines between "(Join" and
    the closing ")" in IconData() with what it prints.

.EXAMPLE
    .\tools\Embed-Icon.ps1
    .\tools\Embed-Icon.ps1 -Icon ..\Peek.ico -OutFile embedded.txt
#>
[CmdletBinding()]
param(
    [string]   $Icon    = (Join-Path $PSScriptRoot '..\Peek.ico'),
    [int[]]    $Sizes   = @(16, 24, 32, 48, 64),
    [int]      $Width   = 76,
    [string]   $OutFile
)

$ErrorActionPreference = 'Stop'
$Icon = (Resolve-Path -LiteralPath $Icon).Path

$b = [IO.File]::ReadAllBytes($Icon)
if ($b.Length -lt 6 -or [BitConverter]::ToUInt16($b, 2) -ne 1) {
    throw "$Icon is not an .ico file."
}
$count = [BitConverter]::ToUInt16($b, 4)

# An .ico is a 6-byte header, then one 16-byte directory entry per image, then
# the image data. Dropping an image means copying the entries we are keeping and
# rewriting each one's offset, because the data after it has moved up.
$keep = New-Object Collections.Generic.List[object]
for ($i = 0; $i -lt $count; $i++) {
    $o = 6 + $i * 16
    $w = if ($b[$o] -eq 0) { 256 } else { [int]$b[$o] }
    if ($Sizes -contains $w) {
        $entry = New-Object byte[] 16
        [Array]::Copy($b, $o, $entry, 0, 16)
        $keep.Add([pscustomobject]@{
            Entry = $entry
            Size  = [int][BitConverter]::ToUInt32($b, $o + 8)
            Off   = [int][BitConverter]::ToUInt32($b, $o + 12)
            W     = $w
        })
    }
}
if ($keep.Count -eq 0) { throw "None of the requested sizes are in $Icon." }

$out = New-Object Collections.Generic.List[byte]
$out.AddRange([byte[]]@(0, 0, 1, 0))
$out.AddRange([BitConverter]::GetBytes([UInt16]$keep.Count))
$dataOff = 6 + 16 * $keep.Count
foreach ($k in $keep) {
    [Array]::Copy([BitConverter]::GetBytes([UInt32]$k.Size), 0, $k.Entry, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([UInt32]$dataOff), 0, $k.Entry, 12, 4)
    $out.AddRange($k.Entry)
    $dataOff += $k.Size
}
foreach ($k in $keep) {
    $img = New-Object byte[] $k.Size
    [Array]::Copy($b, $k.Off, $img, 0, $k.Size)
    $out.AddRange($img)
}

$bytes = $out.ToArray()
$b64 = [Convert]::ToBase64String($bytes)
$lines = for ($i = 0; $i -lt $b64.Length; $i += $Width) {
    $b64.Substring($i, [Math]::Min($Width, $b64.Length - $i))
}

Write-Host ("kept {0} of {1} images ({2}) - {3} bytes, {4} base64 lines" -f `
    $keep.Count, $count, (($keep | ForEach-Object { "$($_.W)px" }) -join ', '),
    $bytes.Length, $lines.Count) -ForegroundColor Green
Write-Host "paste the following between `"(Join`" and `")`" in IconData():`n"

if ($OutFile) {
    $lines | Set-Content -LiteralPath $OutFile -Encoding ascii
    Write-Host "written to $OutFile"
} else {
    $lines
}
