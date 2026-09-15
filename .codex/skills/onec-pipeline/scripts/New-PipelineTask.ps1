[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
}
if (-not (Test-Path -LiteralPath $RequestFile -PathType Leaf)) { throw "Request file was not found: $RequestFile" }

$taskId = New-PipelineTaskId
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$taskId"
[IO.Directory]::CreateDirectory($taskDirectory) | Out-Null
$requestText = [IO.File]::ReadAllText((Resolve-Path $RequestFile), [Text.Encoding]::UTF8)
Write-PipelineUtf8NoBom -Path (Join-Path $taskDirectory 'request.md') -Text $requestText
Write-AtomicJson -Path (Join-Path $taskDirectory 'state.json') -Value (New-PipelineState -TaskId $taskId)
$memoryText = @"
# Память задачи $taskId

## Текущий статус

PLAN: требования приняты в работу, исследование и планирование ещё не завершены.

## Подтверждённые факты

- Исходный запрос сохранён в `request.md`.

## Ключевые решения

- Пока нет.

## Открытые вопросы и риски

- Определяются во время исследования.

## Следующий шаг

- Оценить сложность, исследовать проект и сформировать план с test-plan.
"@
Write-PipelineUtf8NoBom -Path (Join-Path $taskDirectory 'memory.md') -Text $memoryText
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'plan' -Actor 'manager' -Summary 'Задача создана, исходный запрос сохранён.' -EvidencePath (Join-Path $taskDirectory 'request.md') | Out-Null

[pscustomobject][ordered]@{
    task_id = $taskId
    status = 'plan'
    task_directory = $taskDirectory
} | ConvertTo-Json -Depth 5
