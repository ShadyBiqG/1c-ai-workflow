Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineProtocolV2.psm1') -Force
function New-PipelineScopeBaseline { param([Parameter(Mandatory=$true)][string]$ProjectRoot,[Parameter(Mandatory=$true)][string[]]$Paths,[Parameter(Mandatory=$true)][string]$OutputDirectory)
    $root=[IO.Path]::GetFullPath($ProjectRoot); $items=[ordered]@{}
    foreach($path in $Paths){$c=Get-PipelineCanonicalPath $path $root; $items[$c]=Get-PipelineContentFingerprint (Join-Path $root $c)}
    $result=[pscustomobject][ordered]@{protocol_version=2;created_at=[datetime]::UtcNow.ToString('o');paths=$items}
    [IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null; $file=Join-Path $OutputDirectory 'scope-baseline.json'; Write-PipelineImmutableJson $file $result|Out-Null; return $result
}
function Test-PipelineScopePaths { param([Parameter(Mandatory=$true)][string[]]$Paths,[Parameter(Mandatory=$true)][string]$ProjectRoot)
    $root=[IO.Path]::GetFullPath($ProjectRoot); foreach($p in $Paths){$c=Get-PipelineCanonicalPath $p $root; if($c -cne $p.Replace('\','/')){throw "Scope path is not canonical: $p"}; $parts=$c -split '/'; $current=$root; if($parts.Count -gt 1){foreach($part in $parts[0..($parts.Count-2)]){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Scope crosses reparse point: $p"}}}};$target=Join-Path $root $c;if(Test-Path -LiteralPath $target){$targetItem=Get-Item -LiteralPath $target -Force;if($targetItem.PSIsContainer){throw "Scope target must be a file: $p"};if($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Scope target is a reparse point: $p"}}}
    return $true
}
function Test-PipelineRoutingManifest { param([Parameter(Mandatory=$true)]$Manifest)
    foreach($n in 'onec_scope','standard_scope','boundary_evidence'){if($Manifest.PSObject.Properties.Name -notcontains $n){throw "Routing manifest missing $n"}}
    $one=@($Manifest.onec_scope);$std=@($Manifest.standard_scope);$overlap=@($one|Where-Object{$_ -in $std});if($overlap.Count){throw "Routing scopes overlap: $($overlap -join ', ')"};[pscustomobject]@{passed=$true;onec_scope=$one;standard_scope=$std;boundary_evidence=@($Manifest.boundary_evidence)}
}
function Compare-PipelineScope { param([Parameter(Mandatory=$true)]$Scope,[Parameter(Mandatory=$true)]$Delta)
    $allowed=if($Scope.paths.PSObject.Properties.Name -contains 'Keys'){@($Scope.paths.Keys)}else{@($Scope.paths.PSObject.Properties|Where-Object{$_.MemberType -in @('NoteProperty','Property')}|ForEach-Object Name)}; $actual=if($Delta.paths.PSObject.Properties.Name -contains 'Keys'){@($Delta.paths.Keys)}else{@($Delta.paths.PSObject.Properties|Where-Object{$_.MemberType -in @('NoteProperty','Property')}|ForEach-Object Name)}; $unexpected=@($actual|Where-Object{$_ -notin $allowed});$invalid=@();foreach($p in $actual){$entry=if($Delta.paths.PSObject.Properties.Name -contains 'Keys'){$Delta.paths[$p]}else{$Delta.paths.$p};if($entry.operation -notin @('add','modify','delete','restore')){$invalid+=$p};$scopeEntry=if($Scope.paths.PSObject.Properties.Name -contains 'Keys'){$Scope.paths[$p]}else{$Scope.paths.$p};$allowedOps=if($scopeEntry -and $scopeEntry.PSObject.Properties.Name -contains 'operations'){@($scopeEntry.operations)}else{@('modify')};if($p -in $allowed -and $entry.operation -notin $allowedOps){$invalid+=$p}}; [pscustomobject][ordered]@{passed=($unexpected.Count -eq 0 -and $invalid.Count -eq 0);unexpected_paths=$unexpected;invalid_operations=@($invalid|Sort-Object -Unique)}
}
Export-ModuleMember -Function New-PipelineScopeBaseline,Test-PipelineScopePaths,Test-PipelineRoutingManifest,Compare-PipelineScope
