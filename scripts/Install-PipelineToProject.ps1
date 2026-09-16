[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$TargetProject,
    [string]$SourceProject,
    [switch]$Force,
    [switch]$ResetConfiguration
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pipelineVersion = '2.0.0'

if ([string]::IsNullOrWhiteSpace($SourceProject)) { $SourceProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$sourceRoot = [IO.Path]::GetFullPath($SourceProject)
$targetRoot = [IO.Path]::GetFullPath($TargetProject)
if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Target project directory was not found: $targetRoot" }
if ($sourceRoot -eq $targetRoot) { throw 'Source and target projects must be different.' }

$pipelineTarget = Join-Path $targetRoot '.pipeline'
$skillsTarget = Join-Path $targetRoot '.codex\skills'
$scriptsTarget = Join-Path $targetRoot 'scripts'
$configurationTarget = Join-Path $pipelineTarget 'pipeline.json'
$legacyConfiguration = Join-Path $pipelineTarget 'pipeline.yaml'
$agentsTarget = Join-Path $targetRoot 'AGENTS.md'
$conflicts = @(@($configurationTarget, (Join-Path $targetRoot '.codex\skills\onec-pipeline'), (Join-Path $targetRoot '.codex\skills\1c-ai-workflow')) | Where-Object { Test-Path -LiteralPath $_ })
if ($conflicts.Count -gt 0 -and -not $Force) { throw "Pipeline files already exist. Use -Force to update them: $($conflicts -join ', ')" }

$sourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot '.pipeline\references'), (Join-Path $sourceRoot '.pipeline\roles'), (Join-Path $sourceRoot '.codex\skills\onec-pipeline'), (Join-Path $sourceRoot '.codex\skills\1c-ai-workflow') -Recurse -File
) + @(
    Get-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\pipeline.json'), (Join-Path $sourceRoot '.pipeline\.gitignore'), (Join-Path $sourceRoot '.pipeline\tasks\.gitkeep'), (Join-Path $sourceRoot '.pipeline\templates\AGENTS.md'), (Join-Path $sourceRoot 'scripts\Install-PipelineToProject.ps1')
)
$manifest = @($sourceFiles | ForEach-Object {
    $relativePath = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    '{0} {1}' -f $relativePath, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
} | Sort-Object) -join "`n"
$sha = [Security.Cryptography.SHA256]::Create()
try { $sourceSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($manifest))) -replace '-', '').ToLowerInvariant() }
finally { $sha.Dispose() }

$migratedConfiguration = $null
$migrationWarning = $null
if (-not (Test-Path -LiteralPath $configurationTarget -PathType Leaf) -and (Test-Path -LiteralPath $legacyConfiguration -PathType Leaf)) {
    $legacyModulePath = Join-Path $targetRoot '.codex\skills\onec-pipeline\scripts\PipelineState.psm1'
    if (Test-Path -LiteralPath $legacyModulePath -PathType Leaf) {
        try {
            $legacyModuleSource = [IO.File]::ReadAllText($legacyModulePath, [Text.Encoding]::UTF8)
            $legacyModule = New-Module -Name ("LegacyPipeline{0}" -f [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($legacyModuleSource)) -AsCustomObject
            $migratedConfiguration = $legacyModule.'Read-PipelineConfiguration'($legacyConfiguration)
        }
        catch { $migrationWarning = "Не удалось перенести значения pipeline.yaml; установлен шаблон JSON: $($_.Exception.Message)" }
    }
    else { $migrationWarning = 'Не найден прежний PipelineState.psm1; установлен шаблон JSON, pipeline.yaml сохранён.' }
}
$configurationStatus = if (Test-Path -LiteralPath $configurationTarget -PathType Leaf) { 'preserved' } elseif (Test-Path -LiteralPath $legacyConfiguration -PathType Leaf) { 'migrated' } else { 'installed' }
if ($ResetConfiguration) { $configurationStatus = 'reset' }
$agentsStatus = if (Test-Path -LiteralPath $agentsTarget -PathType Leaf) { 'preserved' } else { 'installed' }

if ($PSCmdlet.ShouldProcess($targetRoot, "Install pipeline $pipelineVersion")) {
    [IO.Directory]::CreateDirectory($pipelineTarget) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $pipelineTarget 'tasks')) | Out-Null
    [IO.Directory]::CreateDirectory($skillsTarget) | Out-Null
    [IO.Directory]::CreateDirectory($scriptsTarget) | Out-Null
    if (-not (Test-Path -LiteralPath $configurationTarget -PathType Leaf) -or $ResetConfiguration) {
        if ($null -ne $migratedConfiguration -and -not $ResetConfiguration) {
            [IO.File]::WriteAllText($configurationTarget, ($migratedConfiguration | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        }
        else { Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\pipeline.json') -Destination $configurationTarget -Force }
    }
    if (-not (Test-Path -LiteralPath $agentsTarget -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\templates\AGENTS.md') -Destination $agentsTarget
    }
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\references') -Destination $pipelineTarget -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\roles') -Destination $pipelineTarget -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\.gitignore') -Destination (Join-Path $pipelineTarget '.gitignore') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.pipeline\tasks\.gitkeep') -Destination (Join-Path $pipelineTarget 'tasks\.gitkeep') -Force
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'scripts\Install-PipelineToProject.ps1') -Destination (Join-Path $scriptsTarget 'Install-PipelineToProject.ps1') -Force
    foreach ($skillName in @('onec-pipeline', '1c-ai-workflow')) {
        $targetSkill = Join-Path $skillsTarget $skillName
        [IO.Directory]::CreateDirectory($targetSkill) | Out-Null
        Copy-Item -Path (Join-Path $sourceRoot ".codex\skills\$skillName\*") -Destination $targetSkill -Recurse -Force
    }
    $installed = [ordered]@{ pipeline_version = $pipelineVersion; installed_at = [datetime]::UtcNow.ToString('o'); source_sha256 = $sourceSha256 }
    [IO.File]::WriteAllText((Join-Path $pipelineTarget 'installed.json'), ($installed | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

[pscustomobject][ordered]@{
    status = if ($WhatIfPreference) { 'what_if' } else { 'installed' }
    target_project = $targetRoot; pipeline_version = $pipelineVersion; source_sha256 = $sourceSha256
    configuration = $configurationStatus; agents_md = $agentsStatus
    migration_warning = $migrationWarning
    next_step = 'Настройте VERIFY-адаптеры проекта, затем создайте задачу через $1c-ai-workflow.'
} | ConvertTo-Json -Depth 5
