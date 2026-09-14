[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [Parameter(Mandatory = $true)][string]$IntakeCorrelationId,
    [string]$ProjectRoot,
    [datetime]$Now = [datetime]::UtcNow,
    [string]$Entropy = ([guid]::NewGuid().ToString('N').Substring(0, 4))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
}
$result = New-PipelineTaskArtifacts -ProjectRoot $ProjectRoot -RequestFile $RequestFile -IntakeCorrelationId $IntakeCorrelationId -Now $Now -Entropy $Entropy
$result | ConvertTo-Json -Depth 10 -Compress
