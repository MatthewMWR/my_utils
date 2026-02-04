# Preps system to install modules with latest "Get" machinery
# No restart required between this and using Install-PSResource
Install-Module -Name PowerShellGet,Microsoft.PowerShell.PSResourceGet -Force -AllowClobber

#Install-PSResource -Name Microsoft.OSConfig -Version 1.3.2-preview7 -Prerelease

