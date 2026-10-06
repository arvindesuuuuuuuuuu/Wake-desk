param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9+/]+={0,2}$')]
    [string]$AdapterNameBase64,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

try {
    $adapterName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AdapterNameBase64))
    if ([string]::IsNullOrWhiteSpace($adapterName) -or $adapterName.Length -gt 256) {
        throw 'Invalid network adapter name.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdministrator) {
        if ($Elevated) { throw 'Administrator privileges are required.' }
        $quotedScript = '"' + $PSCommandPath.Replace('"', '""') + '"'
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $quotedScript, '-AdapterNameBase64', $AdapterNameBase64, '-Elevated'
        )
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }

    $adapter = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Name -ceq $adapterName })
    if (@($adapter).Count -ne 1) { throw 'Select one physical network adapter.' }

    $adapter | Set-NetAdapterPowerManagement -WakeOnMagicPacket Enabled -ErrorAction Stop
    $power = @(Get-NetAdapterPowerManagement -Name '*' -ErrorAction Stop |
        Where-Object { $_.Name -ceq $adapterName })
    if (@($power).Count -ne 1) { throw 'Could not verify the adapter power settings.' }
    if ([string]$power.WakeOnMagicPacket -ne 'Enabled') {
        throw 'The adapter or driver did not enable magic-packet wake.'
    }
    Write-Output "Wake-on-LAN enabled for $adapterName."
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
