#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Lets the Codex desktop app on other machines use this Windows PC as an SSH host
  (Codex Settings > Connections > SSH), without changing how ordinary SSH logins behave.

.EXAMPLE
  .\install.ps1 -PublicKeyFile C:\path\to\codex-client-keys.pub
  .\install.ps1 -PublicKeyFile keys.pub -DryRun     # show what it would do

  Run it in an admin PowerShell, signed in as the account Codex should use. Needs OpenSSH Server,
  the Codex desktop app, Git for Windows and Python 3 on this PC. Safe to re-run (adds new keys only).
#>
[CmdletBinding()]
param(
    # Plain Ed25519 public keys, one per line: a dedicated key from each client machine.
    [Parameter(Mandatory)][string]$PublicKeyFile,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Do-It($what, [scriptblock]$action) {
    if ($DryRun) { Write-Host "    (dry run) $what" } else { & $action }
}
$utf8 = [Text.UTF8Encoding]::new($false)
function Posix($p) { '/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }

# ---- what's needed ----
$python = $null
foreach ($candidate in @(
        (& { try { py -3 -c 'import sys; print(sys.executable)' 2>$null } catch {} }),
        (Get-Command python -ErrorAction SilentlyContinue).Source,
        (Join-Path $env:LOCALAPPDATA 'Python\bin\python.exe'))) {
    if ($candidate -and (Test-Path $candidate) -and $candidate -notmatch 'WindowsApps') { $python = $candidate; break }
}
if (-not $python) { throw 'Python 3 not found: install it (python.org or winget install Python.Python.3.13).' }
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw 'Git for Windows not found (winget install Git.Git).' }
if (-not (Get-AppxPackage -Name OpenAI.Codex)) { throw 'The Codex desktop app is not installed for this user.' }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'OpenSSH Server is not installed (Settings > System > Optional features).' }
$keys = @(Get-Content -LiteralPath $PublicKeyFile | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
foreach ($key in $keys) {
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( .*)?$') { throw 'Expected plain Ed25519 public keys, one per line. Never pass a private key.' }
}
if ($keys.Count -eq 0) { throw 'The public key file is empty.' }
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Python: $python`nGit Bash: $bash`nAccount: $user"

# ---- files ----
$dest = Join-Path $env:LOCALAPPDATA 'codex-ssh-windows'
$bridge = Join-Path $dest 'codex-ssh.py'
Step "Installing the bridge in $dest"
Do-It "copy codex-ssh.py, start-server.ps1 and write bin\codex, bin\awk" {
    New-Item -ItemType Directory -Force -Path (Join-Path $dest 'bin') | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'codex-ssh.py'), (Join-Path $PSScriptRoot 'start-server.ps1') $dest -Force
    $py, $br = (Posix $python), (Posix $bridge)
    # Git Bash scripts: LF line endings
    [IO.File]::WriteAllText((Join-Path $dest 'bin\codex'), "#!/bin/sh`nexec `"$py`" `"$br`" --cli `"`$@`"`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $dest 'bin\awk'), (@(
        '#!/bin/sh',
        "# Codex checks that its reverse forward listens on IPv4 loopback only; Windows has no /proc.",
        'if [ "$#" -eq 3 ] && [ "$2" = /proc/net/tcp ] && [ "$3" = /proc/net/tcp6 ]; then',
        "    `"$py`" `"$br`" --tcp-table | /usr/bin/awk `"`$1`"",
        'else',
        '    exec /usr/bin/awk "$@"',
        'fi') -join "`n") + "`n", $utf8)
}

# ---- the app server's private control socket ----
$control = Join-Path $env:USERPROFILE '.codex\app-server-control'
Step "Restricting $control to $user only"
Do-It "owner + full control for $user only (Codex refuses a socket others can reach)" {
    New-Item -ItemType Directory -Force -Path $control | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.NTAccount]$user)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $control -AclObject $acl
}

# ---- the app server, as you, unelevated ----
$taskName = 'Codex SSH app server'
Step "Registering the '$taskName' logon task"
Do-It "Task Scheduler: start-server.ps1 at logon, Limited, no time limit, 3 retries; start it now" {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
        -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'start-server.ps1')`"" -WorkingDirectory $dest
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Codex app server for SSH connections from other machines (codex-ssh-windows).' -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

# ---- forced-command keys ----
$isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.SecurityIdentifier]'S-1-5-32-544')
$authorized = if ($isAdmin) { Join-Path $env:ProgramData 'ssh\administrators_authorized_keys' } else { Join-Path $env:USERPROFILE '.ssh\authorized_keys' }
Step "Adding $($keys.Count) Codex key(s) to $authorized"
$text = if (Test-Path -LiteralPath $authorized) { [IO.File]::ReadAllText($authorized) } else { '' }
$options = "restrict,port-forwarding,command=`"$($python -replace '\\', '/') $($bridge -replace '\\', '/')`""
foreach ($key in $keys) {
    $blob = ($key.Trim() -split '\s+')[1]
    if ($text -match [regex]::Escape($blob)) { Write-Host "    already there: $($key.Substring(0, 30))..."; continue }
    $text = $text.TrimEnd() + "`n$options $($key.Trim())`n"
}
Do-It "write $authorized (restrict + port forwarding for Codex's reverse tunnel + the bridge as forced command)" {
    if (Test-Path -LiteralPath $authorized) { Copy-Item -LiteralPath $authorized ($authorized + '.before-codex-ssh-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    New-Item -ItemType Directory -Force -Path (Split-Path $authorized) | Out-Null
    [IO.File]::WriteAllText($authorized, $text.TrimStart(), $utf8)
    if ($isAdmin) {  # sshd ignores this file unless only SYSTEM and Administrators can write it
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
        [IO.File]::SetAccessControl($authorized, $acl)
    }
}

$address = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp, Manual -ErrorAction SilentlyContinue | Where-Object IPAddress -notlike '169.254.*' | Select-Object -First 1).IPAddress
Write-Host ''
Write-Host 'Done. On each client machine, add to ~/.ssh/config:' -ForegroundColor Green
Write-Host @"

Host $($env:COMPUTERNAME.ToLower())-codex
    HostName $address
    User $env:USERNAME
    IdentityFile ~/.ssh/id_ed25519_codex_remote
    IdentitiesOnly yes

"@
Write-Host "Then in Codex: Settings > Connections > SSH > add '$($env:COMPUTERNAME.ToLower())-codex'. You must be signed in on this PC."
