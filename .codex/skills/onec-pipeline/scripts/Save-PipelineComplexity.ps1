[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskDirectory,
    [Parameter(Mandatory=$true)][string]$FactorsJson,
    [string]$Reason='assessment'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force

$inputValue = Get-Content -LiteralPath $FactorsJson -Raw | ConvertFrom-Json
$factorNames = @('files','components','contracts_data','runtime_risk','coordination','uncertainty')
$factors = [ordered]@{}
$sum = 0
foreach ($name in $factorNames) {
    if ($inputValue.PSObject.Properties.Name -notcontains $name) { throw "Missing factor $name" }
    $factor = $inputValue.$name
    if ($null -eq $factor -or $factor.PSObject.Properties.Name -notcontains 'score') { throw "Factor $name requires score" }
    $scoreValue = 0
    if (-not [int]::TryParse([string]$factor.score,[ref]$scoreValue) -or $scoreValue -lt 0 -or $scoreValue -gt 3) { throw "Factor $name score must be 0..3" }
    $evidence = @($factor.evidence_refs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($evidence.Count -eq 0) { throw "Factor $name requires evidence_refs" }
    $factors[$name] = [ordered]@{ score=$scoreValue; evidence_refs=$evidence }
    $sum += $scoreValue
}

function Test-Flag([string]$Name) { return $inputValue.PSObject.Properties.Name -contains $Name -and [bool]$inputValue.$Name }
$floorReasons = @()
$floor = 'small'
foreach ($name in @('public_contract','metadata_data','rights_rls','transaction','background','integration','deploy','protected_tooling')) { if (Test-Flag $name) { $floorReasons += $name; $floor='medium' } }
foreach ($name in @('migration','security','irreversible','cross_source','shared_mutable','protocol_transition')) { if (Test-Flag $name) { $floorReasons += $name; $floor='large' } }
if (Test-Flag 'unbounded_irreversible_production') { $floorReasons += 'unbounded_irreversible_production'; $floor='critical' }

$scoreLevel = if($sum -ge 13){'critical'}elseif($sum -ge 8){'large'}elseif($sum -ge 3){'medium'}else{'small'}
$rank = @{small=0;medium=1;large=2;critical=3}
$effectiveLevel = if($rank[$scoreLevel] -ge $rank[$floor]){$scoreLevel}else{$floor}

$currentPointerPath = Join-Path $TaskDirectory 'complexity-current.json'
$statePath = Join-Path $TaskDirectory 'state.json'
if ((Test-Path -LiteralPath $currentPointerPath) -and (Test-Path -LiteralPath $statePath)) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $workStarted = [string]$state.status -notin @('plan','awaiting_user_decision','awaiting_plan_approval') -or @($state.transitions | Where-Object { $_.to -eq 'work' }).Count -gt 0
    if ($workStarted) {
        $pointer = Get-Content -LiteralPath $currentPointerPath -Raw | ConvertFrom-Json
        $currentPath = Join-Path $TaskDirectory ([string]$pointer.path)
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw 'Current complexity pointer is broken' }
        $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
        if ($rank[$effectiveLevel] -lt $rank[[string]$current.effective_level]) { throw 'Complexity downgrade after WORK is forbidden' }
    }
}

$directory = Join-Path $TaskDirectory 'complexity-revisions'
[IO.Directory]::CreateDirectory($directory) | Out-Null
$file = $null
$revisionId = $null
for ($number = 1; $number -le 9999; $number++) {
    $revisionId = 'CMP-{0:D4}' -f $number
    $candidate = Join-Path $directory "$revisionId.json"
    if (Test-Path -LiteralPath $candidate) { continue }
    $assessment = [ordered]@{ protocol_version=2; assessment_id=$revisionId; reason=$Reason; factors=$factors; raw_score=$sum; score_level=$scoreLevel; floor=$floor; floor_reasons=$floorReasons; effective_level=$effectiveLevel; created_at=[datetime]::UtcNow.ToString('o') }
    try { Write-PipelineImmutableJson -Path $candidate -Value $assessment | Out-Null; $file=$candidate; break }
    catch { if (Test-Path -LiteralPath $candidate) { continue }; throw }
}
if ($null -eq $file) { throw 'complexity revision space is exhausted' }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
$pointerValue = [ordered]@{ protocol_version=2; type='complexity'; revision_id=$revisionId; path=(Join-Path 'complexity-revisions' "$revisionId.json").Replace('\','/'); sha256=$hash }
Write-PipelineAtomicJson -Path $currentPointerPath -Value $pointerValue
$assessment | ConvertTo-Json -Depth 20
