[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^UT-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ThreadReadFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$runtimeDirectory = Join-Path $ProjectRoot ".pipeline\runtime\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$taskReadyPath = Join-Path $runtimeDirectory 'task-ready.json'
$deliveryPath = Join-Path $runtimeDirectory 'task-ready-delivery.json'
$state = Read-PipelineJson -Path $statePath

if ($state.status -eq 'plan_requested') {
    $existingDelivery = Read-PipelineJson -Path $deliveryPath
    if ($existingDelivery.PSObject.Properties.Name -notcontains 'routing_release_message') {
        $existingDelivery | Add-Member -NotePropertyName routing_release_message -NotePropertyValue ("ROUTING_RELEASED {0} Read state.json and route the task to Plan." -f $TaskId)
        Write-AtomicJson -Path $deliveryPath -Value $existingDelivery
    }
    $existingDelivery | ConvertTo-Json -Depth 10
    exit 0
}
if ($state.status -ne 'task_ready_pending') {
    throw "TASK_READY delivery cannot be confirmed from state: $($state.status)"
}
$taskReady = Read-PipelineJson -Path $taskReadyPath
$threadRead = Read-PipelineJson -Path $ThreadReadFile
if ($threadRead.task_id -ne $TaskId -or ([datetime]$threadRead.captured_at).ToUniversalTime() -lt ([datetime]$taskReady.created_at).ToUniversalTime()) {
    throw 'Manager thread read is stale or belongs to a different pipeline task.'
}
if ($threadRead.app_read.thread.id -ne $taskReady.manager_thread_id) {
    throw 'TASK_READY was not delivered to the registered Manager task.'
}
$matchingTurns = @{}
foreach ($turn in @($threadRead.app_read.turns)) {
    if ($turn.status -ne 'completed') { continue }
    foreach ($item in @($turn.items)) {
        if ($item.type -ne 'userMessage') { continue }
        foreach ($content in @($item.content)) {
            if ($content.PSObject.Properties.Name -contains 'codexDelegation' -and $content.codexDelegation.input -ceq $taskReady.message) {
                $matchingTurns[[string]$turn.id] = $turn
            }
        }
    }
}
if ($matchingTurns.Count -eq 0) {
    throw 'Manager thread read does not contain a completed TASK_READY message.'
}
$observedTurn = @($matchingTurns.Values | Sort-Object @{ Expression = { [double]$_.completedAt } }, @{ Expression = { [string]$_.id } })[0]

$delivery = [ordered]@{
    protocol_version = 1
    task_id = $TaskId
    status = 'completed'
    manager_thread_id = $taskReady.manager_thread_id
    turn_id = $observedTurn.id
    message_sha256 = $taskReady.message_sha256
    thread_read_sha256 = Get-FileSha256 -Path $ThreadReadFile
    routing_release_message = "ROUTING_RELEASED $TaskId Read state.json and route the task to Plan."
    confirmed_at = [datetime]::UtcNow.ToString('o')
}
Write-AtomicJson -Path $deliveryPath -Value $delivery
$state = Set-PipelineTransition -State $state -Transition 'plan_requested' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'plan_requested')
Write-AtomicJson -Path $statePath -Value $state
$delivery | ConvertTo-Json -Depth 10
