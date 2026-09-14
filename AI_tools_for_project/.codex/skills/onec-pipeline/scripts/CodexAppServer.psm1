Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-CodexWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Resolve-CodexExecutable {
    param(
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$UserProfileRoot = $env:USERPROFILE
    )

    if (-not [string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        $binRoot = Join-Path $LocalAppDataRoot 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $binRoot -PathType Container) {
            $localCandidate = Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($null -ne $localCandidate) {
                return $localCandidate.FullName
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($UserProfileRoot)) {
        $pluginCandidate = Join-Path $UserProfileRoot '.codex\plugins\.plugin-appserver\codex.exe'
        if (Test-Path -LiteralPath $pluginCandidate -PathType Leaf) {
            return $pluginCandidate
        }
    }

    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'codex.exe was not found.'
    }
    return $command.Source
}

function Resolve-NodeExecutable {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'node.exe was not found. The BOM-free JSONL transport requires Node.js.'
    }
    return $command.Source
}

function Write-CodexUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-CodexNodeClient {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $node = Resolve-NodeExecutable
    $runner = Join-Path $PSScriptRoot 'codex-app-server-client.js'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "Codex App Server Node client was not found: $runner"
    }

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('onec-codex-client-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
    $configPath = Join-Path $tempDirectory 'config.json'
    $receiptPath = Join-Path $tempDirectory 'receipt.json'
    Write-CodexUtf8NoBom -Path $configPath -Text ($Config | ConvertTo-Json -Depth 30)

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $node
    $arguments = @($runner, '--config', $configPath, '--receipt', $receiptPath)
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CodexWindowsArgument -Value $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($startInfo.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
        $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Failed to start the Codex App Server Node client.'
        }
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(($TimeoutSeconds + 5) * 1000)) {
            try { $process.Kill() } catch { }
            throw "Codex App Server timeout after $TimeoutSeconds seconds."
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        if ($process.ExitCode -ne 0) {
            throw "Codex App Server client failed: $($stderrTask.Result.Trim())"
        }
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw 'Codex App Server client did not write a receipt.'
        }
        try {
            $receipt = [IO.File]::ReadAllText($receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch {
            throw 'Codex App Server client wrote an invalid receipt.'
        }
        $receipt | Add-Member -NotePropertyName process_id -NotePropertyValue $processId -Force
        return $receipt
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        $process.Dispose()
        if (Test-Path -LiteralPath $tempDirectory) {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force
        }
    }
}

function Invoke-CodexThreadCompaction {
    param(
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$Executable,
        [string[]]$PrefixArguments = @('app-server', '--listen', 'stdio://'),
        [int]$TimeoutSeconds = 300
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = Resolve-CodexExecutable
    }
    $config = [ordered]@{
        executable = $Executable
        prefixArguments = $PrefixArguments
        action = 'compact'
        threadId = $ThreadId
        timeoutMs = $TimeoutSeconds * 1000
    }
    return Invoke-CodexNodeClient -Config $config -TimeoutSeconds $TimeoutSeconds
}

function Invoke-CodexThreadUnarchive {
    param(
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$Executable,
        [string[]]$PrefixArguments = @(),
        [int]$TimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = Resolve-CodexExecutable
    }
    $arguments = @($PrefixArguments) + @('unarchive', $ThreadId)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CodexWindowsArgument -Value $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($startInfo.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
        $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Failed to start Codex thread maintenance.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "Codex unarchive timeout after $TimeoutSeconds seconds."
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        if ($process.ExitCode -ne 0) {
            throw "Codex unarchive failed: $($stderrTask.Result.Trim())"
        }
        return [pscustomobject][ordered]@{
            protocol_version = 1
            thread_id = $ThreadId
            status = 'unarchived'
            completed_at = [datetime]::UtcNow.ToString('o')
            process_id = $process.Id
        }
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        $process.Dispose()
    }
}

function Invoke-CodexThreadArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [string]$Executable,
        [string[]]$PrefixArguments = @(),
        [int]$TimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = Resolve-CodexExecutable
    }
    $arguments = @($PrefixArguments) + @('archive', $ThreadId)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-CodexWindowsArgument -Value $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($startInfo.PSObject.Properties.Name -contains 'StandardOutputEncoding') {
        $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Failed to start Codex thread maintenance.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "Codex archive timeout after $TimeoutSeconds seconds."
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        if ($process.ExitCode -ne 0) {
            throw "Codex archive failed: $($stderrTask.Result.Trim())"
        }
        return [pscustomobject][ordered]@{
            protocol_version = 1
            thread_id = $ThreadId
            status = 'archived'
            completed_at = [datetime]::UtcNow.ToString('o')
            process_id = $process.Id
        }
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
        }
        $process.Dispose()
    }
}

function Invoke-CodexThreadTurn {
    param(
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Executable,
        [string[]]$PrefixArguments = @('app-server', '--listen', 'stdio://'),
        [int]$TimeoutSeconds = 1200
    )

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = Resolve-CodexExecutable
    }
    $config = [ordered]@{
        executable = $Executable
        prefixArguments = $PrefixArguments
        action = 'turn'
        threadId = $ThreadId
        text = $Text
        timeoutMs = $TimeoutSeconds * 1000
    }
    return Invoke-CodexNodeClient -Config $config -TimeoutSeconds $TimeoutSeconds
}

Export-ModuleMember -Function @(
    'Resolve-CodexExecutable',
    'Invoke-CodexThreadUnarchive',
    'Invoke-CodexThreadArchive',
    'Invoke-CodexThreadCompaction',
    'Invoke-CodexThreadTurn'
)
