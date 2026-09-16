[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [Parameter(Mandatory=$true)][string]$RequirementsJson
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

$value = Get-Content -LiteralPath $RequirementsJson -Raw | ConvertFrom-Json
$items = @($value.requirements)
if ($items.Count -eq 0) { throw 'requirements must not be empty' }
$ids = @{}
foreach ($requirement in $items) {
    $id = [string]$requirement.id
    if ($id -notmatch '^(REQ|NEG)-[A-Za-z0-9-]+$') { throw "requirement id must be stable REQ-/NEG-: $id" }
    if ($ids.ContainsKey($id)) { throw "duplicate requirement id: $id" }
    $ids[$id] = $true
    if (@($requirement.source_refs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { throw "requirement $id needs source_refs" }
    if ($requirement.status -notin @('active','accepted','rejected','open')) { throw "invalid requirement status: $id" }
}

$directory = Join-Path $TaskDirectory 'requirements-revisions'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$file = $null
$revisionId = $null
for ($number = 1; $number -le 9999; $number++) {
    $revisionId = 'REQREV-{0:D4}' -f $number
    $candidate = Join-Path $directory "$revisionId.json"
    if (Test-Path -LiteralPath $candidate) { continue }
    try { Write-PipelineImmutableJson -Path $candidate -Value $value | Out-Null; $file = $candidate; break }
    catch { if (Test-Path -LiteralPath $candidate) { continue }; throw }
}
if ($null -eq $file) { throw 'requirements revision space is exhausted' }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$pointer = [ordered]@{ protocol_version=2; type='requirements'; revision_id=$revisionId; path=(Join-Path 'requirements-revisions' "$revisionId.json").Replace('\','/'); sha256=$hash }
Write-PipelineAtomicJson -Path (Join-Path $TaskDirectory 'requirements-current.json') -Value $pointer
$value | ConvertTo-Json -Depth 30
