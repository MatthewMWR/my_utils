## The primary function to use here is Install-MachineBadge. For example:
##
## Import-Module .\machine_tray_badge.psm1
## Install-MachineBadge -Context Corp
##
## This installs a tray icon launcher at logon. The icon shows:
## - a 5px Corp/Personal context strip at the bottom
## - an 8x8 hostname-seeded randomart pattern over a machine-specific color
##
## You can optionally set the machine color with -MachineColor ff0000.
## By default, machine color is derived from hostname.
##
## By default Install-MachineBadge also launches the badge immediately.
## To skip immediate launch, use -InstallOnly.

Set-StrictMode -Version Latest

function Ensure-MachineBadgeRuntime {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Win32 cleanup for icon handles
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern bool DestroyIcon(IntPtr handle);
}
"@ -ErrorAction SilentlyContinue
}

function Get-MachineBadgeProfileColor {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Corp','Personal')]
        [string]$Context
    )

    if ($Context -eq 'Corp') {
        return [System.Drawing.Color]::FromArgb(255, 0, 60, 140)   # dark blue
    }

    return [System.Drawing.Color]::FromArgb(255, 235, 120, 0)      # orange
}

function Get-MachineBadgeColorFromHex {
    param(
        [Parameter(Mandatory)]
        [string]$HexColor
    )

    $hexColor = $HexColor -replace '^#', ''
    $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
    $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
    $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)

    [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function Get-MachineBadgeColorHexFromHostname {
    param(
        [Parameter(Mandatory)]
        [string]$Hostname
    )

    $h = [Math]::Abs($Hostname.GetHashCode())
    # Ensure integer math for PS 5.1 composite formatting (X2 requires integral types)
    $r = ([int]($h % 156)) + 50
    $g = ([int](([int]($h / 256))   % 156)) + 50
    $b = ([int](([int]($h / 65536)) % 156)) + 50
    ('#{0:X2}{1:X2}{2:X2}' -f $r,$g,$b)
}

function Get-MachineBadgeWalkVisits {
    param(
        [Parameter(Mandatory)]
        [string]$HostId,

        [Parameter(Mandatory)]
        [int]$GridCols,

        [Parameter(Mandatory)]
        [int]$GridRows,

        [Parameter(Mandatory)]
        [int]$TargetSteps
    )

    $visits = New-Object 'int[,]' $GridCols, $GridRows
    $x = [int]($GridCols / 2)
    $y = [int]($GridRows / 2)
    $visits[$x, $y]++

    # Repeat hash output deterministically so the walk has enough steps for a dense pattern
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($HostId))
        $byteIndex = 0
        $steps = 0

        while ($steps -lt $TargetSteps) {
            if ($byteIndex -ge $hashBytes.Length) {
                $hashBytes = $sha.ComputeHash($hashBytes)
                $byteIndex = 0
            }

            $byte = $hashBytes[$byteIndex]
            $byteIndex++

            for ($shift = 0; $shift -le 6 -and $steps -lt $TargetSteps; $shift += 2) {
                $dir = ($byte -shr $shift) -band 0x3
                switch ($dir) {
                    0 { $dx = -1; $dy = -1 }
                    1 { $dx = 1;  $dy = -1 }
                    2 { $dx = -1; $dy = 1 }
                    default { $dx = 1; $dy = 1 }
                }

                $x = [Math]::Max(0, [Math]::Min(($GridCols - 1), ($x + $dx)))
                $y = [Math]::Max(0, [Math]::Min(($GridRows - 1), ($y + $dy)))
                $visits[$x, $y]++
                $steps++
            }
        }
    } finally {
        $sha.Dispose()
    }

    [pscustomobject]@{
        Visits = $visits
        EndX = $x
        EndY = $y
    }
}

