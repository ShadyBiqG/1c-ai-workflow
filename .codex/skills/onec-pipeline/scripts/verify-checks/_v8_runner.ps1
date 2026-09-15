Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-PipelineV8RunnerCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $configuredRunner = [string]$Configuration.verify.runner_path
    if ([string]::IsNullOrWhiteSpace($configuredRunner)) {
        $runnerCommand = Get-Command 'v8-runner.exe' -ErrorAction SilentlyContinue
        if ($null -eq $runnerCommand) {
            return [pscustomobject][ordered]@{
                status = 'not_run'
                summary = "Проверка $Name не запущена: verify.runner_path не задан и v8-runner.exe не найден в PATH."
            }
        }
        $runnerPath = $runnerCommand.Source
    }
    else {
        $runnerPath = if ([IO.Path]::IsPathRooted($configuredRunner)) {
            [IO.Path]::GetFullPath($configuredRunner)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $ProjectRoot $configuredRunner))
        }
        if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
            return [pscustomobject][ordered]@{
                status = 'failed'
                summary = "Проверка $Name не запущена: v8-runner не найден: $runnerPath"
            }
        }
    }

    $runnerConfig = [string]$Configuration.verify.runner_config
    $configurationPath = if ([IO.Path]::IsPathRooted($runnerConfig)) {
        [IO.Path]::GetFullPath($runnerConfig)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $ProjectRoot $runnerConfig))
    }
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            status = 'not_run'
            summary = "Проверка $Name не запущена: конфигурация v8-runner не найдена: $configurationPath"
        }
    }

    $output = @(& $runnerPath --config $configurationPath --no-color @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $tail = @($output | Select-Object -Last 30 | ForEach-Object { [string]$_ })
    return [pscustomobject][ordered]@{
        status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        summary = if ($exitCode -eq 0) { "Проверка $Name выполнена через v8-runner." } else { "Проверка $Name завершилась с кодом $exitCode." }
        command = @($Arguments)
        exit_code = $exitCode
        output_tail = $tail
    }
}
