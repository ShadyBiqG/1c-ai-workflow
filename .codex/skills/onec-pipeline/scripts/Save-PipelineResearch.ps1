[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [Parameter(Mandatory=$true)][string]$ResearchJson
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

$value = Get-Content -LiteralPath $ResearchJson -Raw | ConvertFrom-Json
$requiredFlags = @('project_rules_read','names_and_interfaces_verified','scope_bounded','risk_floors_justified','verification_targets_justified','alternatives_examined','material_questions_closed')
if ($null -eq $value.sufficiency -or $value.sufficiency.status -ne 'sufficient') { throw 'research sufficiency must be sufficient' }
foreach ($flag in $requiredFlags) {
    if ($value.sufficiency.PSObject.Properties.Name -notcontains $flag -or -not [bool]$value.sufficiency.$flag) { throw "research sufficiency flag missing: $flag" }
}
if (@($value.material_open_question_ids).Count -gt 0) { throw 'material research questions remain open' }
if (@($value.sources).Count -eq 0) { throw 'research requires sources' }

foreach ($collectionName in @('questions','sources','findings')) {
    $seen = @{}
    foreach ($entry in @($value.$collectionName)) {
        $id = [string]$entry.id
        if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { throw "research $collectionName ids must be non-empty and unique" }
        $seen[$id] = $true
    }
}
$sourceIds = @($value.sources | ForEach-Object { [string]$_.id })
foreach ($finding in @($value.findings)) {
    foreach ($sourceId in @($finding.source_ids)) { if ($sourceId -notin $sourceIds) { throw "finding $($finding.id) references unknown source $sourceId" } }
}

$directory = Join-Path $TaskDirectory 'research-revisions'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$file = $null
$revisionId = $null
for ($number = 1; $number -le 9999; $number++) {
    $revisionId = 'RESREV-{0:D4}' -f $number
    $candidate = Join-Path $directory "$revisionId.json"
    if (Test-Path -LiteralPath $candidate) { continue }
    try { Write-PipelineImmutableJson -Path $candidate -Value $value | Out-Null; $file = $candidate; break }
    catch { if (Test-Path -LiteralPath $candidate) { continue }; throw }
}
if ($null -eq $file) { throw 'research revision space is exhausted' }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$pointer = [ordered]@{ protocol_version=2; type='research'; revision_id=$revisionId; path=(Join-Path 'research-revisions' "$revisionId.json").Replace('\','/'); sha256=$hash }
Write-PipelineAtomicJson -Path (Join-Path $TaskDirectory 'research-current.json') -Value $pointer
[pscustomobject]@{ path=$pointer.path; revision=$revisionId; sha256=$hash } | ConvertTo-Json
