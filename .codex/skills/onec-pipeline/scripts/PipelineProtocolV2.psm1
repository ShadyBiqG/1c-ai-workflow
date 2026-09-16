Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PipelineCanonicalPath {
    param([Parameter(Mandatory=$true)][string]$Path,[string]$ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = (Get-Location).Path }
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
    $rootUri = New-Object Uri(($root.TrimEnd('\') + '\'))
    $relative = [Uri]::UnescapeDataString($rootUri.MakeRelativeUri((New-Object Uri($candidate))).ToString()).Replace('\','/')
    if ($relative -eq '..' -or $relative.StartsWith('../')) { throw "Path escapes project root: $Path" }
    if ($relative.Contains('*') -or $relative.Contains('?')) { throw "Wildcards are not allowed in exact scope paths: $Path" }
    return $relative
}

function Get-PipelineSha256Bytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PipelineContentFingerprint {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ exists=$false; kind='missing'; sha256=$null; length=0 } }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [pscustomobject]@{ exists=$true; kind='file'; sha256=(Get-PipelineSha256Bytes $bytes); length=$bytes.Length }
}
function Invoke-PipelineGitRaw { param([Parameter(Mandatory=$true)][string]$ProjectRoot,[Parameter(Mandatory=$true)][string]$Arguments)
    $psi=New-Object Diagnostics.ProcessStartInfo; $psi.FileName='git';$psi.Arguments='-C "'+$ProjectRoot.Replace('"','\"')+'" '+$Arguments;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$out=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit();if($p.ExitCode -ne 0){throw "git failed: $err"};return $out
}
function Get-PipelineNulRecords { param([AllowEmptyString()][string]$Text) return @($Text -split "`0" | Where-Object { $_ -ne '' }) }
function Get-PipelineGitInventory { param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $h=@{};$i=@{};$root=[IO.Path]::GetFullPath($ProjectRoot)
    foreach($r in Get-PipelineNulRecords (Invoke-PipelineGitRaw $root 'ls-tree -r -z HEAD --full-tree')){$parts=$r -split "`t",2;$meta=$parts[0]-split ' ';$path=Get-PipelineCanonicalPath $parts[1] $root;$h[$path]=[pscustomobject]@{exists=$true;mode=$meta[0];type=$meta[1];blob_oid=$meta[2]}}
    foreach($r in Get-PipelineNulRecords (Invoke-PipelineGitRaw $root 'ls-files -s -z')){$parts=$r -split "`t",2;$meta=$parts[0]-split ' ';$path=Get-PipelineCanonicalPath $parts[1] $root;$i[$path]=[pscustomobject]@{exists=$true;mode=$meta[0];stage=[int]$meta[2];blob_oid=$meta[1];conflict=([int]$meta[2] -ne 0)}}
    $untracked=@(Get-PipelineNulRecords (Invoke-PipelineGitRaw $root 'ls-files --others --exclude-standard -z'));$all=@($h.Keys+$i.Keys+$untracked|Sort-Object -Unique);$records=[ordered]@{};$canonical=New-Object Text.StringBuilder
    foreach($path in $all){$w=Get-PipelineContentFingerprint (Join-Path $root $path);if($w.exists -and $path -match '(?i)\.(bsl|xml|txt|md)$'){$w|Add-Member NoteProperty text ([IO.File]::ReadAllText((Join-Path $root $path)))};$hv=if($h.ContainsKey($path)){$h[$path]}else{[pscustomobject]@{exists=$false}};$iv=if($i.ContainsKey($path)){$i[$path]}else{[pscustomobject]@{exists=$false;conflict=$false;mode=$null;stage=$null;blob_oid=$null}};$records[$path]=[pscustomobject]@{path=$path;head=$hv;index=$iv;worktree=$w};[void]$canonical.Append("$path|$($iv.mode)|$($iv.stage)|$($iv.blob_oid)`n")}
    [pscustomobject]@{records=$records;index_hash=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($canonical.ToString())))}
}

function Write-PipelineImmutableText {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path; if ($dir) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    try { $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()} }
    catch [IO.IOException] { throw "Immutable artifact already exists: $Path" }
    return $Path
}

function Write-PipelineImmutableJson {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)]$Value)
    return Write-PipelineImmutableText -Path $Path -Text ($Value | ConvertTo-Json -Depth 60)
}

function Write-PipelineAtomicJson {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Value
    )
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $backupPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 60), $encoding)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function Test-PipelineAppendOnlyArtifact {
    param([Parameter(Mandatory=$true)][string]$Path,[string]$ExpectedSha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($ExpectedSha256) { return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedSha256.ToLowerInvariant()) }
    return $true
}

