[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetProject,
    [string]$SourceProject,
    [switch]$Force,
    [switch]$ResetConfiguration
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SourceProject)) { $SourceProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$sourceRoot = [IO.Path]::GetFullPath($SourceProject)
$targetRoot = [IO.Path]::GetFullPath($TargetProject)
if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Target project directory was not found: $targetRoot" }
if ($sourceRoot -eq $targetRoot) { throw 'Source and target projects must be different.' }

$conflicts = @(@(
    (Join-Path $targetRoot '.pipeline\pipeline.yaml'),
    (Join-Path $targetRoot '.codex\skills\onec-pipeline'),
    (Join-Path $targetRoot '.codex\skills\1c-ai-workflow')
) | Where-Object { Test-Path -LiteralPath $_ })
if ($conflicts.Count -gt 0 -and -not $Force) {
    throw "Pipeline files already exist. Use -Force to update them: $($conflicts -join ', ')"
}

$pipelineTarget = Join-Path $targetRoot '.pipeline'
$skillsTarget = Join-Path $targetRoot '.codex\skills'
$scriptsTarget = Join-Path $targetRoot 'scripts'
$configurationTarget = Join-Path $pipelineTarget 'pipeline.yaml'
[IO.Directory]::CreateDirectory($pipelineTarget) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $pipelineTarget 'tasks')) | Out-Null
[IO.Directory]::CreateDirectory($skillsTarget) | Out-Null
[IO.Directory]::CreateDirectory($scriptsTarget) | Out-Null

$configurationStatus = 'installed'
if (-not (Test-Path -LiteralPath $configurationTarget -PathType Leaf) -or $ResetConfiguration) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\pipeline.yaml') -Destination $configurationTarget -Force
    if ($ResetConfiguration) { $configurationStatus = 'reset' }
}
else {
    $configurationStatus = 'preserved'
}
Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\references') -Destination $pipelineTarget -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\roles') -Destination $pipelineTarget -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\.gitignore') -Destination (Join-Path $pipelineTarget '.gitignore') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\tasks\.gitkeep') -Destination (Join-Path $pipelineTarget 'tasks\.gitkeep') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Install-PipelineToProject.ps1') -Destination (Join-Path $scriptsTarget 'Install-PipelineToProject.ps1') -Force

foreach ($skillName in @('onec-pipeline', '1c-ai-workflow')) {
    $sourceSkill = Join-Path $sourceRoot ".codex\skills\$skillName"
    $targetSkill = Join-Path $skillsTarget $skillName
    [IO.Directory]::CreateDirectory($targetSkill) | Out-Null
    Copy-Item -Path (Join-Path $sourceSkill '*') -Destination $targetSkill -Recurse -Force
}

[pscustomobject][ordered]@{
    status = 'installed'
    target_project = $targetRoot
    configuration = $configurationStatus
    next_step = 'Configure project VERIFY adapters, then start a task with $1c-ai-workflow.'
} | ConvertTo-Json -Depth 5
