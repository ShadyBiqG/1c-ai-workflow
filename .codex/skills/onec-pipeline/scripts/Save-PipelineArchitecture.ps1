[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ArchitectureFile,
    [Parameter(Mandatory = $true)][string]$ArchitectId,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $ArchitectureFile -PathType Leaf)) { throw "Architecture file was not found: $ArchitectureFile" }
if ([string]::IsNullOrWhiteSpace($ArchitectId)) { throw 'ArchitectId must not be empty.' }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'plan') { throw "Architecture can be saved only in plan state, got: $($state.status)" }
$architecturePath = Join-Path $taskDirectory 'architecture.md'
$architectureText = [IO.File]::ReadAllText((Resolve-Path $ArchitectureFile), [Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($architectureText)) { throw 'Architecture artifact must not be empty.' }
Write-PipelineUtf8NoBom -Path $architecturePath -Text $architectureText
$manifest = [ordered]@{
    protocol_version = 1
    task_id = $TaskId
    architect_id = $ArchitectId
    architecture_sha256 = Get-PipelineFileSha256 -Path $architecturePath
    saved_at = [datetime]::UtcNow.ToString('o')
}
$manifestPath = Join-Path $taskDirectory 'architecture.json'
Write-AtomicJson -Path $manifestPath -Value $manifest
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'decision' -Phase 'plan' -Actor $ArchitectId -Summary 'Архитектурное решение сохранено и передано на независимое ревью.' -EvidencePath $architecturePath | Out-Null
$manifest | ConvertTo-Json -Depth 5