function New-PipelineBaselineRecord {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    $root = [IO.Path]::GetFullPath($ProjectRoot); $inventory=Get-PipelineGitInventory $root
    $head = [string](git -C $root rev-parse HEAD 2>$null); if ($LASTEXITCODE -ne 0) { $head = $null }
    return [pscustomobject][ordered]@{ protocol_version=2; created_at=[datetime]::UtcNow.ToString('o'); head_oid=$head; canonical_index_hash=$inventory.index_hash; paths=$inventory.records; path_count=$inventory.records.Count }
}

function Get-PipelineTaskDelta {
    param([Parameter(Mandatory=$true)]$Baseline,[Parameter(Mandatory=$true)][string]$ProjectRoot,[string[]]$ScopePaths,[object]$Tombstones)
    $root = [IO.Path]::GetFullPath($ProjectRoot); $paths = [ordered]@{}; $baselineNames=@($Baseline.paths.Keys);$currentInventory=Get-PipelineGitInventory $root;$currentNames=@($currentInventory.records.Keys);$tombstoneNames=@();if($Tombstones){$tc=if($Tombstones.PSObject.Properties.Name -contains 'tombstones'){$Tombstones.tombstones}else{$Tombstones};$tombstoneNames=@($tc.Keys)};$candidates=@($baselineNames+$currentNames+$tombstoneNames|Sort-Object -Unique)
    if ($ScopePaths) { $candidates = @($candidates | Where-Object { $_ -in @($ScopePaths) }) }
    foreach ($path in @($candidates | Sort-Object -Unique)) {
        $before = $null; if ($path -in $baselineNames) { $entry = $Baseline.paths[$path]; $before = $entry.worktree }
        $after = if(($currentInventory.records.PSObject.Properties.Name -contains 'Keys') -and $currentInventory.records.Contains($path)){$currentInventory.records[$path].worktree}else{Get-PipelineContentFingerprint -Path (Join-Path $root $path)}
        $beforeExists=if($null -eq $before){$false}else{[bool]$before.exists};$afterExists=[bool]$after.exists;$beforeSha=if($before){[string]$before.sha256}else{''};$afterSha=[string]$after.sha256
        $changed = (($beforeExists -ne $afterExists) -or ($beforeSha -ne $afterSha))
        if ($changed) { $operation = if ($null -eq $before) {'add'} elseif (-not $after.exists) {'delete'} else {'modify'}; if($Tombstones -and $after.exists){$tc=if($Tombstones.PSObject.Properties.Name -contains 'tombstones'){$Tombstones.tombstones}else{$Tombstones};$tn=if($tc.PSObject.Properties.Name -contains 'Keys'){@($tc.Keys)}else{@($tc.PSObject.Properties|Where-Object{$_.MemberType -in @('NoteProperty','Property')}|ForEach-Object Name)};if($path -in $tn){$tv=if($tc.PSObject.Properties.Name -contains 'Keys'){$tc[$path]}else{$tc.$path};$currentText=if($after.PSObject.Properties.Name -contains 'text'){$after.text}else{[IO.File]::ReadAllText((Join-Path $root $path))};if(Test-PipelineSemanticMatch -TombstoneFragments @($tv.fragments) -CurrentText $currentText -Path $path){$operation='restore'}}}; $paths[$path]=[pscustomobject][ordered]@{path=$path;operation=$operation;before=$before;after=$after} }
    }
    return [pscustomobject][ordered]@{ protocol_version=2; generated_at=[datetime]::UtcNow.ToString('o'); paths=$paths; changed_count=$paths.Count }
}
function Get-PipelineSemanticFragmentsStrict { param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$Path,[string]$Source='current')
    $out=@();if($null -eq $Text){return $out};if($Path -match '(?i)\.bsl$'){foreach($m in [regex]::Matches($Text,'(?ms)(Процедура|Функция)\s+([\wА-Яа-я_]+)\s*(?:\(([^)]*)\))?.*?Конец(?:Процедуры|Функции)')){$kind=if($m.Groups[1].Value -match '(?i)процедура'){'procedure'}else{'function'};$out+=[pscustomobject]@{kind='bsl_identity';bsl_kind=$kind;name=$m.Groups[2].Value;arity=if($m.Groups[3].Success){@($m.Groups[3].Value -split ','|Where-Object{$_.Trim()}).Count}else{0};source=$Source;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($m.Value)));text=$m.Value}}}elseif($Path -match '(?i)\.xml$'){try{$x=[xml]$Text;foreach($n in $x.SelectNodes('//*')){$ns=[string]$n.NamespaceURI;if($ns -notmatch '^http://v8\.1c\.ru/'){continue};$attr=$n.Attributes['uuid'];if(-not $attr){$attr=$n.Attributes['UUID']};if(-not $attr){$attr=$n.Attributes['Name']};if(-not $attr){$attr=$n.Attributes['name']};if($attr){$out+=[pscustomobject]@{kind='xml_identity';source=$Source;namespace=$ns;local_name=$n.LocalName;identity=$attr.Value;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($n.OuterXml)));text=$n.OuterXml}}}}catch{}}else{foreach($line in ($Text -split "`r?`n")){if($line.Trim()){$out+=[pscustomobject]@{kind='text_fragment';source=$Source;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($line.Trim())));text=$line.Trim()}}}};return $out
}
function Test-PipelineSemanticMatch { param([Parameter(Mandatory=$true)]$TombstoneFragments,[AllowEmptyString()][string]$CurrentText,[Parameter(Mandatory=$true)][string]$Path)
    $current=@(Get-PipelineSemanticFragmentsStrict $CurrentText $Path 'current');foreach($t in @($TombstoneFragments)){foreach($c in $current){if($t.kind -eq 'bsl_identity' -and $c.kind -eq 'bsl_identity' -and $t.bsl_kind -ieq $c.bsl_kind -and $t.name -ieq $c.name -and [int]$t.arity -eq [int]$c.arity){return $true};if($t.kind -eq 'xml_identity' -and $c.kind -eq 'xml_identity' -and $t.namespace -ceq $c.namespace -and $t.local_name -ceq $c.local_name -and $t.identity -ceq $c.identity){return $true};if($t.kind -eq 'text_fragment' -and $c.kind -eq 'text_fragment' -and $t.sha256 -ceq $c.sha256){return $true}}};return $false
}
function Get-PipelineSemanticKey { param([Parameter(Mandatory=$true)]$Fragment)
    if($Fragment.kind -eq 'bsl_identity'){return ('bsl|{0}|{1}|{2}' -f ([string]$Fragment.bsl_kind).ToLowerInvariant(),([string]$Fragment.name).ToLowerInvariant(),[int]$Fragment.arity)}
    if($Fragment.kind -eq 'xml_identity'){return ('xml|{0}|{1}|{2}' -f $Fragment.namespace,$Fragment.local_name,$Fragment.identity)}
    return ('text|{0}' -f $Fragment.sha256)
}
function Get-PipelineSemanticFragmentsDeprecated { param([AllowEmptyString()][string]$Text,[Parameter(Mandatory=$true)][string]$Path,[string]$Source='current')
    $out=@();if($null -eq $Text){return $out};if($Path -match '(?i)\.bsl$'){foreach($m in [regex]::Matches($Text,'(?ms)(?:Процедура|Функция)\s+([\wА-Яа-я_]+).*?Конец(?:Процедуры|Функции)')){$out+=[pscustomobject]@{kind='bsl_identity';source=$Source;identity=$m.Groups[1].Value;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($m.Value)));text=$m.Value}}}elseif($Path -match '(?i)\.xml$'){try{$x=[xml]$Text;if($x.DocumentElement.NamespaceURI -notmatch '^http://v8\.1c\.ru/'){return $out};foreach($n in $x.SelectNodes('//*[@uuid or @UUID or @name or @Name]')){$id=if($n.Attributes['uuid']){$n.Attributes['uuid'].Value}elseif($n.Attributes['UUID']){$n.Attributes['UUID'].Value}elseif($n.Attributes['Name']){$n.Attributes['Name'].Value}else{$n.Attributes['name'].Value};$out+=[pscustomobject]@{kind='xml_identity';source=$Source;identity=$id;namespace=$n.NamespaceURI;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($n.OuterXml)));text=$n.OuterXml}}}catch{}}else{foreach($line in ($Text -split "`r?`n")){if($line.Trim()){$out+=[pscustomobject]@{kind='text_fragment';source=$Source;sha256=(Get-PipelineSha256Bytes ([Text.Encoding]::UTF8.GetBytes($line.Trim())));text=$line.Trim()}}}};return $out
}

