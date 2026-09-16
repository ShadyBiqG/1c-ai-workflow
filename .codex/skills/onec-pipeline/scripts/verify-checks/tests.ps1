[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)]$Configuration,
    [Parameter(Mandatory = $true)][string]$TaskDirectory
)

. (Join-Path $PSScriptRoot '_v8_runner.ps1')
$scope = [string]$Configuration.verify.tests_scope
$selectedModules = @()
$fallbackReason = $null
if ($scope -eq 'impacted') {
    $contextPath = Join-Path $TaskDirectory 'verify-context.json'
    $changedFiles = if (Test-Path -LiteralPath $contextPath) { @(([IO.File]::ReadAllText($contextPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).changed_files) } else { @() }
    $selectedModules = @($changedFiles | Where-Object { $_ -match '\.(bsl|os)$' } | ForEach-Object {
        $segments = ([string]$_).Replace('\', '/').Split('/')
        if ($segments.Count -ge 3) { $segments[$segments.Count - 3] }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($selectedModules.Count -eq 0) { $scope = 'all_fallback'; $fallbackReason = 'Изменённые файлы не удалось сопоставить с тестовыми модулями.' }
}

if ($scope -in @('all', 'all_fallback')) {
    $result = Invoke-PipelineV8RunnerCheck -ProjectRoot $ProjectRoot -Configuration $Configuration -TaskDirectory $TaskDirectory -Name 'tests' -Arguments @('test', '--no-build', 'yaxunit', 'all')
}
else {
    $moduleResults = @($selectedModules | ForEach-Object {
        Invoke-PipelineV8RunnerCheck -ProjectRoot $ProjectRoot -Configuration $Configuration -TaskDirectory $TaskDirectory -Name 'tests' -Arguments @('test', '--no-build', 'yaxunit', 'module', $_)
    })
    $statuses = @($moduleResults.status)
    $combinedOutput = @($moduleResults | ForEach-Object { @($_.full_output) })
    $combinedTail = @($combinedOutput | Select-Object -Last 30)
    $result = [pscustomobject][ordered]@{
        status = if ($statuses -contains 'failed') { 'failed' } elseif ($statuses -contains 'not_run') { 'not_run' } else { 'passed' }
        summary = "YAxUnit: проверены затронутые модули: $($selectedModules -join ', ')."
        command = @($moduleResults.command); exit_code = @($moduleResults.exit_code)
        output_tail = $combinedTail; full_output = $combinedOutput
        timed_out = [bool](@($moduleResults | Where-Object { $_.timed_out }).Count -gt 0)
    }
}
$result | Add-Member -NotePropertyName tests_scope -NotePropertyValue $scope
$result | Add-Member -NotePropertyName selected_modules -NotePropertyValue $selectedModules
$result | Add-Member -NotePropertyName fallback_reason -NotePropertyValue $fallbackReason
$result
