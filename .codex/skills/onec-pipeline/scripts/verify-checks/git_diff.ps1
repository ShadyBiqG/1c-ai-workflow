[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Configuration)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$probe = @(& git -c core.autocrlf=false -C $ProjectRoot rev-parse --is-inside-work-tree 2>&1)
if ($LASTEXITCODE -ne 0 -or $probe -notcontains 'true') {
    return [pscustomobject][ordered]@{ status = 'failed'; summary = 'Проект не является Git-репозиторием.'; changed_files = @() }
}
$files = New-Object Collections.Generic.List[string]
foreach ($arguments in @(
    @('diff', '--relative', '--name-only', '--'),
    @('diff', '--cached', '--relative', '--name-only', '--'),
    @('ls-files', '--others', '--exclude-standard')
)) {
    $output = @(& git -c core.autocrlf=false -C $ProjectRoot @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject][ordered]@{ status = 'failed'; summary = "Ошибка git diff: $($output -join [Environment]::NewLine)"; changed_files = @() }
    }
    foreach ($path in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $files.Add(([string]$path).Replace('\', '/')) }
    }
}
$changedFiles = @($files | Where-Object { $_ -notmatch '^\.pipeline/tasks/' } | Sort-Object -Unique)
$configDumpFiles = @($changedFiles | Where-Object { [IO.Path]::GetFileName($_) -ieq 'ConfigDumpInfo.xml' })
$failed = [bool]$Configuration.verify.fail_on_config_dump_info -and $configDumpFiles.Count -gt 0
[pscustomobject][ordered]@{
    status = if ($failed) { 'failed' } else { 'passed' }
    summary = if ($failed) { 'Обнаружено изменение ConfigDumpInfo.xml; требуется явная проверка.' } else { "Изменённых файлов: $($changedFiles.Count)." }
    changed_files = $changedFiles
    config_dump_info_files = $configDumpFiles
}
