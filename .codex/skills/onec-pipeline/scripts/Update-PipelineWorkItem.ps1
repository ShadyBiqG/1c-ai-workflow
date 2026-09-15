[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$WorkItemId,
    [Parameter(Mandatory = $true)][ValidateSet('in_progress', 'completed', 'failed')][string]$Status,
    [string]$AgentId,
    [string]$ResultFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'work') { throw "Work items can be updated only in work state, got: $($state.status)" }
$workItemsPath = Join-Path $taskDirectory 'work-items.json'
$workItems = Read-PipelineJson -Path $workItemsPath
$matches = @($workItems.items | Where-Object { $_.id -eq $WorkItemId })
if ($matches.Count -ne 1) { throw "Work item was not found or is duplicated: $WorkItemId" }
$item = $matches[0]
$allowed = @{
    pending = @('in_progress')
    in_progress = @('completed', 'failed')
    failed = @('in_progress')
    completed = @()
}
if ($allowed[[string]$item.status] -notcontains $Status) { throw "Illegal work item transition: $($item.status) -> $Status" }
if ($Status -eq 'in_progress') {
    $incompleteDependencies = @($item.depends_on | Where-Object {
        $dependencyId = $_
        @($workItems.items | Where-Object { $_.id -eq $dependencyId -and $_.status -eq 'completed' }).Count -ne 1
    })
    if ($incompleteDependencies.Count -gt 0) { throw "Work item dependencies are incomplete: $($incompleteDependencies -join ', ')" }
}
if ($Status -in @('completed', 'failed')) {
    if ([string]::IsNullOrWhiteSpace($ResultFile) -or -not (Test-Path -LiteralPath $ResultFile -PathType Leaf)) {
        throw "ResultFile is required for status $Status."
    }
    $resultDirectory = Join-Path $taskDirectory 'work-results'
    [IO.Directory]::CreateDirectory($resultDirectory) | Out-Null
    $savedResultPath = Join-Path $resultDirectory ("{0}.md" -f $WorkItemId)
    Write-PipelineUtf8NoBom -Path $savedResultPath -Text ([IO.File]::ReadAllText((Resolve-Path $ResultFile), [Text.Encoding]::UTF8))
    $item.result_path = $savedResultPath
}
if (-not [string]::IsNullOrWhiteSpace($AgentId)) { $item.agent_id = $AgentId }
$item.status = $Status
$item.updated_at = [datetime]::UtcNow.ToString('o')
Write-AtomicJson -Path $workItemsPath -Value $workItems
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'work' -Actor $(if ([string]::IsNullOrWhiteSpace($item.agent_id)) { 'manager' } else { [string]$item.agent_id }) -Summary "Work item ${WorkItemId}: $Status." -EvidencePath $item.result_path | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; work_item_id = $WorkItemId; status = $Status; result_path = $item.result_path } | ConvertTo-Json -Depth 5
