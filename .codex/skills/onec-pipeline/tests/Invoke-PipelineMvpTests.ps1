[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $projectRoot 'TestResults\pester-nunit.xml' }
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) { throw 'Для тестов требуется Pester 5 или новее. Установите: Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser' }
Import-Module $pester.Path -Force
[IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'Pipeline.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = $OutputPath
$configuration.TestResult.OutputFormat = 'NUnitXml'
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0) { throw "Pester: провалено тестов $($result.FailedCount). Отчёт: $OutputPath" }
$result
