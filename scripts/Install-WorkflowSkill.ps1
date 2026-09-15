[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$CodexHome,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}

$sourcePath = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.codex\skills\1c-ai-workflow'))
$skillsRoot = [IO.Path]::GetFullPath((Join-Path $CodexHome 'skills'))
$destinationPath = [IO.Path]::GetFullPath((Join-Path $skillsRoot '1c-ai-workflow'))
$expectedPrefix = $skillsRoot.TrimEnd('\') + '\'
if (-not $destinationPath.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe skill destination: $destinationPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'SKILL.md') -PathType Leaf)) {
    throw "Skill source was not found: $sourcePath"
}
if (Test-Path -LiteralPath $destinationPath) {
    if (-not $Force) { throw "Skill is already installed: $destinationPath. Use -Force to update it." }
    Remove-Item -LiteralPath $destinationPath -Recurse -Force
}
[IO.Directory]::CreateDirectory($skillsRoot) | Out-Null
Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse

[pscustomobject][ordered]@{
    status = 'installed'
    name = '1c-ai-workflow'
    destination = $destinationPath
} | ConvertTo-Json -Depth 5
