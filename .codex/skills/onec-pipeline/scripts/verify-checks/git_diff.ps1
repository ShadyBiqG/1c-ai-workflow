[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)]$Configuration,
    [Parameter(Mandatory = $true)][string]$TaskDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-SafeGit {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $nativePreferenceExisted = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($nativePreferenceExisted) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $false }
        $output = @(& git -c core.autocrlf=false -C $ProjectRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
    }
    return [pscustomobject]@{ output = @($output | ForEach-Object { [string]$_ }); exit_code = $exitCode }
}

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$allOutput = New-Object Collections.Generic.List[string]
$probe = Invoke-SafeGit -Arguments @('rev-parse', '--is-inside-work-tree')
foreach ($line in $probe.output) { $allOutput.Add($line) }
if ($probe.exit_code -ne 0 -or $probe.output -notcontains 'true') {
    $stopwatch.Stop()
    return [pscustomobject][ordered]@{ status = 'failed'; summary = 'Проект не является Git-репозиторием.'; reason = 'not_git'; changed_files = @(); full_output = $allOutput.ToArray() }
}
$files = New-Object Collections.Generic.List[string]
foreach ($arguments in @(
    @('diff', '--relative', '--name-only', '--'),
    @('diff', '--cached', '--relative', '--name-only', '--'),
    @('ls-files', '--others', '--exclude-standard')
)) {
    $result = Invoke-SafeGit -Arguments $arguments
    foreach ($line in $result.output) { $allOutput.Add($line) }
    if ($result.exit_code -ne 0) {
        $stopwatch.Stop()
        return [pscustomobject][ordered]@{ status = 'failed'; summary = "Ошибка git diff: $($result.output -join [Environment]::NewLine)"; reason = 'git_error'; changed_files = @(); full_output = $allOutput.ToArray() }
    }
    foreach ($path in $result.output) {
        if (-not [string]::IsNullOrWhiteSpace($path)) { $files.Add($path.Replace('\', '/')) }
    }
}
$changedFiles = @($files | Where-Object { $_ -notmatch '^\.pipeline/tasks/' } | Sort-Object -Unique)
$configDumpFiles = @($changedFiles | Where-Object { [IO.Path]::GetFileName($_) -ieq 'ConfigDumpInfo.xml' })
$unexpectedPaths = @()
if ([bool]$Configuration.manager.require_decomposition) {
    $decomposition = [IO.File]::ReadAllText((Join-Path $TaskDirectory 'decomposition.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $workItems = [IO.File]::ReadAllText((Join-Path $TaskDirectory 'work-items.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $completedIds = @($workItems.items | Where-Object { $_.status -eq 'completed' } | ForEach-Object { [string]$_.id })
    $declaredPaths = @($decomposition.work_items | Where-Object { [string]$_.id -in $completedIds } | ForEach-Object { @($_.paths) } | ForEach-Object { ([string]$_).Replace('\', '/').TrimEnd('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $unexpectedPaths = @($changedFiles | Where-Object {
        $changedPath = $_
        @($declaredPaths | Where-Object { $changedPath.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) -or $changedPath.Equals($_, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
    })
}
$reason = $null
$failed = $false
if ($changedFiles.Count -eq 0) { $failed = $true; $reason = 'no_changes' }
elseif ([bool]$Configuration.verify.fail_on_config_dump_info -and $configDumpFiles.Count -gt 0) { $failed = $true; $reason = 'config_dump_info' }
elseif ([bool]$Configuration.verify.fail_on_unexpected_paths -and $unexpectedPaths.Count -gt 0) { $failed = $true; $reason = 'unexpected_paths' }
$stopwatch.Stop()
[pscustomobject][ordered]@{
    status = if ($failed) { 'failed' } else { 'passed' }
    summary = if ($reason -eq 'no_changes') { 'Изменённые файлы отсутствуют.' } elseif ($reason -eq 'unexpected_paths') { "Обнаружены изменения вне decomposition: $($unexpectedPaths -join ', ')." } elseif ($reason -eq 'config_dump_info') { 'Обнаружено изменение ConfigDumpInfo.xml; требуется явная проверка.' } else { "Изменённых файлов: $($changedFiles.Count)." }
    reason = $reason; changed_files = $changedFiles; config_dump_info_files = $configDumpFiles
    unexpected_paths = $unexpectedPaths; full_output = $allOutput.ToArray()
}
