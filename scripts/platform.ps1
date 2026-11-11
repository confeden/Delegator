# Shared OS boundary. Keep compatible with Windows PowerShell 5.1.
$script:DelegatorIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:DelegatorUserHome = if ($script:DelegatorIsWindows -and $env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
$script:DelegatorDataRoot = if ($script:DelegatorIsWindows) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:APPDATA }
    Join-Path $base 'DelegatorWin'
} else {
    Join-Path $script:DelegatorUserHome 'Library/Application Support/Delegator'
}
$script:DelegatorConfigFile = if ($env:DELEGATOR_CONFIG_FILE) { $env:DELEGATOR_CONFIG_FILE } elseif ($script:DelegatorIsWindows) {
    Join-Path $env:APPDATA 'Delegator/DelegatorWin/config/config.json'
} else { Join-Path $script:DelegatorDataRoot 'config.json' }

function Get-DelegatorRuntimeHome {
    if ($env:DELEGATOR_RUNTIME_HOME) { return $env:DELEGATOR_RUNTIME_HOME }
    return Join-Path $script:DelegatorDataRoot 'runtime'
}
function Get-DelegatorPowerShell {
    if ($env:DELEGATOR_PWSH) { return $env:DELEGATOR_PWSH }
    if ($script:DelegatorIsWindows) { return 'powershell.exe' }
    return Join-Path $PSHOME 'pwsh'
}
function Get-DelegatorCorePath {
    $name = if ($script:DelegatorIsWindows) { 'delegator-core.exe' } else { 'delegator-core' }
    if ($env:DELEGATOR_CORE_EXE) { return $env:DELEGATOR_CORE_EXE }
    $root = Split-Path $PSScriptRoot -Parent
    $macos = Join-Path (Split-Path $root -Parent) 'MacOS'
    if (-not $script:DelegatorIsWindows -and (Test-Path -LiteralPath $macos)) { $root = $macos }
    return Join-Path $root $name
}
function Get-DelegatorCurl {
    if ($script:DelegatorIsWindows) { return Join-Path $env:SystemRoot 'System32/curl.exe' }
    return '/usr/bin/curl'
}
function Get-DelegatorKeychainSecret {
    param([string]$Reference)
    if ($Reference -notmatch '^keychain:[a-fA-F0-9]{32}$') { throw 'Invalid macOS Keychain reference.' }
    $helper = if ($env:DELEGATOR_SECRET_HELPER) { $env:DELEGATOR_SECRET_HELPER } else {
        Join-Path (Split-Path (Get-DelegatorCorePath) -Parent) 'delegator'
    }
    $value = & $helper --read-secret $Reference
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read API key from macOS Keychain.' }
    return ($value -join "`n")
}
function Start-DelegatorProcess {
    param([string]$Program, [string[]]$Arguments = @(), [string]$WorkingDirectory)
    if ($script:DelegatorIsWindows) {
        $options = @{ FilePath = $Program; PassThru = $true; WindowStyle = 'Hidden' }
        if ($Arguments.Count -gt 0) { $options.ArgumentList = $Arguments }
        if ($WorkingDirectory) { $options.WorkingDirectory = $WorkingDirectory }
        return Start-Process @options
    }
    # Start-Process joins arguments into one string, losing spaces in paths.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Program
    $info.UseShellExecute = $false
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    return [Diagnostics.Process]::Start($info)
}

function ConvertTo-DelegatorTimestamp {
    param($Value)
    # PowerShell 7 deserializes ISO timestamps as DateTime; 5.1 leaves strings.
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
    return [string]$Value
}
