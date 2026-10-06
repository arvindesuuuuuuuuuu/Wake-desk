$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
go run github.com/akavel/rsrc@v0.10.2 -arch amd64 -manifest cmd/agent-gui/app.manifest -o cmd/agent-gui/rsrc_windows_amd64.syso
if ($LASTEXITCODE -ne 0) { throw 'Manifest build failed' }
go build -ldflags '-H=windowsgui' -o pc-agent.exe .
if ($LASTEXITCODE -ne 0) { throw 'Agent build failed' }
go build -ldflags '-H=windowsgui' -o pc-agent-gui.exe ./cmd/agent-gui
if ($LASTEXITCODE -ne 0) { throw 'GUI build failed' }
$outputDir = Join-Path $PSScriptRoot '..\dist\PC-Control-Windows'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
Copy-Item -LiteralPath pc-agent.exe,pc-agent-gui.exe,install.ps1,uninstall.ps1,enable-wol.ps1 -Destination $outputDir -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Destination $outputDir -Force
Compress-Archive -Path (Join-Path $outputDir '*') -DestinationPath (Join-Path $PSScriptRoot '..\dist\PC-Control-Windows.zip') -Force
Write-Host "Windows app built: $outputDir\pc-agent-gui.exe"
