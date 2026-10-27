# Installs Passhand on Windows: builds the helper, registers it with Chrome and Claude desktop.
# Run from the repository folder:  powershell -ExecutionPolicy Bypass -File .\install.ps1
$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$App = Join-Path $env:LOCALAPPDATA 'passhand'
$BinDir = Join-Path $App 'bin'
$Bin = Join-Path $BinDir 'passhand.exe'
$ExtDir = Join-Path $App 'extension'
$ExtId = 'alpckagkehodlliniailejachglpeinb'
$HostName = 'me.shahrestani.passhand'
$Manifest = Join-Path $App "$HostName.json"
$RegKey = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName"

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    Write-Host 'Swift not found. Install the Swift toolchain for Windows (https://www.swift.org/install/windows/), then open a new terminal and run this again.'
    exit 1
}

Write-Host '-> Building the helper (release)...'
swift build -c release --package-path (Join-Path $Here 'helper')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Stop running helpers, so their files can be replaced. Chrome restarts its helper when the extension is
# reloaded; Claude desktop starts a new MCP server when it is restarted.
Get-Process passhand -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host "-> Installing to $App"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item (Join-Path $Here 'helper\.build\release\passhand.exe') $Bin -Force

# The helper needs the Swift runtime DLLs. Copy them next to it, so it also starts when Chrome or Claude
# desktop launch it with a PATH that doesn't include the Swift runtime.
$Runtime = $env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
if ($Runtime) {
    Copy-Item (Join-Path $Runtime '*.dll') $BinDir -Force
} else {
    Write-Host '-> Swift runtime DLLs not found on PATH; the helper will rely on the Swift runtime being on PATH'
}

if (Test-Path $ExtDir) { Remove-Item -Recurse -Force $ExtDir }
Copy-Item -Recurse (Join-Path $Here 'extension') $ExtDir

Write-Host '-> Registering the native messaging host with Chrome'
$json = [ordered]@{
    name = $HostName
    description = 'Passhand helper'
    path = $Bin
    type = 'stdio'
    allowed_origins = @("chrome-extension://$ExtId/")
} | ConvertTo-Json
# UTF-8 without a byte order mark.
[System.IO.File]::WriteAllText($Manifest, $json)
New-Item -Path $RegKey -Force | Out-Null
Set-Item -Path $RegKey -Value $Manifest

Write-Host '-> Registering the fill_login tool with Claude desktop'
& $Bin install-claude-config $Bin

# Put the command on your PATH (user PATH, appended, so the Swift runtime's own folder still comes first).
$Environment = Get-Item 'HKCU:\Environment'
$UserPath = $Environment.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
if (($UserPath -split ';') -notcontains $BinDir) {
    $NewPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
    Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $NewPath -Type ExpandString
    # Setting any user variable through .NET tells Windows the environment changed, so new terminals see it.
    [Environment]::SetEnvironmentVariable('PASSHAND_INSTALL', '1', 'User')
    [Environment]::SetEnvironmentVariable('PASSHAND_INSTALL', $null, 'User')
    $PathNote = "`nNote: open a new terminal to use the 'passhand' command."
} else {
    $PathNote = ''
}

try { Set-Clipboard -Value $ExtDir } catch { }

Write-Host @"

Helper installed. Three steps left:

1. Load the extension in Chrome
   - Open chrome://extensions and switch on "Developer mode" (top right)
   - Click "Load unpacked", paste the folder path into the folder box (it is on your clipboard:
     $ExtDir), then click Select Folder
   - You should see "Passhand" with ID $ExtId

2. Quit Claude desktop completely (also from the system tray) and reopen it, so it picks up the fill_login tool.

3. Save your first login and check everything:
     passhand add github.com you@example.com
     passhand doctor
$PathNote
Windows Hello (PIN, fingerprint or face) must be set up: Settings > Accounts > Sign-in options.
Optional: for unusual login forms, install Ollama and run:  ollama pull qwen2.5:3b
"@
