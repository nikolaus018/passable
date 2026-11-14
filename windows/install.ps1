<#
  Builds Passable for Windows and installs it for the current user (no admin needed):
    - self-contained copy in %LOCALAPPDATA%\Programs\Passable
    - Start menu shortcut
    - .passablemix opens with Passable (double-click in Explorer)
  Run from anywhere:  powershell -ExecutionPolicy Bypass -File windows\install.ps1
#>
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Passable'))

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'PassableWin\PassableWin.csproj'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

Get-Process Passable -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host "Publishing ($arch)..."
dotnet publish $project -c Release -r "win-$arch" -p:Platform=$arch --self-contained true -o $Destination
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

$exe = Join-Path $Destination 'Passable.exe'

# Start menu shortcut
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Passable.lnk'
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $Destination
$link.Description = 'Plays Passable mixes'
$link.Save()

# File association, per user
$classes = 'HKCU:\Software\Classes'
New-Item -Force "$classes\.passablemix" | Out-Null
Set-ItemProperty "$classes\.passablemix" '(default)' 'Passable.Mix'
New-Item -Force "$classes\Passable.Mix" | Out-Null
Set-ItemProperty "$classes\Passable.Mix" '(default)' 'Passable mix'
New-Item -Force "$classes\Passable.Mix\DefaultIcon" | Out-Null
Set-ItemProperty "$classes\Passable.Mix\DefaultIcon" '(default)' "`"$exe`",0"
New-Item -Force "$classes\Passable.Mix\shell\open\command" | Out-Null
Set-ItemProperty "$classes\Passable.Mix\shell\open\command" '(default)' "`"$exe`" `"%1`""

# Tell Explorer the association changed
Add-Type -Namespace Win32 -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);'
[Win32.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "Installed to $Destination"
