# Removes Passhand from Windows. Saved logins stay in Credential Manager unless you pass -Purge.
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 [-Purge]
param([switch]$Purge)

$App = Join-Path $env:LOCALAPPDATA 'passhand'
$BinDir = Join-Path $App 'bin'
$Bin = Join-Path $BinDir 'passhand.exe'
$HostName = 'me.shahrestani.passhand'

if (Test-Path $Bin) {
    & $Bin uninstall-claude-config
    if ($Purge) { & $Bin purge }
}

Get-Process passhand -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Remove-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$HostName" -Recurse -ErrorAction SilentlyContinue

$Environment = Get-Item 'HKCU:\Environment'
$UserPath = $Environment.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$Kept = ($UserPath -split ';' | Where-Object { $_ -and $_ -ne $BinDir }) -join ';'
if ($Kept -ne $UserPath) {
    Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $Kept -Type ExpandString
    [Environment]::SetEnvironmentVariable('PASSHAND_INSTALL', '1', 'User')
    [Environment]::SetEnvironmentVariable('PASSHAND_INSTALL', $null, 'User')
}

Remove-Item -Recurse -Force $App -ErrorAction SilentlyContinue

Write-Host "Removed. Also remove 'Passhand' from chrome://extensions and restart Claude desktop."
if (-not $Purge) {
    Write-Host 'Your saved logins are still in Credential Manager; run with -Purge to delete them too.'
}
