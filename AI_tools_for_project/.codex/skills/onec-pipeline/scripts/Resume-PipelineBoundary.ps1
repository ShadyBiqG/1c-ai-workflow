[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^UT-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ApprovedBy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$runtimeDirectory = Join-Path $ProjectRoot ".pipeline\runtime\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
if ($state.status -ne 'blocked') {
    throw "Boundary recovery requires blocked state, got: $($state.status)"
}

$recoveryId = [guid]::NewGuid().ToString('N')
$recovery = [ordered]@{
    protocol_version = 1
    task_id = $TaskId
    approved_by = $ApprovedBy
    recovery_id = $recoveryId
    approved_at = [datetime]::UtcNow.ToString('o')
}
[IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null
Write-AtomicJson -Path (Join-Path $runtimeDirectory ("recovery-{0}.json" -f $recoveryId)) -Value $recovery
$state = Set-PipelineTransition -State $state -Transition 'compacting' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'compacting' -AttemptId $recoveryId)
Write-AtomicJson -Path $statePath -Value $state
$recovery | ConvertTo-Json -Depth 10