function New-PipelineTombstoneInventory {
    param([Parameter(Mandatory=$true)]$Baseline,[string]$ProjectRoot)
    $deleted=[ordered]@{}
    function Read-BlobText($oid,$path){if(-not $oid){return $null};try{[string](Invoke-PipelineGitRaw $ProjectRoot ("show "+$oid))}catch{return $null}}
    function Extract-Fragments($text,$path,$source){return @(Get-PipelineSemanticFragmentsStrict $text $path $source)}
    $names = if($Baseline.paths -is [Collections.IDictionary]) {@($Baseline.paths.Keys)} else {@($Baseline.paths.PSObject.Properties | Where-Object {$_.MemberType -in @('NoteProperty','Property')} | ForEach-Object Name)}
    foreach($name in $names) {
        $value = if($Baseline.paths -is [Collections.IDictionary]) {$Baseline.paths[$name]} else {$Baseline.paths.$name}
        $worktree = if($value.PSObject.Properties.Name -contains 'worktree'){$value.worktree}else{$value}
        $head = if($value.PSObject.Properties.Name -contains 'head'){$value.head}else{$null}; $index = if($value.PSObject.Properties.Name -contains 'index'){$value.index}else{$null}
        $headExists = $null -ne $head -and $head.PSObject.Properties.Name -contains 'exists' -and [bool]$head.exists
        $indexExists = $null -ne $index -and $index.PSObject.Properties.Name -contains 'exists' -and [bool]$index.exists
        $headOid = if($headExists -and $head.PSObject.Properties.Name -contains 'blob_oid'){[string]$head.blob_oid}else{$null}
        $indexOid = if($indexExists -and $index.PSObject.Properties.Name -contains 'blob_oid'){[string]$index.blob_oid}else{$null}
        $deletedFragments=@()
        $htext=if($ProjectRoot -and $headExists){Read-BlobText $headOid $name}else{$null};$itext=if($ProjectRoot -and $indexExists){Read-BlobText $indexOid $name}else{$null};$hfrag=Extract-Fragments $htext $name 'H';$ifrag=Extract-Fragments $itext $name 'I';$ifKeys=@($ifrag|ForEach-Object{Get-PipelineSemanticKey $_});foreach($hf in $hfrag){if((Get-PipelineSemanticKey $hf) -notin $ifKeys){$hf.source='H_to_I';$deletedFragments+=$hf}}
        $wtext=if($worktree.PSObject.Properties.Name -contains 'text'){$worktree.text}else{$null};if($itext -and $wtext -and $itext -ne $wtext){foreach($if in (Extract-Fragments $itext $name 'I_to_W0')){$wfr=@(Extract-Fragments $wtext $name 'W0');$wkeys=@($wfr|ForEach-Object{Get-PipelineSemanticKey $_});if((Get-PipelineSemanticKey $if) -notin $wkeys){$deletedFragments+=$if}}}
        if(($headExists -and (-not $indexExists)) -or (-not [bool]$worktree.exists) -or $deletedFragments.Count -gt 0) {
            $deleted[$name]=[pscustomobject][ordered]@{path=$name;source_transition=@($deletedFragments|ForEach-Object source|Sort-Object -Unique);sha256=$worktree.sha256;kind=$worktree.kind;fragments=$deletedFragments}
        }
    }
    return [pscustomobject][ordered]@{protocol_version=2;created_at=[datetime]::UtcNow.ToString('o');tombstones=$deleted}
}

