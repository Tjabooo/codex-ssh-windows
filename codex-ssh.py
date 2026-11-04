"""Codex-only SSH entry point on Windows (an authorized_keys forced command).

The Codex desktop app's SSH connections send POSIX shell commands and expect a Unix-like host. For
the keys install.ps1 adds, Windows OpenSSH runs this script instead of the user's shell: it runs the
command in Git Bash with binary-safe standard handles, so ordinary SSH logins keep cmd.exe/PowerShell.

  codex-ssh.py               (forced command) run $SSH_ORIGINAL_COMMAND in Git Bash
  codex-ssh.py --cli ARGS    run the installed Codex desktop app's codex.exe
  codex-ssh.py --tcp-table   Windows TCP listeners in /proc/net/tcp format (for bin/awk)
"""

import ipaddress
import os
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def cli_path():
    packages = []
    for exe in Path(os.environ.get("ProgramFiles", "C:/Program Files"), "WindowsApps").glob(
        "OpenAI.Codex_*_x64__*/app/resources/codex.exe"
    ):
        match = re.search(r"OpenAI\.Codex_([\d.]+)_", str(exe))
        if match:
            packages.append((tuple(map(int, match[1].split("."))), exe))
    if not packages:
        raise RuntimeError("Install the Codex desktop app on this PC first")
    return str(max(packages)[1])


def git_bash():
    for root in (os.environ.get("ProgramFiles", r"C:\Program Files"),
                 os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs")):
        bash = Path(root, "Git", "bin", "bash.exe")
        if bash.exists():
            return str(bash)
    raise RuntimeError("Git for Windows (Git Bash) is not installed")


def posix(path):
    """C:\\Users\\me\\x -> /c/Users/me/x (how Git Bash names it)."""
    p = Path(path)
    return "/" + p.drive.rstrip(":").lower() + p.as_posix()[len(p.drive):]


def print_tcp_table():
    """Expose actual Windows listeners in the format used by Codex's SSH check."""
    result = subprocess.run(
        [r"C:\Windows\System32\netstat.exe", "-na"],
        capture_output=True, encoding="ascii", errors="replace", check=True,
    )
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0] != "TCP" or fields[3] != "LISTENING":
            continue
        address, port = fields[1].rsplit(":", 1)
        packed = ipaddress.ip_address(address.strip("[]")).packed
        # /proc stores each 32-bit address word in little-endian order.
        encoded = b"".join(packed[i:i+4][::-1] for i in range(0, len(packed), 4))
        print(f"0: {encoded.hex().upper()}:{int(port):04X} 0:0 0A")
    return 0


def main():
    if sys.argv[1:] == ["--tcp-table"]:
        return print_tcp_table()
    if sys.argv[1:2] == ["--cli"]:
        return subprocess.call([cli_path(), *sys.argv[2:]])
    command = os.environ.get("SSH_ORIGINAL_COMMAND")
    if not command:
        print("This key is reserved for Codex SSH commands", file=sys.stderr)
        return 1
    env = dict(os.environ)
    env.update(
        SHELL="/usr/bin/bash",
        MSYS2_PATH_TYPE="inherit",
        CODEX_INSTALL_DIR=posix(HERE / "bin"),
        # The app server runs as you, unelevated, from Task Scheduler (start-server.ps1); an SSH
        # session as an administrator has an elevated token and must not start its own.
        CODEX_SSH_SKIP_APP_SERVER_BOOT="true",
    )
    # Scope the TCP-table adapter (bin/awk) and the codex launcher to this SSH connection.
    env["PATH"] = str(HERE / "bin") + os.pathsep + env["PATH"]
    # Inherit the SSH handles directly: text pipelines corrupt WebSocket bytes.
    return subprocess.call([git_bash(), "-c", command], env=env)


if __name__ == "__main__":
    raise SystemExit(main())
