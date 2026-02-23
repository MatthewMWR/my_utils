# Preps system to install modules with latest "Get" machinery
# No restart required between this and using Install-PSResource
Install-Module -Name PowerShellGet,Microsoft.PowerShell.PSResourceGet -Force -AllowClobber

#Install-PSResource -Name Microsoft.OSConfig -Version 1.3.2-preview7 -Prerelease

# Install pwsh7 from powershell 5
Invoke-WebRequest -Uri https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/PowerShell-7.5.4-win-x64.msi -OutFile pwsh.msi
msiexec.exe /package pwsh.msi REGISTER_MANIFEST=1 ADD_PATH=1

# function prompt with truncated path
function prompt { '🅿 …\' + ($executionContext.SessionState.Path.CurrentLocation.Path -split '\\')[-1] + " >" }

## create my usual dirs
New-Item -Path c:\ -Name __my -ItemType Directory -ErrorAction SilentlyContinue
New-Item -Path c:\__my -Name __repos -ItemType Directory -ErrorAction SilentlyContinue
New-Item -Path c:\__my -Name __scratch_local -ItemType Directory -ErrorAction SilentlyContinue
New-Item -Path c:\__my -Name __apps_local -ItemType Directory -ErrorAction SilentlyContinue