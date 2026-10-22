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
Assert-Equal 'tag default'         $c.Snapshot.Tag 'Veeam-Backup'
Assert-Equal 'keep-for default'    $c.Snapshot.KeepFor 'none'
Assert-Equal 'keep-for default ms' $c.Snapshot.KeepForMs 0
Assert-Equal 'array expiry = keep-for + 7d' $c.Snapshot.ArrayExpiryMs 604800000
Assert-Equal 'fail-safe default'   $c.Behaviour.FailSafePath 'True'
Assert-Equal 'ensure mode default' $c.Behaviour.EnsureProcessingMode 'True'
Assert-Equal 'log retention default' $c.Logging.RetentionDays 30
Assert-Equal 'log dir default null' ($null -eq $c.Logging.Directory) 'True'

Write-TestSection 'Get-EvpConfig: sample file loads'
$sample = Get-EvpConfig -Path (Join-Path $projectRoot 'config.sample.jsonc')
Assert-Equal 'sample shares' $sample.Shares.Count 4
Assert-Equal 'sample arrays' $sample.Arrays.Count 2

Write-TestSection 'Get-EvpConfig: validation'
function Test-ConfigError([string] $Name, [string] $Json, [string] $Pattern) {
	$path = Write-TestFile -Path (Join-Path $tmp "jobs/$([guid]::NewGuid().ToString('N')).jsonc") -Content $Json
	Assert-Throws $Name { Get-EvpConfig -Path $path } $Pattern
}
Assert-Throws 'missing file' { Get-EvpConfig -Path (Join-Path $tmp 'nope.jsonc') } 'was not found'
Test-ConfigError 'not json' '{ this is not json' 'could not be read as JSON'
Test-ConfigError 'no arrays'  '{ "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'Arrays must list at least one'
Test-ConfigError 'no shares'  '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ] }' 'Shares must list at least one'
Test-ConfigError 'duplicate array' '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" }, { "Name": "fa", "Endpoint": "e2", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ] }' 'used more than once'
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
$path = Write-TestFile -Path (Join-Path $tmp 'jobs/keep-max.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "e", "ApiTokenFile": "t" } ], "Shares": [ { "VeeamPath": "srv:/e", "Array": "fa" } ], "Snapshot": { "KeepFor": "365d" } }'
Assert-Equal 'array expiry capped at 365d' (Get-EvpConfig -Path $path).Snapshot.ArrayExpiryMs 31536000000
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
if (Test-IsWindowsHost) { Write-TestSkipped 'unwritable destination throws' 'needs a path the test user cannot create on Windows' }
else { Assert-Throws 'unwritable destination throws (module stops on .NET exceptions)' { Protect-EvpSecret -Secret $secret -Path '/nonexistent-root-evp/x/y.token' -Platform $platform -Group '' 6>$null } }

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Logging'
$logDir = Join-Path $tmp 'log'
$old = Write-TestFile -Path (Join-Path $logDir 'job-20200101000000-pre.log') -Content 'old'
(Get-Item $old).LastWriteTime = (Get-Date).AddDays(-40)
$keep = Write-TestFile -Path (Join-Path $logDir 'other-20200101000000-pre.log') -Content 'other profile'
(Get-Item $keep).LastWriteTime = (Get-Date).AddDays(-40)
$logPath = Start-EvpLog -LogDirectory $logDir -ProfileName 'job' -Phase 'pre' -RetentionDays 30 6>$null
Write-Host 'hello transcript'
Stop-EvpLog
Assert-True 'transcript named profile-ts-phase' ((Split-Path -Leaf $logPath) -match '^job-\d{14}-pre\.log$')
Assert-True 'transcript captured output' ((Get-Content $logPath -Raw) -match 'hello transcript')
Assert-Equal 'old same-profile log pruned' (Test-Path $old) 'False'
Assert-Equal 'other profile untouched' (Test-Path $keep) 'True'
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
Assert-Equal 'eight codes' $codes.Count 8

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-TestRun