function Test-PipelineLegacyRestoration {
    param([Parameter(Mandatory=$true)]$Tombstones,[Parameter(Mandatory=$true)]$Delta,[string]$ProjectRoot,[string[]]$AllowedRestorePaths)
    $findings=@(); $container=if($Tombstones.PSObject.Properties.Name -contains 'tombstones'){$Tombstones.tombstones}else{$Tombstones}; $names=if($container -is [Collections.IDictionary]){@($container.Keys)}else{@($container.PSObject.Properties | Where-Object {$_.MemberType -in @('NoteProperty','Property')} | ForEach-Object Name)}; $deltaNames=if($Delta.paths -is [Collections.IDictionary]){@($Delta.paths.Keys)}else{@($Delta.paths.PSObject.Properties | Where-Object {$_.MemberType -in @('NoteProperty','Property')} | ForEach-Object Name)}
    foreach($p in $names){ if($p -in $deltaNames -and $p -notin @($AllowedRestorePaths)){ $d=if($Delta.paths -is [Collections.IDictionary]){$Delta.paths[$p]}else{$Delta.paths.$p}; $t=if($container -is [Collections.IDictionary]){$container[$p]}else{$container.$p}; $file=Join-Path $ProjectRoot $p;if(-not (Test-Path -LiteralPath $file -PathType Leaf)){continue};$text=[IO.File]::ReadAllText($file);if(Test-PipelineSemanticMatch -TombstoneFragments @($t.fragments) -CurrentText $text -Path $p){$findings += [pscustomobject]@{path=$p;reason='legacy_restoration_detected'}} } }
    return [pscustomobject][ordered]@{ passed=($findings.Count -eq 0); findings=$findings }
}

Export-ModuleMember -Function Get-PipelineCanonicalPath,Get-PipelineSha256Bytes,Get-PipelineContentFingerprint,Invoke-PipelineGitRaw,Get-PipelineNulRecords,Get-PipelineGitInventory,Get-PipelineSemanticFragmentsStrict,Get-PipelineSemanticKey,Test-PipelineSemanticMatch,Write-PipelineImmutableText,Write-PipelineImmutableJson,Write-PipelineAtomicJson,Test-PipelineAppendOnlyArtifact,New-PipelineBaselineRecord,New-PipelineTombstoneInventory,Get-PipelineTaskDelta,Test-PipelineLegacyRestoration
