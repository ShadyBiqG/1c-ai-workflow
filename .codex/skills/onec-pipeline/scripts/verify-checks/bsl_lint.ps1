[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)]$Configuration,
    [Parameter(Mandatory = $true)][string]$TaskDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Measure-PipelineDiagnostic {
    param($Node)
    if ($null -eq $Node) { return 0 }
    $count = 0
    if ($Node -is [Collections.IEnumerable] -and $Node -isnot [string] -and $Node -isnot [pscustomobject]) {
        foreach ($item in $Node) { $count += Measure-PipelineDiagnostic -Node $item }
        return $count
    }
    if ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -eq 'diagnostics') { $count += @($property.Value).Count }
            else { $count += Measure-PipelineDiagnostic -Node $property.Value }
        }
    }
    return $count
}
$configuredPath = [string]$Configuration.verify.bsl_ls_path
if ([string]::IsNullOrWhiteSpace($configuredPath)) {
    $command = Get-Command 'bsl-language-server' -ErrorAction SilentlyContinue
    if ($null -eq $command) { return [pscustomobject][ordered]@{ status = 'not_run'; summary = 'verify.bsl_ls_path не задан и bsl-language-server не найден в PATH.'; issues = 0; report_path = $null; full_output = @() } }
    $executable = $command.Source
}
else {
    $executable = if ([IO.Path]::IsPathRooted($configuredPath)) { [IO.Path]::GetFullPath($configuredPath) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $configuredPath)) }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return [pscustomobject][ordered]@{ status = 'failed'; summary = "bsl-language-server не найден: $executable"; issues = 0; report_path = $null; full_output = @() } }
}
$contextPath = Join-Path $TaskDirectory 'verify-context.json'
$changedFiles = if (Test-Path -LiteralPath $contextPath) { @(([IO.File]::ReadAllText($contextPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).changed_files) } else { @() }
$analyzedFiles = @($changedFiles | Where-Object { $_ -match '\.(bsl|os)$' })
if ($analyzedFiles.Count -gt 0) {
    $sourceDirectory = Join-Path $TaskDirectory ("verify-input\bsl-lint-{0}" -f [guid]::NewGuid().ToString('N'))
    foreach ($relativePath in $analyzedFiles) {
        $sourcePath = Join-Path $ProjectRoot $relativePath
        $targetPath = Join-Path $sourceDirectory $relativePath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath
    }
}
else {
    $sourceDirectory = Join-Path $ProjectRoot 'src'
    if (-not (Test-Path -LiteralPath $sourceDirectory)) { $sourceDirectory = $ProjectRoot }
}
$reportDirectory = Join-Path $TaskDirectory ("verify-reports\bsl-lint-{0}" -f [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
$configPath = [string]$Configuration.verify.bsl_ls_config
if (-not [IO.Path]::IsPathRooted($configPath)) { $configPath = Join-Path $ProjectRoot $configPath }
$arguments = @('analyze', '--reporter', 'json', '--outputDir', $reportDirectory, '--configuration', $configPath, '--srcDir', $sourceDirectory)
$savedPreference = $ErrorActionPreference
$nativePreferenceExisted = Test-Path Variable:PSNativeCommandUseErrorActionPreference
if ($nativePreferenceExisted) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $false }
    $output = @(& $executable @arguments 2>&1)
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedPreference
    if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
}
$report = Get-ChildItem -LiteralPath $reportDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$issues = 0
if ($null -ne $report) {
    $reportData = [IO.File]::ReadAllText($report.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $issues = Measure-PipelineDiagnostic -Node $reportData
}
$failed = $exitCode -ne 0 -or $issues -gt [int]$Configuration.verify.bsl_lint_max_issues
[pscustomobject][ordered]@{
    status = if ($failed) { 'failed' } else { 'passed' }
    summary = "BSL Language Server: замечаний $issues, допустимо $($Configuration.verify.bsl_lint_max_issues)."
    issues = $issues; analyzed_files = $analyzedFiles
    report_path = if ($null -eq $report) { $null } else { $report.FullName.Substring($ProjectRoot.Length).TrimStart('\', '/').Replace('\', '/') }
    command = $arguments; exit_code = $exitCode; output_tail = @($output | Select-Object -Last 30 | ForEach-Object { [string]$_ }); full_output = @($output | ForEach-Object { [string]$_ })
}
