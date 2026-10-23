# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Unit tests for the pure layers: durations, share paths, snapshot naming, configuration
	loading and validation, secret files. No network, no Veeam, no array.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
Initialize-TestCounters
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'EverpureVeeamNas.psd1') -Force
$platform = Get-EvpPlatform
$tmp = Get-TestDirectory

# ---------------------------------------------------------------------------------------------
Write-TestSection 'ConvertTo-EvpMilliseconds'
Assert-Equal '7d'          (ConvertTo-EvpMilliseconds -Duration '7d')      604800000
Assert-Equal '1w'          (ConvertTo-EvpMilliseconds -Duration '1w')      604800000
Assert-Equal '48h'         (ConvertTo-EvpMilliseconds -Duration '48h')     172800000
Assert-Equal '1d12h'       (ConvertTo-EvpMilliseconds -Duration '1d12h')   129600000
Assert-Equal '6h30m'       (ConvertTo-EvpMilliseconds -Duration '6h30m')    23400000
Assert-Equal '90m'         (ConvertTo-EvpMilliseconds -Duration '90m')       5400000
Assert-Equal '1w1d1h1m1s'  (ConvertTo-EvpMilliseconds -Duration '1w1d1h1m1s') 694861000
Assert-Equal 'case/space'  (ConvertTo-EvpMilliseconds -Duration '  7D ')   604800000
foreach ($form in @('none', 'never', 'off', 'unlimited', '0', '0h', '', $null)) { Assert-Equal "'$form' is zero" (ConvertTo-EvpMilliseconds -Duration $form) 0 }
Assert-Throws 'bare number'     { ConvertTo-EvpMilliseconds -Duration '3600' } 'has no unit'
Assert-Throws 'unknown unit'    { ConvertTo-EvpMilliseconds -Duration '7x' } 'Could not parse'
Assert-Throws 'out of order'    { ConvertTo-EvpMilliseconds -Duration '30m2h' } 'Could not parse'
Assert-Throws 'below minimum'   { ConvertTo-EvpMilliseconds -Duration '30s' -MinimumMs 300000 } 'outside the accepted range'
Assert-Throws 'above maximum'   { ConvertTo-EvpMilliseconds -Duration '400d' -MaximumMs 31536000000 } 'outside the accepted range'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Share paths'
Assert-Equal 'SMB detected' (Get-EvpShareProtocol -VeeamPath '\\192.0.2.10\finance-smb') 'SMB'
Assert-Equal 'NFS detected' (Get-EvpShareProtocol -VeeamPath '192.0.2.20:/projects-nfs') 'NFS'
Assert-Equal 'FQDN NFS detected' (Get-EvpShareProtocol -VeeamPath 'fb.lab.local:/export/sub') 'NFS'
Assert-Equal 'garbage is null' ($null -eq (Get-EvpShareProtocol -VeeamPath 'C:\share')) 'True'
$p = Split-EvpSharePath -VeeamPath '\\192.0.2.10\finance-smb\'
Assert-Equal 'SMB server' $p.Server '192.0.2.10'
Assert-Equal 'SMB share'  $p.ShareName 'finance-smb'
$p = Split-EvpSharePath -VeeamPath '192.0.2.20:/projects-nfs/'
Assert-Equal 'NFS server' $p.Server '192.0.2.20'
Assert-Equal 'NFS export' $p.ShareName 'projects-nfs'
Assert-Equal 'normalised compare' (Get-EvpNormalizedSharePath -VeeamPath '\\SRV\Share\') (Get-EvpNormalizedSharePath -VeeamPath '\\srv\share')
Assert-Equal 'SMB snapshot path' (Get-EvpStorageSnapshotPath -VeeamPath '\\srv\share' -SnapshotDirectoryName 'Veeam-Backup.20261020T081500Z') '\\srv\share\.snapshot\Veeam-Backup.20261020T081500Z'
Assert-Equal 'NFS snapshot path' (Get-EvpStorageSnapshotPath -VeeamPath 'srv:/export/' -SnapshotDirectoryName 'fs.Veeam-Backup-20261020T081500Z') 'srv:/export/.snapshot/fs.Veeam-Backup-20261020T081500Z'
Assert-Equal 'custom root' (Get-EvpStorageSnapshotPath -VeeamPath 'srv:/export' -SnapshotDirectoryName 'x' -SnapshotRootDirName '.snapshots') 'srv:/export/.snapshots/x'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Snapshot naming'
$ts = '20261020T081500Z'
Assert-True 'timestamp format' ((Get-EvpTimestamp) -match '^\d{8}T\d{6}Z$')
$fa = New-EvpSnapshotName -Tag 'Veeam-Backup' -Platform FlashArray -SourceName 'fs:dir' -Timestamp $ts
Assert-Equal 'FA client_name' $fa.ClientName 'Veeam-Backup'
Assert-Equal 'FA suffix'      $fa.Suffix $ts
Assert-Equal 'FA directory'   $fa.DirectoryName "Veeam-Backup.$ts"
Assert-Equal 'FA array name'  $fa.ArrayName "fs:dir.Veeam-Backup.$ts"
$fb = New-EvpSnapshotName -Tag 'Veeam-Backup' -Platform FlashBlade -SourceName 'myfs' -Timestamp $ts
Assert-Equal 'FB suffix'      $fb.Suffix "Veeam-Backup-$ts"
Assert-True  'FB suffix has no dot' ($fb.Suffix -notmatch '\.')
Assert-True  'FB suffix charset' ($fb.Suffix -match '^[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9]$')
Assert-Equal 'FB directory'   $fb.DirectoryName "myfs.Veeam-Backup-$ts"
$pattern = Get-EvpSnapshotMatchPattern -Tag 'Veeam-Backup'
Assert-True 'pattern matches FA name' ($fa.ArrayName -match $pattern)
Assert-True 'pattern matches FB name' ($fb.ArrayName -match $pattern)
Assert-True 'pattern rejects other tag' ("myfs.Other-Backup-$ts" -notmatch $pattern)
Assert-True 'pattern rejects legacy name' ('dir.Veeam.Backup20260821160315' -notmatch $pattern)
Assert-True 'pattern rejects tag prefix' ("fs.XVeeam-Backup.$ts" -notmatch $pattern)
Assert-Equal 'timestamp from FA name' (Get-EvpSnapshotTimestamp -Name $fa.ArrayName -Tag 'Veeam-Backup').ToString('yyyyMMddTHHmmssZ') $ts
Assert-Equal 'timestamp from FB name' (Get-EvpSnapshotTimestamp -Name $fb.ArrayName -Tag 'Veeam-Backup').ToString('yyyyMMddTHHmmssZ') $ts
Assert-Equal 'timestamp is UTC' (Get-EvpSnapshotTimestamp -Name $fa.ArrayName -Tag 'Veeam-Backup').Kind 'Utc'
Assert-Equal 'no timestamp for foreign name' ($null -eq (Get-EvpSnapshotTimestamp -Name 'policy-snap-0001' -Tag 'Veeam-Backup')) 'True'
Assert-True 'sentinel is unmistakable' ((Get-EvpSentinelDirectoryName) -match '^__everpure-pre-backup-failed-\d{8}T\d{6}Z__$')
Assert-True 'sentinel does not match the tag pattern' ((Get-EvpSentinelDirectoryName) -notmatch $pattern)
Assert-True 'disarm sentinel is unmistakable' ((Get-EvpSentinelDirectoryName -Reason Disarmed) -match '^__everpure-awaiting-pre-backup-\d{8}T\d{6}Z__$')
Assert-Equal 'default tag from profile name' (Get-EvpDefaultSnapshotTag -ProfileName 'lab.files_01') 'veeam-lab-files-01'
$longTag = Get-EvpDefaultSnapshotTag -ProfileName ('a' * 33 + '-b-c')
Assert-True 'default tag cut to 40, no trailing dash' ($longTag.Length -le 40 -and $longTag -notmatch '-$' -and $longTag -match '^veeam-a{33}$')
Assert-Equal 'default tag falls back to the job id' (Get-EvpDefaultSnapshotTag -ProfileName '__' -JobId 'aaaaaaaa-1111-4111-8111-000000000001') 'veeam-aaaaaaaa111141118111000000000001'
Assert-Equal 'default tag last resort' (Get-EvpDefaultSnapshotTag -ProfileName '__') 'veeam-backup'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Get-EvpConfig: defaults and path resolution'
$minimal = @'
// comment
{
	"Arrays": [ { "Name": "fa", "Endpoint": "fa.lab", "ApiTokenFile": "secrets/fa.token" } ],
	"Shares": [ { "VeeamPath": "\\\\srv\\share", "Array": "fa" }, { "VeeamPath": "srv:/export", "Array": "fa", "Source": "fs:dir" } ]
}
'@
$cfgPath = Write-TestFile -Path (Join-Path $tmp 'jobs/minimal.jsonc') -Content $minimal
$c = Get-EvpConfig -Path $cfgPath
Assert-Equal 'profile name'        $c.ProfileName 'minimal'
Assert-Equal 'backend default'     $c.Veeam.Backend 'auto'
Assert-Equal 'server default'      $c.Veeam.Server 'localhost'
Assert-Equal 'port default'        $c.Veeam.Port 9419
Assert-Equal 'tls default'         $c.Veeam.Tls 'skip'
Assert-Equal 'force cert default'  $c.Veeam.ForceAcceptTlsCertificate 'True'
Assert-Equal 'token path resolved against config dir' $c.Arrays['fa'].ApiTokenFile (Join-Path (Join-Path $tmp 'jobs') 'secrets/fa.token')
Assert-Equal 'array platform auto' $c.Arrays['fa'].Platform 'auto'
Assert-Equal 'share protocol'      $c.Shares[0].Protocol 'SMB'
Assert-Equal 'share source auto'   $c.Shares[0].Source 'auto'
Assert-Equal 'explicit source kept' $c.Shares[1].Source 'fs:dir'
Assert-Equal 'tag default from profile' $c.Snapshot.Tag 'veeam-minimal'
Assert-Equal 'keep-for default'    $c.Snapshot.KeepFor 'none'
Assert-Equal 'keep-for default ms' $c.Snapshot.KeepForMs 0
Assert-Equal 'array expiry = keep-for + 7d' $c.Snapshot.ArrayExpiryMs 604800000
Assert-Equal 'fail-safe default'   $c.Behaviour.FailSafePath 'True'
Assert-Equal 'ensure mode default' $c.Behaviour.EnsureProcessingMode 'True'
Assert-Equal 'log retention default' $c.Logging.RetentionDays 30
Assert-Equal 'log dir default null' ($null -eq $c.Logging.Directory) 'True'

Write-TestSection 'Get-EvpConfig: sample files load'
# As the generator writes them: the job's ID filled in, the arrays sample as jobs/arrays.jsonc.
$sampleDir = Join-Path $tmp 'sample-jobs'
$sampleText = (Get-Content (Join-Path $projectRoot 'config.sample.jsonc') -Raw).Replace('"JobId": ""', '"JobId": "aaaaaaaa-1111-4111-8111-000000000001"')
$arraysSample = Get-Content (Join-Path $projectRoot 'arrays.sample.jsonc') -Raw
$null = Write-TestFile -Path (Join-Path $sampleDir 'arrays.jsonc') -Content $arraysSample
Assert-Throws 'sample: a fresh arrays file asks for arrays' { Get-EvpConfig -Path (Write-TestFile -Path (Join-Path $sampleDir 'files.jsonc') -Content $sampleText) } 'No arrays are defined'
# The admin's edit: the commented examples switched on.
$null = Write-TestFile -Path (Join-Path $sampleDir 'arrays.jsonc') -Content ($arraysSample -replace '(?m)^(\s*)// (\{ "Name")', '$1$2')
$sample = Get-EvpConfig -Path (Join-Path $sampleDir 'files.jsonc')
Assert-Equal 'sample: no shares, they come from the job' $sample.Shares.Count 0
Assert-Equal 'sample: arrays from the arrays file' $sample.Arrays.Count 3
Assert-Equal 'sample: the fleet example is a fleet' $sample.Arrays['fleet01'].Type 'Fleet'
Assert-Equal 'sample: arrays file found beside the job file' $sample.ArraysFile (Join-Path $sampleDir 'arrays.jsonc')
Assert-Equal 'sample: token path relative to the arrays file' $sample.Arrays['fa01'].ApiTokenFile (Join-Path $sampleDir 'secrets/fa01.token')
Assert-Throws 'sample without a job ID needs Shares' { Get-EvpConfig -Path (Write-TestFile -Path (Join-Path $sampleDir 'unbound.jsonc') -Content (Get-Content (Join-Path $projectRoot 'config.sample.jsonc') -Raw)) } 'or set Veeam.JobId'
# A 1.0.0 job file with its own arrays next to a fresh arrays file: unchanged.
$legacy = Write-TestFile -Path (Join-Path $tmp 'legacy-jobs/old.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }'
$null = Write-TestFile -Path (Join-Path $tmp 'legacy-jobs/arrays.jsonc') -Content $arraysSample
Assert-Equal '1.0.0 job file beside a fresh arrays file: only its own arrays' ((Get-EvpConfig -Path $legacy).Arrays.Keys -join ',') 'fa'

Write-TestSection 'Adding an array to an arrays file'
$addDir = Join-Path $tmp 'add-array'
function Test-AddArray([string] $Name, [string] $Start, [string[]] $Expected) {
	$p = Write-TestFile -Path (Join-Path $addDir "$([guid]::NewGuid().ToString('N')).jsonc") -Content $Start
	Add-EvpArraysFileEntry -Path $p -Name 'new01' -Endpoint 'new01.example.com'
	$a = Read-EvpArraysFile -Path $p
	Assert-Equal "$Name`: arrays afterwards" ($a.Keys -join ',') ($Expected -join ',')
	return (Get-Content $p -Raw)
}
$after = Test-AddArray 'sample with commented examples' $arraysSample @('new01')
Assert-True  'sample: comments kept' ($after -match '// \{ "Name": "fa01"' -and $after -match 'NEVER put a token')
Assert-True  'sample: token file beside the arrays file' ($after -match '"ApiTokenFile": "secrets/new01.token"')
$null = Test-AddArray 'one entry, bracket on its own line' "{`n`t`"Arrays`": [`n`t`t{ `"Name`": `"fa`", `"Endpoint`": `"e`", `"ApiTokenFile`": `"t`" } // first`n`t]`n}" @('fa', 'new01')
$null = Test-AddArray 'empty list on one line' '{ "Arrays": [] }' @('new01')
$null = Test-AddArray 'entry and bracket on one line' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ] }' @('fa', 'new01')
$null = Test-AddArray 'other lists and strings with brackets before it' '{ "Note": "a ] in [ text", "Other": [1, 2], /* "Arrays": [ */ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ] }' @('fa', 'new01')
$noList = Write-TestFile -Path (Join-Path $addDir 'nolist.jsonc') -Content '{ }'
Assert-Throws 'a file without Arrays is refused' { Add-EvpArraysFileEntry -Path $noList -Name 'x' -Endpoint 'e' } 'no top-level Arrays list'
Assert-Equal 'refused file unchanged' (Get-Content $noList -Raw) '{ }'
$sameName = Write-TestFile -Path (Join-Path $addDir 'same.jsonc') -Content '{ "Arrays": [ { "Name": "new01", "Endpoint": "e", "ApiTokenFile": "t" } ] }'
Assert-Throws 'a duplicate name is refused and rolled back' { Add-EvpArraysFileEntry -Path $sameName -Name 'new01' -Endpoint 'e2' } 'left unchanged'
Assert-Equal 'rolled-back file unchanged' (Get-Content $sameName -Raw) '{ "Arrays": [ { "Name": "new01", "Endpoint": "e", "ApiTokenFile": "t" } ] }'
Assert-Throws 'a name unfit for a file name is refused' { Add-EvpArraysFileEntry -Path $sameName -Name '../x' -Endpoint 'e' } 'ValidatePattern|does not match'

