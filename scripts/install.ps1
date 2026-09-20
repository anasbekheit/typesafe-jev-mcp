# Product installer for Windows.
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/anasbekheit/typesafe-jev-mcp/main/scripts/install.ps1 | iex"
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($env:OS -ne "Windows_NT") {
    Write-Error "install.ps1 supports Windows only. Use install.sh on macOS or Linux."
    exit 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "typesafe-jev-mcp requires a 64-bit version of Windows."
    exit 1
}

$Repo = "anasbekheit/typesafe-jev-mcp"
$Dist = "https://github.com/$Repo/releases/latest/download/typesafe-jev-mcp-installer.ps1"
$Manifest = "https://github.com/$Repo/releases/latest/download/dist-manifest.json"
$SkillUrl = "https://raw.githubusercontent.com/$Repo/main/skills/jev/SKILL.md"
$Console = "https://console.typesafe.ai/"
$NonInteractive = $env:TYPESAFE_NON_INTERACTIVE -match "^(?i:1|true|yes)$"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Get-PlatformLabel {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($architecture) {
        "Arm64" { return "Windows (ARM64)" }
        "X64" { return "Windows (x64)" }
        default { throw "Unsupported architecture: $architecture" }
    }
}

function Get-ResolvedVersion {
    try {
        $json = Invoke-RestMethod -Uri $Manifest
        $tag = [string]$json.announcement_tag
        return $tag.TrimStart("v")
    } catch {
        return $null
    }
}

function Get-VersionFromBinary {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $out = & $Path --version 2>$null
        if ($out -match '^typesafe-jev-mcp (.+)$') {
            return $Matches[1].Trim()
        }
    } catch {}
    return $null
}

function Find-Binary {
    $candidates = @(
        (Join-Path $HOME ".cargo\bin\typesafe-jev-mcp.exe"),
        (Join-Path $HOME ".local\bin\typesafe-jev-mcp.exe")
    )
    $cmd = Get-Command typesafe-jev-mcp -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }
    return $null
}

function Find-Agent {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $homeCandidates = @(
        (Join-Path $HOME ".local\bin\$Name.exe"),
        (Join-Path $HOME ".local\bin\$Name")
    )
    foreach ($p in $homeCandidates) {
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }
    return $null
}

function Save-Key {
    param([string]$Key)
    $dir = Join-Path $env:LOCALAPPDATA "typesafe-jev-mcp"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir "key"
    Set-Content -LiteralPath $path -Value $Key -NoNewline
    icacls $path /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null
    $script:KeyCommand = "type `"$path`""
    Write-Step "Saved the key at $path"
}

function Ensure-Key {
    if (-not [string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY_COMMAND)) {
        $script:KeyCommand = $env:TYPESAFE_API_KEY_COMMAND
        Write-Step "Using TYPESAFE_API_KEY_COMMAND"
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        Save-Key $env:TYPESAFE_API_KEY
        return
    }
    $existing = Join-Path $env:LOCALAPPDATA "typesafe-jev-mcp\key"
    if ((Test-Path -LiteralPath $existing) -and ((Get-Item $existing).Length -gt 0)) {
        $script:KeyCommand = "type `"$existing`""
        Write-Step "Found $existing"
        return
    }
    if ($NonInteractive -or [Console]::IsInputRedirected) {
        throw "No key. Set TYPESAFE_API_KEY and re-run. $Console"
    }
    Write-Step "Open this URL: $Console"
    $secure = Read-Host "Paste the API key" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Empty key"
    }
    Save-Key $key.Trim()
}

function Install-Skill {
    param([string]$Label, [string]$Dir)
    $dest = Join-Path $Dir "jev"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Invoke-WebRequest -Uri $SkillUrl -OutFile (Join-Path $dest "SKILL.md") -UseBasicParsing
    Write-Step "Skill → $Label"
}

function Register-Mcp {
    param([string]$Label, [scriptblock]$Command)
    try {
        & $Command | Out-Null
        Write-Step "Registered $Label"
    } catch {
        Write-Step "Skipped $Label (already registered, or the CLI refused)"
    }
}

