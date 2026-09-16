[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [Parameter(Mandatory=$true)][string]$InvariantsJson
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

$inputValue = Get-Content -LiteralPath $InvariantsJson -Raw | ConvertFrom-Json
$items = @($inputValue.invariants)
if ($items.Count -eq 0) { throw 'invariants must not be empty' }
$ids = @{}
foreach ($invariant in $items) {
    $id = [string]$invariant.id
    if ($id -notmatch '^NEG-[A-Za-z0-9-]+$' -or $ids.ContainsKey($id)) { throw "invariant ids must be unique NEG-*: $id" }
    $ids[$id] = $true
    if ($invariant.type -notin @('forbidden_path','forbidden_symbol','must_remain_deleted')) { throw "invalid invariant type: $id" }
    if ($null -eq $invariant.selector -or $invariant.selector -is [string]) { throw "selector must be a structured object: $id" }
    $selectorNames = @($invariant.selector.PSObject.Properties.Name)
    if ($invariant.type -eq 'forbidden_path' -and ('path' -notin $selectorNames -or [string]::IsNullOrWhiteSpace([string]$invariant.selector.path))) { throw "forbidden_path requires selector.path: $id" }
    if ($invariant.type -eq 'forbidden_symbol' -and (('path' -notin $selectorNames) -or ('symbol' -notin $selectorNames))) { throw "forbidden_symbol requires selector.path and selector.symbol: $id" }
    if ($invariant.type -eq 'must_remain_deleted' -and ('tombstone_id' -notin $selectorNames) -and ('path' -notin $selectorNames)) { throw "must_remain_deleted requires selector.tombstone_id or selector.path: $id" }
    if (@($invariant.requirement_ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "requirement_ids are required: $id" }
    if (@($invariant.check_ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "check_ids are required: $id" }
}

$directory = Join-Path $TaskDirectory 'negative-invariant-revisions'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$file = $null
$revisionId = $null
for ($number = 1; $number -le 9999; $number++) {
    $revisionId = 'NEGSET-{0:D4}' -f $number
    $candidate = Join-Path $directory "$revisionId.json"
    if (Test-Path -LiteralPath $candidate) { continue }
    $document = [ordered]@{ protocol_version=2; revision_id=$revisionId; invariants=$items; created_at=[datetime]::UtcNow.ToString('o') }
    try { Write-PipelineImmutableJson -Path $candidate -Value $document | Out-Null; $file=$candidate; break }
    catch { if (Test-Path -LiteralPath $candidate) { continue }; throw }
}
if ($null -eq $file) { throw 'negative invariant revision space is exhausted' }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$pointer = [ordered]@{ protocol_version=2; type='negative_invariants'; revision_id=$revisionId; path=(Join-Path 'negative-invariant-revisions' "$revisionId.json").Replace('\','/'); sha256=$hash }
Write-PipelineAtomicJson -Path (Join-Path $TaskDirectory 'negative-invariants-current.json') -Value $pointer
$document | ConvertTo-Json -Depth 20