Write-TestSection 'Get-EvpConfig: arrays file'
$afDir = Join-Path $tmp 'arrays-file'
$null = Write-TestFile -Path (Join-Path $afDir 'shared/arrays.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "fa.example.com", "ApiTokenFile": "secrets/fa.token" } ] }'
$job = Write-TestFile -Path (Join-Path $afDir 'jobs/a.jsonc') -Content '{ "ArraysFile": "../shared/arrays.jsonc", "Veeam": { "JobId": "aaaaaaaa-1111-4111-8111-000000000001" }, "Arrays": [ { "Name": "fb", "Endpoint": "fb.example.com", "ApiTokenFile": "fb.token" } ] }'
$c = Get-EvpConfig -Path $job
Assert-Equal 'arrays merged from both files' (($c.Arrays.Keys | Sort-Object) -join ',') 'fa,fb'
Assert-Equal 'explicit ArraysFile resolved' $c.ArraysFile (Join-Path $afDir 'shared/arrays.jsonc')
Assert-Equal 'arrays-file token beside the arrays file' $c.Arrays['fa'].ApiTokenFile (Join-Path $afDir 'shared/secrets/fa.token')
Assert-Equal 'inline token beside the job file' $c.Arrays['fb'].ApiTokenFile (Join-Path $afDir 'jobs/fb.token')
Assert-Equal 'origin kept' $c.Arrays['fa'].Origin (Join-Path $afDir 'shared/arrays.jsonc')
Assert-Equal 'job guard on with a job id' $c.Veeam.JobGuard 'True'
Assert-Equal 'state directory default null' ($null -eq $c.State.Directory) 'True'
$clash = Write-TestFile -Path (Join-Path $afDir 'jobs/b.jsonc') -Content '{ "ArraysFile": "../shared/arrays.jsonc", "Veeam": { "JobId": "aaaaaaaa-1111-4111-8111-000000000001" }, "Arrays": [ { "Name": "fa", "Endpoint": "other", "ApiTokenFile": "t" } ] }'
Assert-Throws 'a name in both files is an error' { Get-EvpConfig -Path $clash } "defined in both"
$missingFile = Write-TestFile -Path (Join-Path $afDir 'jobs/c.jsonc') -Content '{ "ArraysFile": "nope.jsonc", "Veeam": { "JobId": "aaaaaaaa-1111-4111-8111-000000000001" } }'
Assert-Throws 'explicit ArraysFile must exist' { Get-EvpConfig -Path $missingFile } "ArraysFile .* was not found"
$override = Write-TestFile -Path (Join-Path $afDir 'shared/d.jsonc') -Content '{ "Veeam": { "JobId": "aaaaaaaa-1111-4111-8111-000000000001" }, "Shares": [ { "VeeamPath": "\\\\srv\\share", "Source": "fs:dir" } ], "State": { "Directory": "st" } }'
$c = Get-EvpConfig -Path $override
Assert-Equal 'default arrays.jsonc beside the job file' $c.Arrays['fa'].Endpoint 'fa.example.com'
Assert-Equal 'override without Array: mapped at run time' $c.Shares[0].Array ''
Assert-Equal 'override source kept' $c.Shares[0].Source 'fs:dir'
Assert-Equal 'state directory resolved' $c.State.Directory (Join-Path $afDir 'shared/st')

Write-TestSection 'Get-EvpConfig: validation'
function Test-ConfigError([string] $Name, [string] $Json, [string] $Pattern) {
	$path = Write-TestFile -Path (Join-Path $tmp "jobs/$([guid]::NewGuid().ToString('N')).jsonc") -Content $Json
	Assert-Throws $Name { Get-EvpConfig -Path $path } $Pattern
}
Assert-Throws 'missing file' { Get-EvpConfig -Path (Join-Path $tmp 'nope.jsonc') } 'was not found'
Test-ConfigError 'not json' '{ this is not json' 'could not be read as JSON'
Test-ConfigError 'no arrays'  '{ "Shares": [ { "VeeamPath": "srv:/e" } ] }' 'No arrays are defined.*arrays\.jsonc'
Test-ConfigError 'no shares'  '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ] }' 'Shares must list at least one share, or set Veeam.JobId'
Test-ConfigError 'duplicate array' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" }, { "Name": "fa", "Endpoint": "e2", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'defined more than once'
Test-ConfigError 'unknown array ref' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fb" } ] }' "unknown array 'fb'"
Test-ConfigError 'bad share path' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "C:\\share", "Array": "fa" } ] }' 'neither an SMB path'
Test-ConfigError 'duplicate share' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" }, { "VeeamPath": "srv:/e/", "Array": "fa" } ] }' 'listed more than once'
Test-ConfigError 'no token file' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'has no ApiTokenFile'
Test-ConfigError 'bad tag (dot)' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "Tag": "Veeam.Backup" } }' 'Snapshot.Tag'
Test-ConfigError 'bad tag (numeric)' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "Tag": "12345" } }' 'Snapshot.Tag'
Test-ConfigError 'bad keep-for' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "7" } }' 'Snapshot.KeepFor'
$path = Write-TestFile -Path (Join-Path $tmp 'jobs/keep.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "7d" } }'
$k = Get-EvpConfig -Path $path
Assert-Equal 'keep-for 7d ms' $k.Snapshot.KeepForMs 604800000
Assert-Equal 'array expiry 14d' $k.Snapshot.ArrayExpiryMs 1209600000
$path = Write-TestFile -Path (Join-Path $tmp 'jobs/keep-max.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "358d" } }'
Assert-Equal 'keep-for 358d: array expiry exactly 365d' (Get-EvpConfig -Path $path).Snapshot.ArrayExpiryMs 31536000000
Test-ConfigError 'keep-for above 358d' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "359d" } }' 'at most 358d'
Test-ConfigError 'keep-for overflow' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "600000w" } }' 'Snapshot.KeepFor'
Test-ConfigError 'FailIfNoSnapshots with a keep-for duration' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "1d" }, "Behaviour": { "FailIfNoSnapshots": true } }' 'FailIfNoSnapshots'
Test-ConfigError 'thumbprint of impossible length' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t", "Tls": "thumbprint:0123456789012345678901234567890123456789ABCDEFABCD" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Tls'
$path = Write-TestFile -Path (Join-Path $tmp 'jobs/explicit-tag.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "Tag": "Veeam-Backup" } }'
Assert-Equal 'explicit tag wins over the default' (Get-EvpConfig -Path $path).Snapshot.Tag 'Veeam-Backup'
Test-ConfigError 'user without password' '{ "Veeam": { "User": "x" }, "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'must be set together'
Test-ConfigError 'bad backend' '{ "Veeam": { "Backend": "soap" }, "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Veeam.Backend'
Test-ConfigError 'bad job id' '{ "Veeam": { "JobId": "not-a-guid" }, "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Veeam.JobId'
Test-ConfigError 'bad tls' '{ "Veeam": { "Tls": "yolo" }, "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Veeam.Tls'
Test-ConfigError 'bad platform' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t", "Platform": "Netapp" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Platform must be'
$path = Write-TestFile -Path (Join-Path $tmp 'jobs/multi.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e" } ], "Shares": [ { "VeeamPath": "bad", "Array": "zz" } ], "Snapshot": { "Tag": "a.b" } }'
try { Get-EvpConfig -Path $path } catch { $msg = $_.Exception.Message }
Assert-True 'all problems reported at once' (($msg -split "`n").Count -ge 4)

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Secrets'
$secret = ConvertTo-SecureString -String 'tok-123' -AsPlainText -Force
$secretPath = Join-Path $tmp 'secrets/test.token'
Protect-EvpSecret -Secret $secret -Path $secretPath -Platform $platform -Group '' 6>$null 3>$null
$back = Unprotect-EvpSecret -Path $secretPath -Platform $platform 3>$null
Assert-Equal 'round trip' (ConvertFrom-EvpSecureString $back) 'tok-123'
$report = Test-EvpSecretFile -Path $secretPath -Platform $platform
Assert-True 'report exists' $report.Exists
if (Test-IsWindowsHost) {
	Assert-Equal 'DPAPI on Windows' $report.Protection 'DPAPI LocalMachine'
} else {
	Assert-Equal 'plain text elsewhere' $report.Protection 'plain text, file permissions'
	Assert-True  'mode 0640' ($report.Permissions -like '640 *')
	Assert-Equal 'no warnings at 0640' $report.Warnings.Count 0
	& chmod 0644 $secretPath
	$report = Test-EvpSecretFile -Path $secretPath -Platform $platform
	Assert-True 'world-readable warns' ($report.Warnings -join ' ' -match 'world-readable')
	Protect-EvpSecret -Secret $secret -Path $secretPath -Platform $platform -Group '' 6>$null 3>$null
	Assert-True 'rewrite restricts a world-readable file to 0640' ((Test-EvpSecretFile -Path $secretPath -Platform $platform).Permissions -like '640 *')
	Assert-Equal 'rewrite keeps the secret' (ConvertFrom-EvpSecureString (Unprotect-EvpSecret -Path $secretPath -Platform $platform 3>$null)) 'tok-123'
}
$plainPath = Write-TestFile -Path (Join-Path $tmp 'secrets/plain.pwd') -Content "pw-with-newline`r`n"
Assert-Equal 'plain file read, newline trimmed' (ConvertFrom-EvpSecureString (Unprotect-EvpSecret -Path $plainPath -Platform $platform 3>$null)) 'pw-with-newline'
$clixml = Join-Path $tmp 'secrets/cred.clixml'
$secret | Export-Clixml -Path $clixml
Assert-Equal 'CliXml SecureString read' (ConvertFrom-EvpSecureString (Unprotect-EvpSecret -Path $clixml -Platform $platform)) 'tok-123'
Assert-Throws 'missing secret file' { Unprotect-EvpSecret -Path (Join-Path $tmp 'nope') -Platform $platform } 'was not found'
Write-TestFile -Path (Join-Path $tmp 'secrets/empty') -Content '' | Out-Null
Assert-Throws 'empty secret file' { Unprotect-EvpSecret -Path (Join-Path $tmp 'secrets/empty') -Platform $platform } 'is empty'
Assert-Equal 'missing file report' (Test-EvpSecretFile -Path (Join-Path $tmp 'nope') -Platform $platform).Exists 'False'
$unelevated = [pscustomobject]@{ IsWindows = $true; IsLinux = $false; IsElevated = $false; Identity = 'HOST\someone' }
$lockedOut = Join-Path $tmp 'not-elevated/x.token'
Assert-Throws 'non-elevated Windows session refused' { Protect-EvpSecret -Secret $secret -Path $lockedOut -Platform $unelevated 6>$null } 'not elevated.*Nothing was written'
Assert-Equal 'refused before anything was created' (Test-Path (Split-Path $lockedOut)) 'False'
Assert-True 'elevation is reported on Windows only' ($(if (Test-IsWindowsHost) { $null -ne $platform.IsElevated } else { $null -eq $platform.IsElevated }))
if (Test-IsWindowsHost) { Write-TestSkipped 'unwritable destination throws' 'needs a path the test user cannot create on Windows' }
else { Assert-Throws 'unwritable destination throws (module stops on .NET exceptions)' { Protect-EvpSecret -Secret $secret -Path '/nonexistent-root-evp/x/y.token' -Platform $platform -Group '' 6>$null } }

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Logging'
$logDir = Join-Path $tmp 'log'
$old = Write-TestFile -Path (Join-Path $logDir 'job-20200101000000-pre.log') -Content 'old'
(Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
$keep = Write-TestFile -Path (Join-Path $logDir 'other-20200101000000-pre.log') -Content 'other profile'
(Get-Item $keep).LastWriteTime = (Get-Date).AddDays(-40)
$prefixed = Write-TestFile -Path (Join-Path $logDir 'job-files-20200101000000-pre.log') -Content 'profile sharing the prefix'
(Get-Item $prefixed).LastWriteTime = (Get-Date).AddDays(-40)
$logPath = Start-EvpLog -LogDirectory $logDir -ProfileName 'job' -Phase 'pre' -RetentionDays 30 6>$null
Write-Host 'hello transcript'
Stop-EvpLog
Assert-True 'transcript named profile-ts-phase' ((Split-Path -Leaf $logPath) -match '^job-\d{14}-pre\.log$')
Assert-True 'transcript captured output' ((Get-Content $logPath -Raw) -match 'hello transcript')
Assert-Equal 'old same-profile log pruned' (Test-Path $old) 'False'
Assert-Equal 'other profile untouched' (Test-Path $keep) 'True'
Assert-Equal 'profile sharing the name prefix untouched' (Test-Path $prefixed) 'True'
# On PowerShell 7.6 a caller's $WhatIfPreference reaches module functions. The transcript must
# still be written, otherwise a dry run leaves no record.
$WhatIfPreference = $true
$dryLog = Start-EvpLog -LogDirectory $logDir -ProfileName 'dry' -Phase 'pre' -RetentionDays 30 6>$null
Write-Host 'dry run line'
Stop-EvpLog
$WhatIfPreference = $false
Assert-True 'transcript written despite WhatIf preference' ((Test-Path $dryLog) -and ((Get-Content $dryLog -Raw) -match 'dry run line'))
Assert-Equal 'default log dir on windows' (Get-EvpDefaultLogDirectory -Platform ([pscustomobject]@{ IsWindows = $true; InSandbox = $false; SandboxRoot = '/s' }) -InstallRoot '/inst' -ConfigDirectory '/cfg') (Join-Path '/inst' 'log')
Assert-Equal 'default log dir in sandbox' (Get-EvpDefaultLogDirectory -Platform ([pscustomobject]@{ IsWindows = $false; InSandbox = $true; SandboxRoot = '/var/lib/veeam/scripts/sandbox' }) -InstallRoot '/i' -ConfigDirectory '/c') '/var/lib/veeam/scripts/sandbox/everpure-veeam-nas/log'
Assert-Equal 'default log dir elsewhere' (Get-EvpDefaultLogDirectory -Platform ([pscustomobject]@{ IsWindows = $false; InSandbox = $false; SandboxRoot = '/s' }) -InstallRoot '/i' -ConfigDirectory '/c') '/c/log'

Write-TestSection 'Version'
$manifestPath = Join-Path $projectRoot 'EverpureVeeamNas.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Assert-Equal 'manifest version is MAJOR.MINOR.PATCH' ([bool]("$($manifest.Version)" -match '^\d+\.\d+\.\d+$')) $true
Assert-Equal 'Get-EvpVersion matches the manifest' (Get-EvpVersion) "$($manifest.Version)"
Assert-Equal 'loaded module carries the manifest version' (Get-Module EverpureVeeamNas).Version "$($manifest.Version)"
$changelog = Get-Content -LiteralPath (Join-Path $projectRoot 'CHANGELOG.md') -Raw
Assert-True 'CHANGELOG has an entry for the current version' ($changelog -match ('(?m)^## \[' + [regex]::Escape("$($manifest.Version)") + '\]'))

Write-TestSection 'Exit code table'
$codes = Get-EvpExitCodeTable
Assert-Equal 'success 0' $codes.Success 0
Assert-Equal 'fail-safe 10' $codes.FailSafe 10
Assert-Equal 'nine codes' $codes.Count 9

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-TestRun
