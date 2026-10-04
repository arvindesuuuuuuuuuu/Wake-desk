$ErrorActionPreference = 'Stop'
Stop-ScheduledTask -TaskName 'PC Control Agent' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'PC Control Agent' -Confirm:$false
Write-Host 'Startup task removed. Configuration retained.'