function New-MachineBadgeIdentityIcon {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Corp','Personal')]
        [string]$Context,

        [Parameter(Mandatory)]
        [System.Drawing.Color]$MachineColor,

        [Parameter(Mandatory)]
        [string]$HostId
    )

    $profileColor = Get-MachineBadgeProfileColor -Context $Context
    $machineColor = $MachineColor

    $size = 32
    $renderSize = 16
    $contextHeight = 5
    $renderContextHeight = [Math]::Max(2, [int][Math]::Round(($contextHeight * $renderSize) / $size))

    $bmp = New-Object System.Drawing.Bitmap $size,$size,([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.Clear([System.Drawing.Color]::Transparent)

    $renderBmp = New-Object System.Drawing.Bitmap $renderSize,$renderSize,([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rg = [System.Drawing.Graphics]::FromImage($renderBmp)
    $rg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $rg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $rg.Clear([System.Drawing.Color]::Transparent)

    # Bottom strip for Corp/Personal context
    $profileBrush = New-Object System.Drawing.SolidBrush $profileColor
    $rg.FillRectangle($profileBrush, 0, ($renderSize - $renderContextHeight), $renderSize, $renderContextHeight)

    # Machine area base color
    $machineBrush = New-Object System.Drawing.SolidBrush $machineColor
    $rg.FillRectangle($machineBrush, 0, 0, $renderSize, ($renderSize - $renderContextHeight))

    if ([string]::IsNullOrWhiteSpace($HostId)) { $HostId = 'unknown-host' }
    $machineAreaWidth = $renderSize
    $machineAreaHeight = ($renderSize - $renderContextHeight)
    $gridCols = 8
    $gridRows = 8
    $targetSteps = ($gridCols * $gridRows * 3)

    $walk = Get-MachineBadgeWalkVisits -HostId $HostId -GridCols $gridCols -GridRows $gridRows -TargetSteps $targetSteps
    $visits = $walk.Visits
    $x = $walk.EndX
    $y = $walk.EndY

    $luma = (0.299 * $machineColor.R) + (0.587 * $machineColor.G) + (0.114 * $machineColor.B)
    $highColor = if ($luma -lt 128) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black }
    $midColor = if ($luma -lt 128) {
        [System.Drawing.Color]::FromArgb(255, 175, 175, 175)
    } else {
        [System.Drawing.Color]::FromArgb(255, 80, 80, 80)
    }

    $highBrush = New-Object System.Drawing.SolidBrush $highColor
    $midBrush = New-Object System.Drawing.SolidBrush $midColor

    for ($ix = 0; $ix -lt $gridCols; $ix++) {
        $x0 = [int][Math]::Floor(($ix * $machineAreaWidth) / $gridCols)
        $x1 = [int][Math]::Floor((($ix + 1) * $machineAreaWidth) / $gridCols)
        if ($x1 -le $x0) { $x1 = $x0 + 1 }
        $w = $x1 - $x0

        for ($iy = 0; $iy -lt $gridRows; $iy++) {
            $v = $visits[$ix, $iy]
            if ($v -le 0) { continue }

            $y0 = [int][Math]::Floor(($iy * $machineAreaHeight) / $gridRows)
            $y1 = [int][Math]::Floor((($iy + 1) * $machineAreaHeight) / $gridRows)
            if ($y1 -le $y0) { $y1 = $y0 + 1 }
            $h = $y1 - $y0

            $brush = if ($v -gt 1) { $highBrush } else { $midBrush }
            $rg.FillRectangle($brush, $x0, $y0, $w, $h)
        }
    }

    # Emphasize walk endpoint with context color marker in its 8x8 cell
    $endpointX0 = [int][Math]::Floor(($x * $machineAreaWidth) / $gridCols)
    $endpointX1 = [int][Math]::Floor((($x + 1) * $machineAreaWidth) / $gridCols)
    if ($endpointX1 -le $endpointX0) { $endpointX1 = $endpointX0 + 1 }
    $endpointY0 = [int][Math]::Floor(($y * $machineAreaHeight) / $gridRows)
    $endpointY1 = [int][Math]::Floor((($y + 1) * $machineAreaHeight) / $gridRows)
    if ($endpointY1 -le $endpointY0) { $endpointY1 = $endpointY0 + 1 }

    $endpointBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, $profileColor.R, $profileColor.G, $profileColor.B))
    $rg.FillRectangle($endpointBrush, $endpointX0, $endpointY0, ($endpointX1 - $endpointX0), ($endpointY1 - $endpointY0))
    $endpointBrush.Dispose()

    $highBrush.Dispose()
    $midBrush.Dispose()

    # Upscale with nearest-neighbor to keep edges crisp
    $destRect = New-Object System.Drawing.Rectangle 0,0,$size,$size
    $srcRect = New-Object System.Drawing.Rectangle 0,0,$renderSize,$renderSize
    $g.DrawImage($renderBmp, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)

    # Convert bitmap -> icon safely
    $hIcon = $bmp.GetHicon()
    $tmpIcon = [System.Drawing.Icon]::FromHandle($hIcon)
    $icon = [System.Drawing.Icon]$tmpIcon.Clone()
    [Win32]::DestroyIcon($hIcon) | Out-Null
    $tmpIcon.Dispose()

    $rg.Dispose()
    $g.Dispose()
    $renderBmp.Dispose()
    $bmp.Dispose()
    $profileBrush.Dispose()
    $machineBrush.Dispose()

    return $icon
}

