[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$MemoryFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $MemoryFile -PathType Leaf)) { throw "Memory file was not found: $MemoryFile" }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
$memoryPath = Join-Path $taskDirectory 'memory.md'
Write-PipelineUtf8NoBom -Path $memoryPath -Text ([IO.File]::ReadAllText((Resolve-Path $MemoryFile), [Text.Encoding]::UTF8))
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'note' -Phase ([string]$state.status) -Actor 'manager' -Summary 'Обновлена долговременная память задачи.' -EvidencePath $memoryPath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; status = $state.status; memory_path = $memoryPath } | ConvertTo-Json -Depth 5
