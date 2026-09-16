[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ConfigurationPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
else { $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot) }
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { $ConfigurationPath = Join-Path $ProjectRoot '.pipeline\pipeline.json' }

$blockers = New-Object Collections.Generic.List[string]
$warnings = New-Object Collections.Generic.List[string]
$details = [ordered]@{}

$installedPath = Join-Path $ProjectRoot '.pipeline\installed.json'
if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
    try { $details.pipeline_version = ([IO.File]::ReadAllText($installedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).pipeline_version }
    catch { $warnings.Add("Не удалось прочитать .pipeline/installed.json: $($_.Exception.Message)") }
}

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { $blockers.Add("Каталог проекта не найден: $ProjectRoot") }

$configuration = $null
try {
    $configuration = Read-PipelineConfiguration -Path $ConfigurationPath
    $details.configuration = 'valid'
}
catch {
    $details.configuration = 'invalid'
    $blockers.Add($_.Exception.Message)
}

if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot 'AGENTS.md') -PathType Leaf)) { $blockers.Add('В корне проекта отсутствует обязательный AGENTS.md.') }

foreach ($skillName in @('onec-pipeline', '1c-ai-workflow')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot ".codex\skills\$skillName\SKILL.md") -PathType Leaf)) {
        $blockers.Add("Не установлен project skill: $skillName")
    }
}

$gitCommand = Get-Command 'git' -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $blockers.Add('Git не найден в PATH.') }
else {
    $savedPreference = $ErrorActionPreference
    $nativePreferenceExisted = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($nativePreferenceExisted) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $false }
        $gitProbe = @(& git -C $ProjectRoot rev-parse --is-inside-work-tree 2>&1)
        $gitProbeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
    }
    if ($gitProbeExitCode -ne 0 -or ($gitProbe -join '').Trim() -ne 'true') { $blockers.Add('Каталог проекта не находится внутри Git worktree.') }
    else {
        $changedFiles = @(& git -C $ProjectRoot status --short 2>$null)
        $details.changed_files = $changedFiles.Count
        if ($changedFiles.Count -gt 0) { $warnings.Add("Рабочее дерево содержит изменений: $($changedFiles.Count). Manager должен зафиксировать исходный snapshot и не смешивать чужие изменения с задачей.") }
    }
}

if ($null -ne $configuration) {
    foreach ($checkName in @($configuration.verify.checks)) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "verify-checks\$checkName.ps1") -PathType Leaf)) { $blockers.Add("Не найден VERIFY adapter: $checkName") }
    }

    $runnerPath = [string]$configuration.verify.runner_path
    if ([string]::IsNullOrWhiteSpace($runnerPath)) {
        $runnerCommand = Get-Command 'v8-runner.exe' -ErrorAction SilentlyContinue
        if ($null -eq $runnerCommand) { $blockers.Add('Не задан verify.runner_path и v8-runner.exe не найден в PATH.') }
        else { $details.runner_path = $runnerCommand.Source }
    }
    else {
        $resolvedRunnerPath = if ([IO.Path]::IsPathRooted($runnerPath)) { [IO.Path]::GetFullPath($runnerPath) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $runnerPath)) }
        $details.runner_path = $resolvedRunnerPath
        if (-not (Test-Path -LiteralPath $resolvedRunnerPath -PathType Leaf)) { $blockers.Add("Не найден v8-runner: $resolvedRunnerPath") }
    }

    $runnerConfig = [string]$configuration.verify.runner_config
    $resolvedRunnerConfig = if ([IO.Path]::IsPathRooted($runnerConfig)) { [IO.Path]::GetFullPath($runnerConfig) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $runnerConfig)) }
    $details.runner_config = $resolvedRunnerConfig
    if (-not (Test-Path -LiteralPath $resolvedRunnerConfig -PathType Leaf)) { $blockers.Add("Не найдена конфигурация v8-runner: $resolvedRunnerConfig") }
}

[pscustomobject][ordered]@{
    status = if ($blockers.Count -eq 0) { 'ready' } else { 'blocked' }
    project_root = $ProjectRoot
    blockers = $blockers.ToArray()
    warnings = $warnings.ToArray()
    details = $details
} | ConvertTo-Json -Depth 10
