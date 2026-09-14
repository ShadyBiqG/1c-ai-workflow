[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Initialize', 'Ask', 'Compact', 'Status')]
    [string]$Action,

    [string]$InputFile,
    [string]$OutputFile,
    [string]$RegistryPath,

    [ValidateSet('opus', 'sonnet', 'haiku')]
    [string]$Model = 'opus',

    [ValidateSet('low', 'medium', 'high', 'max')]
    [string]$Effort = 'high',

    [string]$ClaudePath,
    [int]$TimeoutSeconds = 1200
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ClaudeConsilium.psm1') -Force
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $projectRoot '.pipeline\local\claude-session.json'
}

if ($Action -eq 'Status') {
    $registry = Read-ClaudeSessionRegistry -Path $RegistryPath
    $registry | ConvertTo-Json -Depth 8
    exit 0
}

Assert-ClaudeProfile -Model $Model -Effort $Effort
if ([string]::IsNullOrWhiteSpace($ClaudePath)) {
    $ClaudePath = Resolve-ClaudeCodePath
}

$sessionId = $null
if ($Action -eq 'Initialize') {
    if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
        throw "Claude session registry already exists. Reuse it or obtain explicit user approval before replacement: $RegistryPath"
    }
    if ([string]::IsNullOrWhiteSpace($InputFile)) {
        throw 'Initialize requires -InputFile.'
    }
    $sessionId = [guid]::NewGuid().ToString()
}
else {
    $registry = Read-ClaudeSessionRegistry -Path $RegistryPath
    $sessionId = $registry.session_id
    $Model = $registry.model
    $Effort = $registry.effort
}

if ($Action -eq 'Compact') {
    $inputText = Get-ClaudeCompactPrompt -ProjectRoot $projectRoot
}
else {
    if ([string]::IsNullOrWhiteSpace($InputFile) -or -not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
        throw "$Action requires an existing -InputFile."
    }
    $inputText = [IO.File]::ReadAllText($InputFile, [Text.Encoding]::UTF8)
}

$arguments = @('-p', '--output-format', 'stream-json', '--verbose', '--model', $Model, '--effort', $Effort)
if ($Action -eq 'Initialize') {
    $arguments += @('--session-id', $sessionId)
}
else {
    $arguments += @('--resume', $sessionId)
}

$result = Invoke-RedirectedUtf8Process -FilePath $ClaudePath -ArgumentList $arguments -InputText $inputText -TimeoutSeconds $TimeoutSeconds
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    Write-Utf8NoBom -Path ($OutputFile + '.stdout.jsonl') -Text $result.StdOut
    Write-Utf8NoBom -Path ($OutputFile + '.stderr.log') -Text $result.StdErr
}
if ($result.ExitCode -ne 0) {
    throw "Claude Code failed with exit code $($result.ExitCode). See redirected stderr."
}

$events = ConvertFrom-ClaudeJsonLines -Text $result.StdOut
$actualSessionId = Get-ClaudeSessionIdFromEvents -Events $events
if ($actualSessionId -ne $sessionId) {
    throw "Claude session ID mismatch. Expected=$sessionId Actual=$actualSessionId"
}
$compactionOutcome = $null
if ($Action -eq 'Compact') {
    $compactionOutcome = Get-ClaudeCompactionOutcome -Events $events
}
if ($Action -eq 'Initialize') {
    Write-ClaudeSessionRegistry -Path $RegistryPath -SessionId $sessionId -Model $Model -Effort $Effort
}

$compactEvent = $events | Where-Object { $_.PSObject.Properties.Name -contains 'subtype' -and $_.subtype -eq 'compact_boundary' } | Select-Object -First 1
$receipt = [ordered]@{
    protocol_version = 1
    action = $Action.ToLowerInvariant()
    status = 'succeeded'
    session_id = $sessionId
    model = $Model
    effort = $Effort
    compact_boundary = ($null -ne $compactEvent)
    compaction_outcome = $compactionOutcome
    compact_metadata = if ($null -ne $compactEvent -and $compactEvent.PSObject.Properties.Name -contains 'compact_metadata') { $compactEvent.compact_metadata } else { $null }
    completed_at = [datetime]::UtcNow.ToString('o')
}
$receiptJson = $receipt | ConvertTo-Json -Depth 10
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    Write-Utf8NoBom -Path $OutputFile -Text $receiptJson
}
$receiptJson
