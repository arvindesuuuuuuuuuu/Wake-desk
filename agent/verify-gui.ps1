param([string]$Executable = (Join-Path $PSScriptRoot 'pc-agent-gui.exe'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PCControlCapture {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr ReadText(IntPtr window, uint message, IntPtr size, System.Text.StringBuilder text);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
$fixtureId = [Guid]::NewGuid().ToString('N')
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) ('PCControl-GUI-Test-' + $fixtureId)
$fixtureTask = 'PC Control GUI Test ' + $fixtureId
New-Item -ItemType Directory -Path $fixtureDir | Out-Null
$fixtureConfig = Join-Path $fixtureDir 'config.json'
$portProbe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$fixturePort = $portProbe.LocalEndpoint.Port
$portProbe.Stop()
@{ listen = "0.0.0.0:$fixturePort"; token = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')) } | ConvertTo-Json | Set-Content -LiteralPath $fixtureConfig -Encoding ASCII
$errorLog = Join-Path $fixtureDir 'error.log'
$clipboardBefore = [Windows.Forms.Clipboard]::GetDataObject()
$guiProcess = $null
$backendProcess = $null
$backendHandle = [IntPtr]::Zero
$window = $null

function Wait-For([scriptblock]$Check, [int]$Seconds = 25) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $result = & $Check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'GUI verification timed out'
}
function Find-Control([string]$Name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $found = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($found) { return $found }
    $copyNames = @('Copy agent URL','Copy MAC address','Copy broadcast address','Copy access token')
    $copyIndex = [Array]::IndexOf($copyNames, $Name)
    if ($copyIndex -ge 0) {
        $glyphCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, ([char]0xE8C8).ToString())
        $buttons = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $glyphCondition)
        if ($buttons.Count -gt $copyIndex) { return $buttons[$copyIndex] }
    }
    if ($Name -eq 'Refresh status') {
        $glyphCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, ([char]0xE72C).ToString())
        return $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $glyphCondition)
    }
    if ($Name -eq 'Show QR code') {
        $glyphCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, ([char]0xED14).ToString())
        return $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $glyphCondition)
    }
    return $null
}
function Click-Control([string]$Name) {
    $control = Wait-For { $candidate = Find-Control $Name; if ($candidate -and $candidate.Current.IsEnabled) { $candidate } }
    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Read-Field([string]$Name) {
    $control = Find-Control $Name
    $pattern = $null
    if ($control.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { return $pattern.Current.Value }
    $handle = [IntPtr]$control.Current.NativeWindowHandle
    $length = [PCControlCapture]::SendMessage($handle, 0xE, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
    $buffer = New-Object Text.StringBuilder($length + 1)
    [PCControlCapture]::ReadText($handle, 0xD, [IntPtr]($length + 1), $buffer) | Out-Null
    return $buffer.ToString()
}
function Toggle-Token {
    (Find-Control 'Show token').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
}
function Token-IsMasked {
    $token = Find-Control 'Access token value'
    return [PCControlCapture]::SendMessage([IntPtr]$token.Current.NativeWindowHandle, 0xD2, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero
}
function Start-Panel {
    $script:guiProcess = Start-Process -FilePath $Executable -ArgumentList ('-config "' + $fixtureConfig + '" -task-name "' + $fixtureTask + '"') -PassThru -RedirectStandardError $errorLog
    $processCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $guiProcess.Id)
    $script:window = Wait-For {
        $guiProcess.Refresh()
        if ($guiProcess.HasExited) { throw ('GUI exited: ' + (Get-Content -LiteralPath $errorLog -Raw)) }
        [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $processCondition)
    }
}
function Capture-Panel([string]$FileName = 'windows-gui-preview.png') {
    $bounds = $window.Current.BoundingRectangle
    $bitmap = New-Object Drawing.Bitmap([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    try {
        if (-not [PCControlCapture]::PrintWindow([IntPtr]$window.Current.NativeWindowHandle, $dc, 2)) { throw 'Window capture failed' }
    } finally { $graphics.ReleaseHdc($dc) }
    $bitmap.Save((Join-Path $PSScriptRoot ('..\dist\' + $FileName)), [Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
}
try {
    Start-Panel
    Write-Host 'Window opened'
    $null = Wait-For { Find-Control 'Stopped / unreachable' }
    Write-Host 'Stopped status confirmed'
    Write-Host ('Initial window size: ' + $window.Current.BoundingRectangle.Width + ' x ' + $window.Current.BoundingRectangle.Height)
    if ($window.Current.BoundingRectangle.Width -ne 520 -or $window.Current.BoundingRectangle.Height -ne 600) { throw 'Expected a 520 x 600 window' }
    Capture-Panel
    Click-Control 'Show QR code'
    $panelWindow = $window
    $dialogCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Connect phone')
    $script:window = Wait-For {
        $dialog = $panelWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $dialogCondition)
        if (-not $dialog) { $dialog = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $dialogCondition) }
        $dialog
    }
    $null = Wait-For { Find-Control "This code contains your access token.`r`nKeep it private." }
    Write-Host ('QR window size: ' + $window.Current.BoundingRectangle.Width + ' x ' + $window.Current.BoundingRectangle.Height)
    Capture-Panel 'windows-qr-preview.png'
    Click-Control 'Close'
    $script:window = $panelWindow
    Write-Host 'PASS: QR dialog opens, displays warning, and closes'
    foreach ($entry in @(
        @{ Button = 'Copy agent URL'; Field = 'Agent URL value' },
        @{ Button = 'Copy MAC address'; Field = 'MAC address value' },
        @{ Button = 'Copy broadcast address'; Field = 'Broadcast address value' }
    )) {
        $expected = Read-Field $entry.Field
        Click-Control $entry.Button
        $null = Wait-For { [Windows.Forms.Clipboard]::GetText() -eq $expected }
        Write-Host ('PASS: ' + $entry.Button)
    }
    $cfg = Get-Content -LiteralPath $fixtureConfig -Raw | ConvertFrom-Json
    if (-not (Token-IsMasked)) { throw 'Token initially visible' }
    Click-Control 'Copy access token'
    $null = Wait-For { [Windows.Forms.Clipboard]::GetText() -eq $cfg.token }
    Write-Host 'Clipboard token confirmed'
    Toggle-Token
    $null = Wait-For { -not (Token-IsMasked) }
    if ((Read-Field 'Access token value') -ne $cfg.token) { throw 'Revealed token differs from saved token' }
    Toggle-Token
    $null = Wait-For { Token-IsMasked }
    Write-Host 'PASS: all four clipboard buttons and token reveal/hide'

    Click-Control 'Generate token'
    $null = Wait-For { Find-Control 'Unsaved changes' }
    $unchanged = Get-Content -LiteralPath $fixtureConfig -Raw | ConvertFrom-Json
    if ($unchanged.token -ne $cfg.token) { throw 'Token generation saved without confirmation' }
    Click-Control 'Discard changes'
    Click-Control 'Copy access token'
    $null = Wait-For { [Windows.Forms.Clipboard]::GetText() -eq $cfg.token }
    Click-Control 'Generate token'
    Click-Control 'Save settings'
    $null = Wait-For { Find-Control 'Connection settings saved' }
    $updated = Get-Content -LiteralPath $fixtureConfig -Raw | ConvertFrom-Json
    if ($updated.token -eq $cfg.token -or $updated.token.Length -lt 32) { throw 'New token not saved' }
    $cfg = $updated
    Write-Host 'PASS: token generation, unsaved state, discard, and save'

    Click-Control 'Enable startup'
    $null = Wait-For { Find-Control 'Disable startup' }
    $task = Get-ScheduledTask -TaskName $fixtureTask
    if ($task.Actions[0].Arguments -notlike ('*' + $fixtureConfig + '*')) { throw 'Startup task uses wrong configuration' }
    Click-Control 'Disable startup'
    $null = Wait-For { Find-Control 'Enable startup' }
    if (Get-ScheduledTask -TaskName $fixtureTask -ErrorAction SilentlyContinue) { throw 'Startup task not removed' }
    Write-Host 'PASS: startup enable/disable using an isolated scheduled task'

    Click-Control 'Start agent'
    $null = Wait-For { Find-Control 'Running' }
    $status = Invoke-RestMethod -Uri "http://127.0.0.1:$fixturePort/v1/status" -Headers @{ Authorization = 'Bearer ' + $cfg.token }
    if (-not $status.name -or $status.uptime_seconds -le 0) { throw 'Invalid live agent status' }
    $backend = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($guiProcess.Id) AND Name = 'pc-agent.exe'"
    $backendProcess = [Diagnostics.Process]::GetProcessById($backend.ProcessId)
    $backendHandle = [PCControlCapture]::OpenProcess(0x1000, $false, $backend.ProcessId)
    if ($backendHandle -eq [IntPtr]::Zero) { throw 'Could not monitor test agent exit' }
    if ((Find-Control 'Save settings').Current.IsEnabled -or (Find-Control 'Generate token').Current.IsEnabled) { throw 'Settings mutable while agent running' }
    $tokenPattern = (Find-Control 'Access token value').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $tokenPattern.Current.IsReadOnly) { throw 'Running token field is editable' }
    Toggle-Token
    $null = Wait-For { -not (Token-IsMasked) }
    Toggle-Token
    Click-Control 'Copy access token'
    $null = Wait-For { [Windows.Forms.Clipboard]::GetText() -eq $cfg.token }
    Click-Control 'Refresh status'
    $null = Wait-For { Find-Control 'Running' }

    Click-Control 'Open log'
    $null = Wait-For { Find-Control 'Log opened' }
    if (-not (Test-Path -LiteralPath (Join-Path $fixtureDir 'agent.log'))) { throw 'Log does not exist' }
    $logViewers = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($guiProcess.Id) AND Name = 'notepad.exe'"
    foreach ($viewer in $logViewers) {
        if ($viewer.CommandLine -like ('*' + $fixtureDir + '*')) { Stop-Process -Id $viewer.ProcessId -ErrorAction SilentlyContinue }
    }
    Click-Control 'Clear'
    $null = Wait-For { (Read-Field 'Activity log') -eq '' }
    Click-Control 'Copy agent URL'
    Capture-Panel
    $windowHandle = [IntPtr]$window.Current.NativeWindowHandle
    Click-Control 'Hide to tray'
    $null = Wait-For { -not [PCControlCapture]::IsWindowVisible($windowHandle) }
    [PCControlCapture]::ShowWindow($windowHandle, 9) | Out-Null
    $null = Wait-For { [PCControlCapture]::IsWindowVisible($windowHandle) }
    Write-Host 'PASS: start, live status, locked settings, copy/reveal while running, refresh, open/clear log, hide/restore'

    Click-Control 'Exit control panel'
    if (-not $guiProcess.WaitForExit(10000)) { throw 'Control panel did not exit' }
    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$fixturePort/v1/status" -Headers @{ Authorization = 'Bearer ' + $cfg.token }
    Start-Panel
    $null = Wait-For { Find-Control 'Running' }
    Click-Control 'Stop agent'
    $null = Wait-For { Find-Control 'Stopped / unreachable' }
    $finished = $backendProcess.WaitForExit(10000)
    $exitCode = [uint32]0
    if (-not $finished -or -not [PCControlCapture]::GetExitCodeProcess($backendHandle, [ref]$exitCode) -or $exitCode -ne 0) { throw ('Agent did not exit cleanly: ' + $exitCode) }
    Click-Control 'Exit control panel'
    if (-not $guiProcess.WaitForExit(10000)) { throw 'Reopened panel did not exit' }
    Write-Host 'PASS: exiting preserves agent; reopened panel stops it cleanly'
} catch {
    if (Test-Path -LiteralPath (Join-Path $fixtureDir 'agent.log')) { Get-Content -LiteralPath (Join-Path $fixtureDir 'agent.log') -Tail 5 | Write-Host }
    if ($window) {
        $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
            if ($_.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit) { Write-Host $_.Current.Name }
        }
    }
    throw
} finally {
    Unregister-ScheduledTask -TaskName $fixtureTask -Confirm:$false -ErrorAction SilentlyContinue
    if ($backendProcess -and -not $backendProcess.HasExited) { $backendProcess.Kill() }
    if ($backendHandle -ne [IntPtr]::Zero) { [PCControlCapture]::CloseHandle($backendHandle) | Out-Null }
    if ($guiProcess -and -not $guiProcess.HasExited) { Stop-Process -Id $guiProcess.Id -ErrorAction SilentlyContinue }
    if ($clipboardBefore) { [Windows.Forms.Clipboard]::SetDataObject($clipboardBefore, $true) } else { [Windows.Forms.Clipboard]::Clear() }
    Remove-Item -LiteralPath $fixtureConfig -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $fixtureDir 'agent.log') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errorLog -ErrorAction SilentlyContinue
}
