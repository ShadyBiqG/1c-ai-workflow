[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetProject,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $TargetProject -PathType Container)) {
    throw "Target project was not found: $TargetProject"
}

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$targetRoot = [IO.Path]::GetFullPath($TargetProject)
$sourcePath = [IO.Path]::GetFullPath((Join-Path $sourceRoot '.codex\skills\1c-ai-workflow'))
$skillsRoot = [IO.Path]::GetFullPath((Join-Path $targetRoot '.codex\skills'))
$destinationPath = [IO.Path]::GetFullPath((Join-Path $skillsRoot '1c-ai-workflow'))
$expectedPrefix = $targetRoot.TrimEnd('\') + '\'
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
