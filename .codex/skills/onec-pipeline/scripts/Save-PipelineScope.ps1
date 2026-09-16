[CmdletBinding(DefaultParameterSetName='Entries')]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(ParameterSetName='Entries',Mandatory=$true)][string[]]$Paths,
    [Parameter(ParameterSetName='Entries')][ValidateSet('add','modify','delete','restore')][string]$Operation='modify',
    [Parameter(ParameterSetName='Entries')][string[]]$RequirementIds,
    [Parameter(ParameterSetName='Entries')][string[]]$WorkItemIds,
    [Parameter(ParameterSetName='Entries')][string]$RequirementsHash,
    [Parameter(ParameterSetName='Entries')][string]$ComplexityHash,
    [Parameter(ParameterSetName='ScopeJson',Mandatory=$true)][string]$ScopeJson
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineGitScope.psm1') -Force

$entries = [ordered]@{}
if ($PSCmdlet.ParameterSetName -eq 'ScopeJson') {
    $inputValue = Get-Content -LiteralPath $ScopeJson -Raw | ConvertFrom-Json
    if ($null -eq $inputValue.paths) { throw 'scope paths are required' }
    foreach ($property in $inputValue.paths.PSObject.Properties) { $entries[$property.Name] = $property.Value }
    $RequirementsHash = [string]$inputValue.requirements_hash
    $ComplexityHash = [string]$inputValue.complexity_hash
}
else {
    foreach ($path in $Paths) {
        $canonical = $path.Replace('\','/')
        if ($entries.Contains($canonical)) { throw "duplicate scope path: $path" }
        $entries[$canonical] = [pscustomobject]@{ path=$canonical; kind='file'; operations=@($Operation); requirement_ids=@($RequirementIds); work_item_ids=@($WorkItemIds) }
    }
}

if ([string]::IsNullOrWhiteSpace($RequirementsHash) -or [string]::IsNullOrWhiteSpace($ComplexityHash)) { throw 'scope requires requirements_hash and complexity_hash' }
if ($entries.Count -eq 0) { throw 'scope must contain at least one exact path' }
foreach ($path in @($entries.Keys)) {
    Test-PipelineScopePaths -Paths @($path) -ProjectRoot $ProjectRoot | Out-Null
    $entry = $entries[$path]
    if ([string]$entry.path -cne $path -or $entry.kind -ne 'file') { throw "invalid exact scope entry: $path" }
    $operations = @($entry.operations)
    if ($operations.Count -eq 0 -or @($operations | Where-Object { $_ -notin @('add','modify','delete','restore') }).Count -gt 0) { throw "invalid operations for scope entry: $path" }
    if (@($entry.requirement_ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "requirement_ids are required for scope entry: $path" }
    if (@($entry.work_item_ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "work_item_ids are required for scope entry: $path" }
}

$directory = Join-Path $TaskDirectory 'scope-revisions'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$file = $null
$revisionId = $null
for ($number = 1; $number -le 9999; $number++) {
    $revisionId = 'SCOPE-{0:D4}' -f $number
    $candidate = Join-Path $directory "$revisionId.json"
    if (Test-Path -LiteralPath $candidate) { continue }
    $scope = [ordered]@{ protocol_version=2; revision_id=$revisionId; paths=$entries; requirements_hash=$RequirementsHash; complexity_hash=$ComplexityHash; created_at=[datetime]::UtcNow.ToString('o') }
    try { Write-PipelineImmutableJson -Path $candidate -Value $scope | Out-Null; $file=$candidate; break }
    catch { if (Test-Path -LiteralPath $candidate) { continue }; throw }
}
if ($null -eq $file) { throw 'scope revision space is exhausted' }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$pointer = [ordered]@{ protocol_version=2; type='scope'; revision_id=$revisionId; path=(Join-Path 'scope-revisions' "$revisionId.json").Replace('\','/'); sha256=$hash }
Write-PipelineAtomicJson -Path (Join-Path $TaskDirectory 'scope-current.json') -Value $pointer
$scope | ConvertTo-Json -Depth 20
