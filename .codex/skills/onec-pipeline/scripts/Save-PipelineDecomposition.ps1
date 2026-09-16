[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$DecompositionFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'plan') { throw "Decomposition can be saved only in plan state, got: $($state.status)" }
$decomposition = Read-PipelineJson -Path $DecompositionFile
Test-PipelineDecomposition -Decomposition $decomposition | Out-Null
$savedPath = Join-Path $taskDirectory 'decomposition.json'
Write-AtomicJson -Path $savedPath -Value $decomposition
$items = @($decomposition.work_items | ForEach-Object {
    [ordered]@{
        id = $_.id; title = $_.title; role = $_.role; depends_on = @($_.depends_on)
        paths = @($_.paths); acceptance_criteria = @($_.acceptance_criteria); test_requirements = @($_.test_requirements)
        parallel_safe = [bool]$_.parallel_safe; status = 'pending'; agent_id = $null; result_path = $null; updated_at = [datetime]::UtcNow.ToString('o')
    }
})
Write-AtomicJson -Path (Join-Path $taskDirectory 'work-items.json') -Value ([ordered]@{ protocol_version = 1; task_id = $TaskId; items = $items })
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'decision' -Phase 'plan' -Actor 'manager' -Summary "Декомпозиция сохранена: $($items.Count) work items, сложность $($decomposition.complexity)." -Rationale ([string]$decomposition.summary) -EvidencePath $savedPath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; complexity = $decomposition.complexity; work_items = $items.Count; decomposition_path = $savedPath } | ConvertTo-Json -Depth 5
