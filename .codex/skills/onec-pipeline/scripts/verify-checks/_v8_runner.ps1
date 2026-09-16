Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-NativeArgumentString {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        if ($_ -notmatch '[\s"]') { $_ }
        else { '"{0}"' -f ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') }
    }) -join ' ')
}

function Stop-PipelineProcessTree {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    if ($env:OS -eq 'Windows_NT') {
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & taskkill.exe /PID $Process.Id /T /F 2>&1 | Out-Null
        }
        finally { $ErrorActionPreference = $savedPreference }
    }
    else { try { $Process.Kill() } catch { Write-Verbose "Не удалось завершить процесс $($Process.Id): $($_.Exception.Message)" } }
    try { $Process.WaitForExit(5000) | Out-Null } catch { Write-Verbose "Не удалось дождаться процесса $($Process.Id): $($_.Exception.Message)" }
}

function Invoke-PipelineV8RunnerCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$TaskDirectory,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $configuredRunner = [string]$Configuration.verify.runner_path
    if ([string]::IsNullOrWhiteSpace($configuredRunner)) {
        $runnerCommand = Get-Command 'v8-runner.exe' -ErrorAction SilentlyContinue
        if ($null -eq $runnerCommand) { return [pscustomobject][ordered]@{ status = 'not_run'; summary = "Проверка $Name не запущена: verify.runner_path не задан и v8-runner.exe не найден в PATH."; full_output = @() } }
        $runnerPath = $runnerCommand.Source
    }
    else {
        $runnerPath = if ([IO.Path]::IsPathRooted($configuredRunner)) { [IO.Path]::GetFullPath($configuredRunner) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $configuredRunner)) }
        if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) { return [pscustomobject][ordered]@{ status = 'failed'; summary = "Проверка $Name не запущена: v8-runner не найден: $runnerPath"; full_output = @() } }
    }
    $runnerConfig = [string]$Configuration.verify.runner_config
    $configurationPath = if ([IO.Path]::IsPathRooted($runnerConfig)) { [IO.Path]::GetFullPath($runnerConfig) } else { [IO.Path]::GetFullPath((Join-Path $ProjectRoot $runnerConfig)) }
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { return [pscustomobject][ordered]@{ status = 'not_run'; summary = "Проверка $Name не запущена: конфигурация v8-runner не найдена: $configurationPath"; full_output = @() } }

    $timeoutSeconds = [int]$Configuration.verify.timeout_seconds
    if ($Configuration.verify.timeout_overrides.Contains($Name)) { $timeoutSeconds = [int]$Configuration.verify.timeout_overrides[$Name] }
    $allArguments = @('--config', $configurationPath, '--no-color') + @($Arguments)
    $processFilePath = $runnerPath
    $argumentString = ConvertTo-NativeArgumentString -Arguments $allArguments
    if ([IO.Path]::GetExtension($runnerPath) -in @('.cmd', '.bat')) {
        $processFilePath = $env:ComSpec
        $argumentString = '/d /s /c ""{0}" {1}"' -f $runnerPath, $argumentString
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $processFilePath
    $startInfo.Arguments = $argumentString
    $startInfo.WorkingDirectory = $ProjectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $savedPreference = $ErrorActionPreference
    $nativePreferenceExisted = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($nativePreferenceExisted) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $false }
        if (-not $process.Start()) { throw "Не удалось запустить $processFilePath." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $completed) { Stop-PipelineProcessTree -Process $process }
        $process.WaitForExit()
        $stdoutText = $stdoutTask.Result
        $stderrText = $stderrTask.Result
        $exitCode = if ($completed) { $process.ExitCode } else { $null }
    }
    finally {
        $stopwatch.Stop()
        $ErrorActionPreference = $savedPreference
        if ($nativePreferenceExisted) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
    }
    $output = @(($stdoutText -split '\r?\n') + ($stderrText -split '\r?\n') | Where-Object { $_ -ne '' })
    $tail = @($output | Select-Object -Last 30 | ForEach-Object { [string]$_ })
    return [pscustomobject][ordered]@{
        status = if (-not $completed -or $exitCode -ne 0) { 'failed' } else { 'passed' }
        summary = if (-not $completed) { "Проверка $Name превысила таймаут ${timeoutSeconds} с; длительность $($stopwatch.ElapsedMilliseconds) мс." } elseif ($exitCode -eq 0) { "Проверка $Name выполнена через v8-runner." } else { "Проверка $Name завершилась с кодом $exitCode." }
        command = @($Arguments); exit_code = $exitCode; output_tail = $tail
        full_output = @($output | ForEach-Object { [string]$_ }); timed_out = (-not $completed)
    }
}
