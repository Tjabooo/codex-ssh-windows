# codex-ssh-windows

Use a **Windows PC as an SSH host in the Codex desktop app** (Settings → Connections → SSH), from
your Linux or Mac machines, or from another Windows machine.

Codex's SSH connections expect a Unix-like host: they send POSIX shell commands, check
`/proc/net/tcp` for their reverse tunnel, and talk WebSocket over the SSH channel's raw bytes.
Windows OpenSSH gives you cmd.exe instead, so out of the box the connection fails. This bridge fixes
that **for dedicated Codex keys only**. Ordinary `ssh`, `scp` and `sftp` to the PC keep working
exactly as before.

## How it works

- Each client machine gets its own key (`~/.ssh/id_ed25519_codex_remote`). On the PC, that key is
  added with a **forced command**: `restrict,port-forwarding,command="python codex-ssh.py"`.
- `codex-ssh.py` runs whatever Codex asked for (`$SSH_ORIGINAL_COMMAND`) in **Git Bash**. The SSH
  handles are passed straight through, with no text-mode pipes that would corrupt WebSocket frames.
- A scoped `awk` shim (only on this connection's PATH) answers Codex's `/proc/net/tcp` listener check
  from Windows' own `netstat`, so the check that the tunnel binds to IPv4 loopback only still runs.
  Every other `awk` call goes to Git Bash's real awk.
- `codex` on that connection runs the newest installed Codex desktop app's `codex.exe`. No version
  is pinned, so app updates don't break it.
- The **app server** runs as you, unelevated, from a Task Scheduler logon task (`start-server.ps1`),
  on a private local socket. SSH sessions of an administrator have an elevated token, so they're
  told not to start their own (`CODEX_SSH_SKIP_APP_SERVER_BOOT`). No new network port is opened.
- Codex refuses a control socket that anyone else can reach, so `~/.codex/app-server-control` is
  restricted to your account alone. The rest of `.codex` is not touched.

## Install

On the Windows PC you need: OpenSSH Server running with key login, the **Codex desktop app** (signed
in), **Git for Windows**, **Python 3**, and to be signed in to Windows (the app server runs in your
session).

1. On each client, make a dedicated key and copy its `.pub` to the PC:
   ```sh
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519_codex_remote -C "codex-remote@$(hostname)"
   ```
2. On the PC, in an **admin** PowerShell, put those public keys in one file and run:
   ```powershell
   git clone https://github.com/Tjabooo/codex-ssh-windows.git
   cd codex-ssh-windows
   .\install.ps1 -PublicKeyFile C:\path\to\codex-keys.pub     # -DryRun first to see what it does
   ```
   It installs to `%LOCALAPPDATA%\codex-ssh-windows`, restricts the control folder, registers and
   starts the "Codex SSH app server" task, and adds the keys to `administrators_authorized_keys`
   (or `~/.ssh/authorized_keys` for a non-admin account), backing up the old file. At the end it
   prints the client SSH config block.
3. On each client, add that block to `~/.ssh/config` (an alias like `mypc-codex`, with
   `IdentityFile ~/.ssh/id_ed25519_codex_remote`), then add the alias in Codex: Settings →
   Connections → SSH.

## Checks

```sh
ssh mypc-codex 'PATH="$HOME/.local/bin:$PATH"; codex --version'
ssh mypc-codex 'codex app-server daemon version'
```

On the PC: `Get-ScheduledTask 'Codex SSH app server'`, and the log is
`%USERPROFILE%\.codex\app-server-control\app-server.log`.

If you remove or upgrade Python to a new major version, run `install.ps1` again: the forced command
and the launchers name the interpreter's path.

## License

MIT
