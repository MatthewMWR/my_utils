
Set-StrictMode -Version Latest

function Start-MachineBadge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Corp','Personal')]
        [string]$Context,
        
        [Parameter()]
        [string]$MachineColor
    )

    # Single-instance guard (prevents duplicates if user launches manually + Run key)
    $mutexName = "Global\MachineBadgeTray"
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) { return }

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

    function Get-StableColorFromString {
        param([string]$s)
        $h = [Math]::Abs($s.GetHashCode())
        $r = ($h           % 156) + 50
        $g = (($h / 256)   % 156) + 50
        $b = (($h / 65536) % 156) + 50
        [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
    }

    function Get-GlyphFirstLastAlnum {
        param([string]$name)
        $clean = ($name -replace '[^A-Za-z0-9]', '')
        if ([string]::IsNullOrWhiteSpace($clean)) { return "??" }
        (($clean.Substring(0,1) + $clean.Substring($clean.Length-1,1))).ToLower()
    }

    function New-IdentityIcon {
        param(
            [string]$Context,
            [System.Drawing.Color]$MachineColor
        )
        $profileColor = if ($Context -eq 'Corp') {
            [System.Drawing.Color]::FromArgb(255, 0, 60, 140)    # dark blue
        } else {
            [System.Drawing.Color]::FromArgb(255, 235, 120, 0)   # orange
        }
        $machineColor = $MachineColor

        $size = 32
        $halfSize = $size / 2
        $bmp  = New-Object System.Drawing.Bitmap $size,$size,([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g    = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        # Fill top half with profile color
        $profileBrush = New-Object System.Drawing.SolidBrush $profileColor
        $g.FillRectangle($profileBrush, 0, 0, $size, $halfSize)

        # Fill bottom half with machine-specific color
        $machineBrush = New-Object System.Drawing.SolidBrush $machineColor
        $g.FillRectangle($machineBrush, 0, $halfSize, $size, $halfSize)

        # Convert bitmap -> icon safely
        $hIcon   = $bmp.GetHicon()
        $tmpIcon = [System.Drawing.Icon]::FromHandle($hIcon)
        $icon    = [System.Drawing.Icon]$tmpIcon.Clone()
        [Win32]::DestroyIcon($hIcon) | Out-Null
        $tmpIcon.Dispose()

        $g.Dispose(); $bmp.Dispose()
        $profileBrush.Dispose(); $machineBrush.Dispose()

        return $icon
    }

    $hostname = $env:COMPUTERNAME

    # Parse machine color from hex string or default to hash-based color
    if ($MachineColor) {
        $hexColor = $MachineColor -replace '^#', ''
        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
        $machineColorObj = [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
    } else {
        $machineColorObj = Get-StableColorFromString $hostname
    }

    # Keep tooltip short (NotifyIcon.Text limit varies by runtime; safe to keep compact) 【2-0a3195】
    $sessionHint = if ($env:SESSIONNAME -like 'RDP-*') { 'R' } else { 'L' }

    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = New-IdentityIcon -Context $Context -MachineColor $machineColorObj
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

    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
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
        $h = [Math]::Abs($hostname.GetHashCode())
        $r = ($h           % 156) + 50
        $g = (($h / 256)   % 156) + 50
        $b = (($h / 65536) % 156) + 50
        $MachineColor = "#{0:X2}{1:X2}{2:X2}" -f $r,$g,$b
    }

    # Create a VBScript wrapper to launch PowerShell truly hidden
    # -WindowStyle Hidden is unreliable at logon; VBScript's Run(cmd, 0) is bulletproof
    # Embed PowerShell commands directly to avoid extra .ps1 file
    $vbsPath = Join-Path $installDir "MachineBadge.vbs"
    $psCmd = "`$ErrorActionPreference = 'SilentlyContinue'; Import-Module '$moduleDest' -Force; Start-MachineBadge -Context $Context -MachineColor '$MachineColor'"
    @"
Set objShell = CreateObject("WScript.Shell")
powershellCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$psCmd`""
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
