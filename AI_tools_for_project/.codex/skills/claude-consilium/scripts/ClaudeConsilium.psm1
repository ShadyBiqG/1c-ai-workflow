Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-WindowsCommandLineArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-ClaudeCodePath {
    param([string]$AppDataRoot = $env:APPDATA)

    $candidates = New-Object Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($AppDataRoot)) {
        $versionRoot = Join-Path $AppDataRoot 'Claude\claude-code'
        if (Test-Path -LiteralPath $versionRoot -PathType Container) {
            foreach ($directory in Get-ChildItem -LiteralPath $versionRoot -Directory -ErrorAction SilentlyContinue) {
                $version = $null
                if ([version]::TryParse($directory.Name, [ref]$version)) {
                    $path = Join-Path $directory.FullName 'claude.exe'
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        $candidates.Add([pscustomobject]@{ Version = $version; Path = $path })
                    }
                }
            }
        }
    }

    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object Version -Descending | Select-Object -First 1).Path
    }

    $fallbacks = @()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $fallbacks += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $fallbacks += (Join-Path $env:LOCALAPPDATA 'Programs\Claude\claude.exe')
    }

    foreach ($path in $fallbacks) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    $command = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw 'Claude Code executable was not found. A replacement installation or session must not be created automatically.'
}

function Assert-ClaudeProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Effort
    )

    $models = @('opus', 'sonnet', 'haiku')
    $efforts = @('low', 'medium', 'high', 'max')
    if ($models -notcontains $Model) {
        throw "Unsupported Claude model: $Model"
    }
    if ($efforts -notcontains $Effort) {
        throw "Unsupported Claude effort: $Effort"
    }
}

function Invoke-RedirectedUtf8Process {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputText,
        [int]$TimeoutSeconds = 600
    )

    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) {
        throw 'node.exe was not found. The BOM-free Claude stdin transport requires Node.js.'
    }
    $runner = Join-Path $PSScriptRoot 'stdin-process-client.js'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw "Claude stdin Node client was not found: $runner"
    }

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('claude-stdin-client-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
    $configPath = Join-Path $tempDirectory 'config.json'
    $resultPath = Join-Path $tempDirectory 'result.json'
    $config = [ordered]@{
        executable = $FilePath
        arguments = $ArgumentList
        input = $InputText
        timeoutMs = $TimeoutSeconds * 1000
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nodeCommand.Source
    $runnerArguments = @($runner, '--config', $configPath, '--result', $resultPath)
    $startInfo.Arguments = (($runnerArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value $_ }) -join ' ')
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
            throw "Failed to start process: $FilePath"
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(($TimeoutSeconds + 5) * 1000)) {
            try { $process.Kill() } catch { }
            throw "Process timeout after $TimeoutSeconds seconds: $FilePath"
        }

        $stdoutTask.Wait()
        $stderrTask.Wait()
        if ($process.ExitCode -ne 0) {
            throw "Claude stdin client failed: $($stderrTask.Result.Trim())"
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw 'Claude stdin client did not write a result.'
        }
        try {
            $childResult = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch {
            throw 'Claude stdin client wrote invalid JSON.'
        }
        if ($childResult.timed_out) {
            throw "Process timeout after $TimeoutSeconds seconds: $FilePath"
        }
        return [pscustomobject]@{
            ExitCode = [int]$childResult.exit_code
            StdOut = [string]$childResult.stdout
            StdErr = [string]$childResult.stderr
        }
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

function ConvertFrom-ClaudeJsonLines {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $events = New-Object Collections.Generic.List[object]
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $events.Add(($line | ConvertFrom-Json))
        }
        catch {
            throw "Invalid Claude JSON event: $line"
        }
    }
    return ,$events.ToArray()
}

function Get-ClaudeSessionIdFromEvents {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events)

    foreach ($event in $Events) {
        if ($event.PSObject.Properties.Name -contains 'session_id' -and -not [string]::IsNullOrWhiteSpace($event.session_id)) {
            return [string]$event.session_id
        }
    }
    throw 'Claude session ID is missing from JSON events.'
}

function Test-ClaudeCompactBoundary {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [switch]$ThrowOnMissing
    )

    foreach ($event in $Events) {
        if ($event.PSObject.Properties.Name -contains 'subtype' -and $event.subtype -eq 'compact_boundary') {
            return $true
        }
    }
    if ($ThrowOnMissing) {
        throw 'Claude compact_boundary event was not received.'
    }
    return $false
}

function Get-ClaudeCompactionOutcome {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events)

    if (Test-ClaudeCompactBoundary -Events $Events) {
        return 'compacted'
    }

    $sawCompacting = $false
    foreach ($event in $Events) {
        if ($event.PSObject.Properties.Name -contains 'status' -and $event.status -eq 'compacting') {
            $sawCompacting = $true
        }
        if ($event.PSObject.Properties.Name -contains 'compact_result' -and $event.compact_result -eq 'failed') {
            $errorText = if ($event.PSObject.Properties.Name -contains 'compact_error') { [string]$event.compact_error } else { 'Unknown compact failure' }
            if ($sawCompacting -and $errorText -eq 'Not enough messages to compact.') {
                return 'not_needed'
            }
            throw "Claude compaction failed: $errorText"
        }
    }

    throw 'Claude compaction completion event was not received.'
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-ClaudeSessionRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Effort
    )

    Assert-ClaudeProfile -Model $Model -Effort $Effort
    $value = [ordered]@{
        protocol_version = 1
        session_id = $SessionId
        model = $Model
        effort = $Effort
        updated_at = [datetime]::UtcNow.ToString('o')
    }
    $json = $value | ConvertTo-Json -Depth 6
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    Write-Utf8NoBom -Path $tempPath -Text $json
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($tempPath, $Path, $null)
    }
    else {
        [IO.File]::Move($tempPath, $Path)
    }
}

function Read-ClaudeSessionRegistry {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Claude session registry was not found: $Path"
    }
    try {
        $registry = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw "Invalid Claude session registry: $Path"
    }
    if ([string]::IsNullOrWhiteSpace($registry.session_id)) {
        throw "Claude session ID is missing from registry: $Path"
    }
    Assert-ClaudeProfile -Model $registry.model -Effort $registry.effort
    return $registry
}

function Get-ClaudeCompactPrompt {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $memoryPath = Join-Path $ProjectRoot 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $memoryPath -PathType Leaf)) {
        throw "CLAUDE.md was not found: $memoryPath"
    }
    return '/compact Preserve the pipeline role, UT configuration identity, cross-task decisions, known constraints, accepted/rejected rationale, and reusable lessons. Drop completed-task details, raw diffs, raw logs, duplicate file contents, and transient tool output.'
}

Export-ModuleMember -Function @(
    'Resolve-ClaudeCodePath',
    'Assert-ClaudeProfile',
    'Invoke-RedirectedUtf8Process',
    'ConvertFrom-ClaudeJsonLines',
    'Get-ClaudeSessionIdFromEvents',
    'Test-ClaudeCompactBoundary',
    'Get-ClaudeCompactionOutcome',
    'Write-Utf8NoBom',
    'Write-ClaudeSessionRegistry',
    'Read-ClaudeSessionRegistry',
    'Get-ClaudeCompactPrompt'
)
