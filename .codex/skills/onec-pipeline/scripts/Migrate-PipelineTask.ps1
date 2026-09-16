[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [switch]$Adopt,
    [hashtable]$AdoptedPaths
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

$statePath = Join-Path $TaskDirectory 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Task state not found' }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ([int]$state.protocol_version -ge 2) { return [pscustomobject]@{status='already_v2'} | ConvertTo-Json }
if ($state.status -ne 'plan') { throw "Only a v1 PLAN task can be migrated; got: $($state.status)" }
if (-not $Adopt -or $null -eq $AdoptedPaths -or $AdoptedPaths.Count -eq 0) { throw 'V1 migration requires explicit adopted paths and hashes' }

$projectRoot = [IO.Path]::GetFullPath((Join-Path $TaskDirectory '..\..\..'))
$verifiedPaths = [ordered]@{}
foreach ($path in @($AdoptedPaths.Keys)) {
    $canonical = Get-PipelineCanonicalPath -Path ([string]$path) -ProjectRoot $projectRoot
    if ($canonical -cne ([string]$path).Replace('\','/')) { throw "Adopted path is not canonical: $path" }
    $fullPath = Join-Path $projectRoot $canonical
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Adopted path does not exist: $canonical" }
    $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$AdoptedPaths[$path]).ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Adopted path hash mismatch: $canonical" }
    $verifiedPaths[$canonical] = $actualHash
}

$rawRequestPath = Join-Path $TaskDirectory 'request.raw.md'
$legacyRequestPath = Join-Path $TaskDirectory 'request.legacy-interpreted.md'
$requestPath = Join-Path $TaskDirectory 'request.md'
if (-not (Test-Path -LiteralPath $rawRequestPath) -and (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
    Write-PipelineImmutableText -Path $legacyRequestPath -Text (Get-Content -LiteralPath $requestPath -Raw) | Out-Null
}

$state.protocol_version=2
$state.status='plan'
$state | Add-Member NoteProperty migration ([pscustomobject]@{from=1;at=[datetime]::UtcNow.ToString('o');mode='full_replan';adopted_paths=$verifiedPaths}) -Force
$outputPath = Join-Path $TaskDirectory 'state.v2.json'
Write-PipelineImmutableJson -Path $outputPath -Value $state | Out-Null
[pscustomobject]@{status='migrated';path=$outputPath;mode='full_replan';adopted_paths=$verifiedPaths}|ConvertTo-Json -Depth 10
