[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^UT-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ControllerThreadId,
    [string]$ProjectRoot,
    [switch]$Force,
    [switch]$WhatIf
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
}
$invokeScript = Join-Path $PSScriptRoot 'Invoke-PipelineBoundary.ps1'
$powerShell = (Get-Command powershell.exe).Source
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$invokeScript`" -TaskId $TaskId -ControllerThreadId $ControllerThreadId -ProjectRoot `"$ProjectRoot`""
if ($Force) {
    $arguments += ' -Force'
}
$launch = [ordered]@{
    executable = $powerShell
    arguments = $arguments
    window_style = 'Hidden'
    task_id = $TaskId
}
if ($WhatIf) {
    $launch | ConvertTo-Json -Compress
    exit 0
}

$process = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
$launch.process_id = $process.Id
$launch | ConvertTo-Json -Compress
