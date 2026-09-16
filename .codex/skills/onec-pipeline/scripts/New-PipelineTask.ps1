[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [string]$ProjectRoot,[switch]$Explicit,[switch]$SelfMaintenance
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
}
if (-not (Test-Path -LiteralPath $RequestFile -PathType Leaf)) { throw "Request file was not found: $RequestFile" }
$requestText = [IO.File]::ReadAllText((Resolve-Path $RequestFile), [Text.Encoding]::UTF8)
$applicability=& (Join-Path $PSScriptRoot 'Test-PipelineApplicability.ps1') -ProjectRoot $ProjectRoot -RequestText $requestText -Explicit:$Explicit -SelfMaintenance:$SelfMaintenance | ConvertFrom-Json
if(-not $applicability.applicable){[pscustomobject]@{status='not_applicable';applicability=$applicability.classification;routing_manifest=$applicability.routing_manifest}|ConvertTo-Json -Depth 12;return}

$taskId = New-PipelineTaskId
$tasksRoot=Join-Path $ProjectRoot '.pipeline\tasks';$staging=Join-Path $tasksRoot ('.staging-'+$taskId);$taskDirectory=Join-Path $tasksRoot $taskId
try { [IO.Directory]::CreateDirectory($tasksRoot) | Out-Null;[IO.Directory]::CreateDirectory($staging) | Out-Null;$taskDirectory=$staging
Write-PipelineUtf8NoBom -Path (Join-Path $taskDirectory 'request.md') -Text $requestText
Write-PipelineImmutableText -Path (Join-Path $taskDirectory 'request.raw.md') -Text $requestText | Out-Null
$baseline = New-PipelineBaselineRecord -ProjectRoot $ProjectRoot
Write-PipelineImmutableJson -Path (Join-Path $taskDirectory 'baseline.json') -Value $baseline | Out-Null
Write-PipelineImmutableJson -Path (Join-Path $taskDirectory 'tombstones.json') -Value (New-PipelineTombstoneInventory -Baseline $baseline -ProjectRoot $ProjectRoot) | Out-Null
New-Item -ItemType Directory -Path (Join-Path $taskDirectory 'request-addenda') -Force | Out-Null
Write-PipelineImmutableJson -Path (Join-Path $taskDirectory 'request-sources.json') -Value ([ordered]@{ protocol_version=2; sources=@([ordered]@{ path='request.raw.md'; kind='user_message'; trusted_as_instruction=$true }) }) | Out-Null
$state=New-PipelineState -TaskId $taskId;$state.applicability=$applicability.classification;Write-PipelineImmutableJson -Path (Join-Path $taskDirectory 'applicability.json') -Value $applicability|Out-Null;Write-AtomicJson -Path (Join-Path $taskDirectory 'state.json') -Value $state
$memoryText = @"
# Память задачи $taskId

## Текущий статус

PLAN: требования приняты в работу, исследование и планирование ещё не завершены.

## Подтверждённые факты

    - Исходный запрос сохранён в `request.raw.md`; `request.md` — совместимое представление.
    - Снимок рабочего дерева сохранён в `baseline.json` до исследования.

## Ключевые решения

- Пока нет.

## Открытые вопросы и риски

- Определяются во время исследования.

## Следующий шаг

- Оценить сложность, исследовать проект и сформировать план с test-plan.
"@
Write-PipelineUtf8NoBom -Path (Join-Path $taskDirectory 'memory.md') -Text $memoryText
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'plan' -Actor 'manager' -Summary 'Задача создана, исходный запрос сохранён.' -EvidencePath (Join-Path $taskDirectory 'request.md') | Out-Null

[IO.Directory]::Move($staging,$taskDirectory.Replace($staging,$taskId))
$taskDirectory=Join-Path $tasksRoot $taskId

[pscustomobject][ordered]@{
    task_id = $taskId
    status = 'plan'
    task_directory = $taskDirectory
} | ConvertTo-Json -Depth 5
} catch { if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue};throw }
