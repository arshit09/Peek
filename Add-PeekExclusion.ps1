<#
.SYNOPSIS
    Tells Windows Defender to leave Peek's folder alone.

.DESCRIPTION
    Defender quarantines Peek.exe on a good many machines, as a machine-learning
    guess rather than a signature match. This adds the folder the script is
    sitting in to Defender's exclusion list, which stops that happening to
    Peek.exe and to the executables future updates put there.

    The folder is excluded, not the one file, deliberately: an update writes a
    new Peek.exe, and a per-file exclusion would not cover it.

    Run it and accept the prompt - it asks Windows for administrator rights by
    itself, because only an administrator can change Defender's settings.

    Undo it with Remove-PeekExclusion.ps1 in the same folder.

    An exclusion is a real hole in your protection. Keep Peek in a folder of its
    own so that the hole is only Peek-shaped; the script refuses to exclude
    Downloads, the Desktop, a profile root or a drive root for that reason.

.PARAMETER Force
    Exclude the folder even if it is one of the shared locations above. Only
    sensible if you know exactly what else lives there.

.PARAMETER Pause
    Wait for a keypress before closing. Set automatically when the script
    relaunches itself with administrator rights, so the window stays up long
    enough to read.

.EXAMPLE
    .\Add-PeekExclusion.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Add-PeekExclusion.ps1
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $Pause
)

$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
if (-not $folder) { $folder = (Get-Location).Path }
$folder = (Resolve-Path -LiteralPath $folder).Path.TrimEnd('\')

function Finish([int]$code) {
    if ($Pause) {
        Write-Host ''
        Write-Host 'Press any key to close...' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep 5 }
    }
    exit $code
}

Write-Host ''
Write-Host '  Peek - add a Defender exclusion' -ForegroundColor Cyan
Write-Host '  ------------------------------' -ForegroundColor DarkGray
Write-Host "  Folder: $folder"
Write-Host ''

# Everything that can be decided without administrator rights is decided first,
# so a folder that was never going to be accepted is turned down before anyone
# is made to answer a consent prompt for it.

# --- do not punch a hole in something shared -----------------------------------
$shared = @(
    $env:USERPROFILE, $env:SystemRoot, $env:SystemDrive + '\',
    $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:TEMP,
    (Join-Path $env:USERPROFILE 'Desktop'), (Join-Path $env:USERPROFILE 'Downloads'),
    (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Pictures'),
    (Join-Path $env:USERPROFILE 'Music'), (Join-Path $env:USERPROFILE 'Videos'),
    'C:\Users'
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

if ($shared -contains $folder -and -not $Force) {
    Write-Host '  That folder is shared with a great deal else.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Excluding it would stop Defender looking at everything in it, not'
    Write-Host '  just at Peek. Put Peek in a folder of its own - somewhere like'
    Write-Host "  $env:LOCALAPPDATA\Peek - and run this again from there."
    Write-Host ''
    Write-Host '  If you really did mean this folder, run it again with -Force.' -ForegroundColor DarkGray
    Finish 1
}

# --- is Defender actually the thing protecting this machine? -------------------
# Reading the settings needs no special rights, so this too is settled before
# the consent prompt.
try {
    $null = Get-MpPreference
} catch {
    Write-Host '  Windows Defender does not appear to be available on this machine.' -ForegroundColor Red
    Write-Host '  If another antivirus is in charge, add the exclusion in that instead.'
    Finish 1
}

# --- administrator rights -----------------------------------------------------
# Only an administrator can change Defender's settings, so rather than failing
# with a permissions error the script asks Windows to start it again elevated.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  Asking for administrator rights...' -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path
    $argv  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pause')
    if ($Force) { $argv += '-Force' }
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argv
    } catch {
        Write-Host '  The prompt was declined, so nothing has been changed.' -ForegroundColor Red
        Write-Host '  Defender will only take instructions from an administrator.'
        Finish 1
    }
    exit 0
}

# --- add it --------------------------------------------------------------------
$already = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath) |
           Where-Object { $_ -and $_.TrimEnd('\') -ieq $folder }

if ($already) {
    Write-Host '  That folder is already excluded. Nothing to do.' -ForegroundColor Green
} else {
    try {
        Add-MpPreference -ExclusionPath $folder
    } catch {
        Write-Host "  Defender refused the change: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  A managed machine may have this locked by group policy.'
        Finish 1
    }
    Start-Sleep -Milliseconds 400
    $confirm = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath) |
               Where-Object { $_ -and $_.TrimEnd('\') -ieq $folder }
    if (-not $confirm) {
        Write-Host '  Defender reported no error but the exclusion is not listed.' -ForegroundColor Red
        Write-Host '  Group policy or another security product may be overriding it.'
        Finish 1
    }
    Write-Host '  Added.' -ForegroundColor Green
}

Write-Host ''
Write-Host '  Defender is now ignoring:' -ForegroundColor DarkGray
foreach ($p in (Get-MpPreference).ExclusionPath | Sort-Object) {
    $mine = ($p.TrimEnd('\') -ieq $folder)
    Write-Host ("    {0}" -f $p) -ForegroundColor $(if ($mine) { 'Green' } else { 'DarkGray' })
}

Write-Host ''
Write-Host '  If Peek.exe was already taken away, restore it from Windows Security'
Write-Host '  -> Virus & threat protection -> Protection history, or just download'
Write-Host '  it again - it will be left alone now.'
Write-Host ''
Write-Host '  Undo this any time with Remove-PeekExclusion.ps1.' -ForegroundColor DarkGray
Finish 0
