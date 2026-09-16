[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [string]$RequestText,
    [switch]$Explicit,
    [switch]$SelfMaintenance,
    [string[]]$OnecScope,
    [string[]]$StandardScope,
    [object[]]$BoundaryEvidence
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($ProjectRoot)
$excluded='[\\/](?:\.git|\.pipeline|\.codex|node_modules|vendor|packages)[\\/]'

$bsl=@(Get-ChildItem -LiteralPath $root -Filter *.bsl -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notmatch $excluded})
$xml=@(Get-ChildItem -LiteralPath $root -Filter *.xml -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notmatch $excluded} | ForEach-Object {
    try {
        $document=[xml](Get-Content -LiteralPath $_.FullName -Raw)
        $namespace=[string]$document.DocumentElement.NamespaceURI
        if($namespace -match '^http://v8\.1c\.ru/(?:8\.|edi/|xmi/)'){$_}
    }
    catch {}
})
$hasV8Project=Test-Path -LiteralPath (Join-Path $root 'v8project.yaml') -PathType Leaf
$confirmed=(($xml.Count -gt 0 -and $bsl.Count -gt 0) -or ($hasV8Project -and $bsl.Count -gt 0))
$classification=if($Explicit){'explicit_user_request'}elseif($SelfMaintenance){'workflow_self_maintenance'}elseif($confirmed){'confirmed_1c_evidence'}else{'not_applicable'}

$onec=@($OnecScope | Where-Object {$_} | ForEach-Object {($_ -replace '\','/').TrimStart('/')} | Sort-Object -Unique)
$standard=@($StandardScope | Where-Object {$_} | ForEach-Object {($_ -replace '\','/').TrimStart('/')} | Sort-Object -Unique)
$overlap=@($onec | Where-Object {$_ -in $standard})
if($overlap.Count -gt 0){throw "routing scope overlap: $($overlap -join ', ')"}

[pscustomobject][ordered]@{
    protocol_version=2
    applicable=($confirmed -or $Explicit -or $SelfMaintenance)
    classification=$classification
    markers=@($(if($xml.Count -gt 0){'official 1C namespace XML'}),$(if($hasV8Project -and $bsl.Count -gt 0){'v8project + BSL'})) | Where-Object {$_}
    onec_evidence=@($xml | ForEach-Object {$_.FullName.Substring($root.Length).TrimStart('\','/').Replace('\','/')})
    routing_manifest=[ordered]@{protocol_version=2;onec_scope=$onec;standard_scope=$standard;boundary_evidence=@($BoundaryEvidence);overlap=$overlap}
}|ConvertTo-Json -Depth 12