function Start-MachineBadge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Corp','Personal')]
        [string]$Context,
        
        [Parameter(Mandatory)]
        [string]$MachineColor
    )

    Ensure-MachineBadgeRuntime

    $hostname = $env:COMPUTERNAME

    # Parse machine color from hex string (required)
    $machineColorObj = Get-MachineBadgeColorFromHex -HexColor $MachineColor

    # Keep tooltip short (NotifyIcon.Text limit varies by runtime; safe to keep compact) 【2-0a3195】
    $sessionHint = if ($env:SESSIONNAME -like 'RDP-*') { 'R' } else { 'L' }

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = New-MachineBadgeIdentityIcon -Context $Context -MachineColor $machineColorObj -HostId $hostname
    $tray.Text = "$hostname ($Context,$sessionHint)"
    $tray.Visible = $true

    # Right-click Exit (helps testing / cleanup)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $exitItem = $menu.Items.Add("Exit")
    $exitItem.add_Click({
        $tray.Visible = $false
        $tray.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    $tray.ContextMenuStrip = $menu

    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
}

function Install-MachineBadge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Corp','Personal')]
        [string]$Context,
        
        [Parameter()]
        [string]$MachineColor,
        
        [Parameter()]
        [switch]$InstallOnly
    )

    $installDir = Join-Path $env:LOCALAPPDATA "MachineBadge"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    # Copy THIS module to stable location for future use
    $moduleSource = $PSCommandPath
    if (-not $moduleSource) { throw "Install-MachineBadge must be run from a saved .psm1 file." }
    $moduleDest = Join-Path $installDir "MachineBadge.psm1"
    Copy-Item -Path $moduleSource -Destination $moduleDest -Force

    # Determine machine color at install time
    if (-not $MachineColor) {
        $hostname = $env:COMPUTERNAME
        $MachineColor = Get-MachineBadgeColorHexFromHostname -Hostname $hostname
    }

    # Create a VBScript wrapper to launch PowerShell truly hidden
    # -WindowStyle Hidden is unreliable at logon; VBScript's Run(cmd, 0) is bulletproof
    # Embed PowerShell commands directly and use -EncodedCommand for robust quoting in PS 5.1
    $vbsPath = Join-Path $installDir "MachineBadge.vbs"
    $psCmd = "`$ErrorActionPreference = 'SilentlyContinue'; Import-Module '$moduleDest' -Force; Start-MachineBadge -Context $Context -MachineColor '$MachineColor'"
    $psEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psCmd))
    @"
Set objShell = CreateObject("WScript.Shell")
powershellCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $psEncoded"
objShell.Run powershellCmd, 0, False
"@ | Set-Content -Path $vbsPath -Encoding ASCII

    # Write HKCU Run entry to launch via VBScript (window style 0 = hidden)
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $cmd = "cscript.exe `"$vbsPath`""

    New-ItemProperty -Path $runKey -Name "MachineBadge" -Value $cmd -PropertyType String -Force | Out-Null

    Write-Host "Installed MachineBadge (Run key)"
    Write-Host "  Context      : $Context"
    Write-Host "  MachineColor : $MachineColor"
    Write-Host "  Module       : $moduleDest"
    Write-Host "  Launcher     : $vbsPath"
    
    if (-not $InstallOnly) {
        Write-Host "Starting MachineBadge..."
        & cscript.exe $vbsPath
    } else {
        Write-Host "-InstallOnly detected. Skipping automatic first run (no logoff required)"
        Write-Host "To test manually without logoff/logon: cscript.exe `"$vbsPath`""
    }
}

function Uninstall-MachineBadge {
    [CmdletBinding()]
    param()

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "MachineBadge" -ErrorAction SilentlyContinue

    $installDir = Join-Path $env:LOCALAPPDATA "MachineBadge"
    Remove-Item -Recurse -Force $installDir -ErrorAction SilentlyContinue

    Write-Host "Uninstalled MachineBadge (removed Run key + install folder)"
}

Export-ModuleMember -Function Start-MachineBadge, Install-MachineBadge, Uninstall-MachineBadge
