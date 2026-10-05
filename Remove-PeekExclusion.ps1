<#
.SYNOPSIS
    Puts Windows Defender back to watching Peek's folder.

.DESCRIPTION
    Undoes Add-PeekExclusion.ps1: removes the folder this script is sitting in
    from Defender's exclusion list, so the folder is scanned again like any
    other.

    Run it and accept the prompt - it asks Windows for administrator rights by
    itself, because only an administrator can change Defender's settings.

    Worth knowing before you do: with the exclusion gone, Defender may well
    quarantine Peek.exe again, for the same machine-learning guess it made the
    first time. Running Peek.ahk instead avoids the whole question - there is no
    executable on that route for Defender to object to.

.PARAMETER Pause
    Wait for a keypress before closing. Set automatically when the script
    relaunches itself with administrator rights, so the window stays up long
    enough to read.

.EXAMPLE
    .\Remove-PeekExclusion.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Remove-PeekExclusion.ps1
#>
[CmdletBinding()]
param(
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
Write-Host '  Peek - remove the Defender exclusion' -ForegroundColor Cyan
Write-Host '  -----------------------------------' -ForegroundColor DarkGray
Write-Host "  Folder: $folder"
Write-Host ''

# --- is Defender actually here? ------------------------------------------------
try {
    $null = Get-MpPreference
} catch {
    Write-Host '  Windows Defender does not appear to be available on this machine.' -ForegroundColor Red
    Write-Host '  There is nothing here to undo.'
    Finish 1
}

# --- administrator rights -----------------------------------------------------
# Asked for before the list is read, not after. Without administrator rights
# Get-MpPreference does not return the exclusions at all - it returns the single
# string "N/A: Must be an administrator to view exclusions" in their place - so
# checking first would decide there was nothing to remove every single time.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  Asking for administrator rights...' -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path
    $argv  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Pause')
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argv
    } catch {
        Write-Host '  The prompt was declined, so nothing has been changed.' -ForegroundColor Red
        Write-Host '  Defender will only take instructions from an administrator.'
        Finish 1
    }
    exit 0
}

# --- remove it -----------------------------------------------------------------
$present = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath) |
           Where-Object { $_ -and $_.TrimEnd('\') -ieq $folder }

if (-not $present) {
    Write-Host '  That folder is not excluded, so there is nothing to remove.' -ForegroundColor Green
} else {
    try {
        # Removed by the spelling Defender stored, not the one worked out here,
        # so a trailing slash or different casing cannot leave it behind.
        foreach ($p in $present) { Remove-MpPreference -ExclusionPath $p }
    } catch {
        Write-Host "  Defender refused the change: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  A managed machine may have this locked by group policy.'
        Finish 1
    }
    Start-Sleep -Milliseconds 400
    $still = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath) |
             Where-Object { $_ -and $_.TrimEnd('\') -ieq $folder }
    if ($still) {
        Write-Host '  Defender reported no error but the exclusion is still listed.' -ForegroundColor Red
        Write-Host '  Group policy may be putting it back.'
        Finish 1
    }
    Write-Host '  Removed. Defender is watching that folder again.' -ForegroundColor Green
}

$rest = @((Get-MpPreference).ExclusionPath)
Write-Host ''
if ($rest.Count) {
    Write-Host '  Still excluded elsewhere:' -ForegroundColor DarkGray
    foreach ($p in $rest | Sort-Object) { Write-Host "    $p" -ForegroundColor DarkGray }
} else {
    Write-Host '  No folders are excluded now.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Defender may quarantine Peek.exe again from here. Running Peek.ahk'
Write-Host '  instead sidesteps that entirely - see the README.'
Finish 0
