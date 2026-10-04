param(
    [string]$Listen = '0.0.0.0:8787',
    [string]$ConfigPath = '',
    [string]$TaskName = 'PC Control Agent',
    [switch]$SkipBuild,
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not $SkipBuild) {
    go build -ldflags '-H=windowsgui' -o pc-agent.exe .
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'pc-agent.exe'))) { throw 'Agent executable is missing' }
if ($ConfigPath -eq '') { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$configPath = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $configPath)) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    @{ listen = $Listen; token = [Convert]::ToBase64String($bytes) } | ConvertTo-Json | Set-Content -LiteralPath $configPath
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $configPath /inheritance:r /grant:r "${identity}:(F)" 'SYSTEM:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict config permissions' }
}
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute (Join-Path $PSScriptRoot 'pc-agent.exe') -Argument ('-config "' + $configPath + '"') -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
if (-not $NoStart) { Start-ScheduledTask -TaskName $TaskName }
Write-Host "Agent installed. Connection token is in $configPath"