$claude = Find-Agent claude
$codex = Find-Agent codex
$opencode = Find-Agent opencode
$agy = Find-Agent agy
$hasCursor = Test-Path (Join-Path $HOME ".cursor")

if (-not $claude -and -not $codex -and -not $opencode -and -not $agy -and -not $hasCursor) {
    throw "No coding agent found (claude, codex, opencode, agy, or ~/.cursor)."
}

$platformLabel = Get-PlatformLabel
$resolved = Get-ResolvedVersion
Write-Step "Detected platform: $platformLabel"
if ($resolved) {
    Write-Step "Resolved version: $resolved"
} else {
    Write-Warning "Could not read the latest release tag; will reinstall the binary."
}

$bin = Find-Binary
$installed = if ($bin) { Get-VersionFromBinary -Path $bin } else { $null }

if ($resolved -and $installed -and ($installed -eq $resolved)) {
    Write-Step "typesafe-jev-mcp $resolved already installed"
} else {
    if ($installed -and $resolved) {
        Write-Step "Updating typesafe-jev-mcp from $installed to $resolved"
    } else {
        Write-Step "Installing typesafe-jev-mcp"
    }
    $installer = Join-Path $env:TEMP "typesafe-jev-mcp-installer.ps1"
    Invoke-WebRequest -Uri $Dist -OutFile $installer -UseBasicParsing
    & $installer
    $env:Path = "$(Join-Path $HOME '.cargo\bin');$env:Path"
    $bin = Find-Binary
    if (-not $bin) {
        throw "binary not on PATH; add $HOME\.cargo\bin and re-run"
    }
}

Write-Step $bin
Ensure-Key
$env:TYPESAFE_API_KEY_COMMAND = $KeyCommand

if ($claude) { Install-Skill "Claude Code" (Join-Path $HOME ".claude\skills") }
if ($codex) { Install-Skill "Codex" (Join-Path $HOME ".codex\skills") }
if ($opencode) {
    $cfg = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    Install-Skill "OpenCode" (Join-Path $cfg "opencode\skills")
}
if ($agy) { Install-Skill "Antigravity" (Join-Path $HOME ".gemini\antigravity\skills") }
if ($hasCursor) { Install-Skill "Cursor" (Join-Path $HOME ".cursor\skills") }

if ($claude) {
    Register-Mcp "Claude Code" { & $claude mcp add jev -s user -e "TYPESAFE_API_KEY_COMMAND=$KeyCommand" -- $bin }
}
if ($codex) {
    Register-Mcp "Codex" { & $codex mcp add jev --env "TYPESAFE_API_KEY_COMMAND=$KeyCommand" -- $bin }
}
if ($opencode) {
    Register-Mcp "OpenCode" { & $opencode mcp add jev --global --env "TYPESAFE_API_KEY_COMMAND=$KeyCommand" -- $bin }
}
if ($agy) {
    Register-Mcp "Antigravity" { & $agy mcp add -e "TYPESAFE_API_KEY_COMMAND=$KeyCommand" jev $bin }
}

if ($hasCursor) {
    $mcpPath = Join-Path $HOME ".cursor\mcp.json"
    $data = @{ mcpServers = @{} }
    if (Test-Path -LiteralPath $mcpPath) {
        $raw = Get-Content -LiteralPath $mcpPath -Raw
        if ($raw.Trim()) {
            $data = $raw | ConvertFrom-Json
        }
    }
    if (-not $data.mcpServers) {
        $data | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $server = [pscustomobject]@{
        command = $bin
        env     = [pscustomobject]@{ TYPESAFE_API_KEY_COMMAND = $KeyCommand }
    }
    $data.mcpServers | Add-Member -NotePropertyName jev -NotePropertyValue $server -Force
    ($data | ConvertTo-Json -Depth 8) + "`n" | Set-Content -LiteralPath $mcpPath -NoNewline
    Write-Step "Registered Cursor (~/.cursor/mcp.json)"
}

Write-Step "Restart the agent, then: use evaluate to decide whether this is urgent"
Write-Step "Key is not in the agent config; the server runs: $KeyCommand"
Write-Host "typesafe-jev-mcp $resolved installed successfully."
