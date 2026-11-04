$ErrorActionPreference = 'Stop'
$control = Join-Path $env:USERPROFILE '.codex\app-server-control'
try {
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $package) { throw 'Codex desktop package not found' }
    $cli = Join-Path $package.InstallLocation 'app\resources\codex.exe'
    # Native stderr can contain harmless warnings; use the process exit code.
    $ErrorActionPreference = 'Continue'
    & $cli -c features.code_mode_host=true app-server --listen unix:// *> (Join-Path $control 'app-server.log')
    exit $LASTEXITCODE
} catch {
    $_ | Out-File (Join-Path $control 'app-server.log')
    exit 1
}
