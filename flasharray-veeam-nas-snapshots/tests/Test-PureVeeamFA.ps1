# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Unit tests for PureVeeamFA.psm1. No FlashArray or Veeam server required.

.DESCRIPTION
	Covers settings resolution, configuration loading, duration parsing, API token resolution,
	snapshot sweeping, and the SMB/NFS dispatch that decides which Veeam cmdlet to call.

	Veeam inventory object types are faked with Add-Type and the Veeam cmdlets with global
	functions, because the dispatch keys on the concrete .NET type name of the inventory object.

.EXAMPLE
	.\Test-PureVeeamFA.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHelper.ps1')
Reset-TestCounters

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'PureVeeamFA.psm1') -Force

# ---------------------------------------------------------------------------------------------
# Fake Veeam inventory object types and cmdlets
# ---------------------------------------------------------------------------------------------
if (-not ('Veeam.Backup.PowerShell.Infos.VBRNASSMBServer' -as [type])) {
	Add-Type -TypeDefinition @'
namespace Veeam.Backup.PowerShell.Infos {
    public class VBRNASSMBServer   { public string Name { get; set; } }
    public class VBRNASNFSServer   { public string Name { get; set; } public string Path { get; set; } }
    public class VBRAmazonS3Folder { public string Name { get; set; } }
}
'@
}

$global:LastSetCall = $null
function global:Set-VBRNASSMBServer {
	param($Server, [string]$StorageSnapshotPath, [switch]$EnableDirectBackupFailover,
		[string]$ProcessingMode, $ErrorAction)
	$global:LastSetCall = [pscustomobject]@{
		Cmdlet = 'Set-VBRNASSMBServer'; Path = $StorageSnapshotPath
		Failover = $EnableDirectBackupFailover.IsPresent; Mode = $ProcessingMode
	}
}
function global:Set-VBRNASNFSServer {
	param($Server, [string]$StorageSnapshotPath, [switch]$EnableDirectBackupFailover,
		[string]$ProcessingMode, $ErrorAction)
	$global:LastSetCall = [pscustomobject]@{
		Cmdlet = 'Set-VBRNASNFSServer'; Path = $StorageSnapshotPath
		Failover = $EnableDirectBackupFailover.IsPresent; Mode = $ProcessingMode
	}
}
$global:InventoryResult = @()
function global:Get-VBRUnstructuredServer { param([string[]]$Name, $ErrorAction); $global:InventoryResult }

# Fake FlashArray snapshot cmdlets for the sweeper tests
$global:SnapshotFixture = @()
$global:DestroyCalls = @()
function global:Get-Pfa2DirectorySnapshot { param($Array, [string]$SourceNames, $ErrorAction); $global:SnapshotFixture }
function global:Update-Pfa2DirectorySnapshot {
	param($Array, [string]$Ids, [switch]$Destroyed, $ErrorAction)
	$global:DestroyCalls += $Ids
}

$smb = [Veeam.Backup.PowerShell.Infos.VBRNASSMBServer]@{ Name = '\\172.16.16.15\lab-files' }
$nfs = [Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = '172.16.16.15:/lab-nfs' }
$s3 = [Veeam.Backup.PowerShell.Infos.VBRAmazonS3Folder]@{ Name = 'bucket-01' }

# ---------------------------------------------------------------------------------------------
Write-TestSection 'ConvertTo-PureVeeamKeepFor: valid durations'
Assert-Equal '7d'        (ConvertTo-PureVeeamKeepFor -Duration '7d')     604800000
Assert-Equal '1w'        (ConvertTo-PureVeeamKeepFor -Duration '1w')     604800000
Assert-Equal '48h'       (ConvertTo-PureVeeamKeepFor -Duration '48h')    172800000
Assert-Equal '1d12h'     (ConvertTo-PureVeeamKeepFor -Duration '1d12h')  129600000
Assert-Equal '6h30m'     (ConvertTo-PureVeeamKeepFor -Duration '6h30m')   23400000
Assert-Equal '90m'       (ConvertTo-PureVeeamKeepFor -Duration '90m')      5400000
Assert-Equal '5m minimum' (ConvertTo-PureVeeamKeepFor -Duration '5m')       300000
Assert-Equal '365d maximum' (ConvertTo-PureVeeamKeepFor -Duration '365d') 31536000000
Assert-Equal 'case insensitive' (ConvertTo-PureVeeamKeepFor -Duration '7D') 604800000
Assert-Equal 'whitespace tolerated' (ConvertTo-PureVeeamKeepFor -Duration '  48h ') 172800000
Assert-Equal 'combined w+d+h+m+s' (ConvertTo-PureVeeamKeepFor -Duration '1w1d1h1m1s') 694861000

Write-TestSection 'ConvertTo-PureVeeamKeepFor: no-expiry forms all return 0'
foreach ($form in @('none', 'never', 'off', 'unlimited', '0', 'NONE', '0h', '0d')) {
	Assert-Equal "'$form'" (ConvertTo-PureVeeamKeepFor -Duration $form) 0
}
Assert-Equal 'empty string' (ConvertTo-PureVeeamKeepFor -Duration '') 0
Assert-Equal 'null'         (ConvertTo-PureVeeamKeepFor -Duration $null) 0

Write-TestSection 'ConvertTo-PureVeeamKeepFor: rejections'
Assert-Throws 'bare number is ambiguous' { ConvertTo-PureVeeamKeepFor -Duration '604800000' } 'has no unit'
Assert-Throws 'below the 5m minimum'  { ConvertTo-PureVeeamKeepFor -Duration '30s' }  'outside the range'
Assert-Throws 'above the 365d maximum' { ConvertTo-PureVeeamKeepFor -Duration '400d' } 'outside the range'
Assert-Throws 'unknown unit'      { ConvertTo-PureVeeamKeepFor -Duration '7x' }    'Could not parse'
Assert-Throws 'not a duration'    { ConvertTo-PureVeeamKeepFor -Duration 'abc' }   'Could not parse'
Assert-Throws 'repeated unit'     { ConvertTo-PureVeeamKeepFor -Duration '7d7d' }  'Could not parse'
Assert-Throws 'units out of order' { ConvertTo-PureVeeamKeepFor -Duration '30m2h' } 'Could not parse'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Set-PureVeeamStorageSnapshotPath: protocol dispatch and path building'
$path = Set-PureVeeamStorageSnapshotPath -Server $smb -SnapshotName 'Veeam.Backup20260817093153' 6>$null
Assert-Equal 'SMB path'            $path '\\172.16.16.15\lab-files\.snapshot\Veeam.Backup20260817093153'
Assert-Equal 'SMB cmdlet'          $global:LastSetCall.Cmdlet 'Set-VBRNASSMBServer'
Assert-Equal 'SMB failover off'    $global:LastSetCall.Failover 'False'
Assert-Equal 'SMB mode untouched'  $global:LastSetCall.Mode ''

$path = Set-PureVeeamStorageSnapshotPath -Server $nfs -SnapshotName 'Veeam.Backup20260817093153' 6>$null
Assert-Equal 'NFS path'            $path '172.16.16.15:/lab-nfs/.snapshot/Veeam.Backup20260817093153'
Assert-Equal 'NFS cmdlet'          $global:LastSetCall.Cmdlet 'Set-VBRNASNFSServer'

$nfsTrailing = [Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = '172.16.16.15:/lab-nfs/' }
$path = Set-PureVeeamStorageSnapshotPath -Server $nfsTrailing -SnapshotName 'Veeam.Backup1' 6>$null
Assert-Equal 'NFS trailing slash trimmed' $path '172.16.16.15:/lab-nfs/.snapshot/Veeam.Backup1'

$path = Set-PureVeeamStorageSnapshotPath -Server $nfs -SnapshotName 'Veeam.Backup1' `
	-SharePath '10.0.0.1:/export' -SnapshotRootDirName '.snapshots' 6>$null
Assert-Equal 'SharePath and root override' $path '10.0.0.1:/export/.snapshots/Veeam.Backup1'

$path = Set-PureVeeamStorageSnapshotPath -Server $smb -SnapshotName 'ignored' `
	-StorageSnapshotPath '\\host\s\weird\place' 6>$null
Assert-Equal 'StorageSnapshotPath override wins' $path '\\host\s\weird\place'

$null = Set-PureVeeamStorageSnapshotPath -Server $nfs -SnapshotName 'Veeam.Backup1' `
	-SetProcessingModeStorageSnapshot 6>$null
Assert-Equal 'ProcessingMode is opt-in' $global:LastSetCall.Mode 'StorageSnapshot'

Assert-Throws 'unsupported source type' {
	Set-PureVeeamStorageSnapshotPath -Server $s3 -SnapshotName 'x' 6>$null
} 'has type .VBRAmazonS3Folder., which these scripts do not support'

Write-TestSection 'Set-PureVeeamStorageSnapshotPath: -WhatIf makes no call'
$global:LastSetCall = $null
$path = Set-PureVeeamStorageSnapshotPath -Server $nfs -SnapshotName 'Veeam.Backup1' -WhatIf 6>$null
Assert-Equal 'WhatIf still returns the path' $path '172.16.16.15:/lab-nfs/.snapshot/Veeam.Backup1'
Assert-Equal 'WhatIf made no cmdlet call'    ($null -eq $global:LastSetCall) 'True'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Get-PureVeeamUnstructuredServer: requires exactly one match'
$global:InventoryResult = @($nfs)
$found = Get-PureVeeamUnstructuredServer -Name '172.16.16.15:/lab-nfs' 6>$null
Assert-Equal 'single match returns the object' $found.Name '172.16.16.15:/lab-nfs'

$global:InventoryResult = @()
Assert-Throws 'no match' { Get-PureVeeamUnstructuredServer -Name 'nope' 6>$null } 'No unstructured data source named .nope.'

$global:InventoryResult = @($smb, $s3)
Assert-Throws 'ambiguous match' { Get-PureVeeamUnstructuredServer -Name 'dup' 6>$null } 'Found 2 unstructured data sources'

Write-TestSection 'Get-PureVeeamSourceLabel'
# Veeam Backup & Replication 13.1 returns an empty Name on every unstructured source and puts the
# share path in Path, confirmed against a live server.
Assert-Equal 'prefers Name' (Get-PureVeeamSourceLabel -Server ([pscustomobject]@{ Name = 'n'; Path = 'p' })) 'n'
Assert-Equal 'falls back to Path' (Get-PureVeeamSourceLabel -Server ([pscustomobject]@{ Name = ''; Path = 'p' })) 'p'
Assert-Equal 'falls back to ServerName' (Get-PureVeeamSourceLabel -Server ([pscustomobject]@{ Name = $null; ServerName = 's' })) 's'
Assert-Equal 'falls back to the caller value' (Get-PureVeeamSourceLabel -Server ([pscustomobject]@{ Name = '  ' }) -Fallback 'f') 'f'
Assert-Equal 'null object uses the fallback' (Get-PureVeeamSourceLabel -Server $null -Fallback 'f') 'f'
Assert-Equal 'nothing at all is empty, not an error' (Get-PureVeeamSourceLabel -Server $null) ''

Write-TestSection 'Set-PureVeeamStorageSnapshotPath: builds the path from Path when Name is empty'
$noName = [Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = ''; Path = '10.0.0.9:/export' }
$path = Set-PureVeeamStorageSnapshotPath -Server $noName -SnapshotName 'Veeam.Backup1' 6>$null
Assert-Equal 'path is built from Path' $path '10.0.0.9:/export/.snapshot/Veeam.Backup1'

Assert-Throws 'no name and no path is a clear error' {
	Set-PureVeeamStorageSnapshotPath -Server ([Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = ''; Path = '' }) `
		-SnapshotName 'Veeam.Backup1' 6>$null
} 'reports no name or path'

Write-TestSection 'Get-PureVeeamUnstructuredServer: log label falls back when Name is empty'
# NFS exports come back from the real inventory with an empty Name, which made the transcript
# report "Found Veeam unstructured data source ''".
$global:InventoryResult = @([Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = ''; Path = '10.0.0.1:/export' })
$null = Get-PureVeeamUnstructuredServer -Name 'asked-for' -InformationVariable info 6>$null
Assert-Equal 'falls back to Path' ([bool](($info -join ' ') -match "source '10\.0\.0\.1:/export'")) 'True'

$global:InventoryResult = @([Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = ''; Path = '' })
$null = Get-PureVeeamUnstructuredServer -Name 'asked-for' -InformationVariable info 6>$null
Assert-Equal 'falls back to the requested name' ([bool](($info -join ' ') -match "source 'asked-for'")) 'True'

$global:InventoryResult = @($nfs)
$null = Get-PureVeeamUnstructuredServer -Name 'asked-for' -InformationVariable info 6>$null
Assert-Equal 'prefers Name when set' ([bool](($info -join ' ') -match "source '172\.16\.16\.15:/lab-nfs'")) 'True'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Remove-PureFADirectorySnapshotMatch'
function New-SnapFixture {
	@(
		[pscustomobject]@{ Name = 'dir.Veeam.Backup20260817093153'; Id = 'id-new';  Destroyed = $false }
		[pscustomobject]@{ Name = 'dir.Veeam.Backup20260816093153'; Id = 'id-old';  Destroyed = $false }
		[pscustomobject]@{ Name = 'dir.Veeam.Backup20260815093153'; Id = 'id-gone'; Destroyed = $true }
		[pscustomobject]@{ Name = 'dir.policy-snap-0001';           Id = 'id-other'; Destroyed = $false }
	)
}
$pattern = 'Veeam\.Backup\d{14}'

$global:SnapshotFixture = New-SnapFixture; $global:DestroyCalls = @()
$result = Remove-PureFADirectorySnapshotMatch -Array 'fake' -SnapDirectory 'dir' -MatchPattern $pattern 6>$null
Assert-Equal 'matched only our pattern'   $result.Matched 3
Assert-Equal 'destroyed the two live'     $result.Destroyed 2
Assert-Equal 'counted already-destroyed'  $result.AlreadyDestroyed 1
Assert-Equal 'kept nothing'               $result.Kept 0
Assert-Equal 'left the policy snapshot alone' ($global:DestroyCalls -contains 'id-other') 'False'
Assert-Equal 'destroy calls'              ($global:DestroyCalls -join ',') 'id-new,id-old'

$global:SnapshotFixture = New-SnapFixture; $global:DestroyCalls = @()
$result = Remove-PureFADirectorySnapshotMatch -Array 'fake' -SnapDirectory 'dir' -MatchPattern $pattern `
	-ExcludeName 'Veeam.Backup20260817093153' 6>$null
Assert-Equal 'exclude by client-visible tail keeps it' $result.Kept 1
Assert-Equal 'exclude leaves only the older one'       ($global:DestroyCalls -join ',') 'id-old'

$global:SnapshotFixture = New-SnapFixture; $global:DestroyCalls = @()
$result = Remove-PureFADirectorySnapshotMatch -Array 'fake' -SnapDirectory 'dir' -MatchPattern $pattern `
	-ExcludeName 'dir.Veeam.Backup20260817093153' 6>$null
Assert-Equal 'exclude by full name also works' $result.Kept 1

$global:SnapshotFixture = New-SnapFixture; $global:DestroyCalls = @()
$result = Remove-PureFADirectorySnapshotMatch -Array 'fake' -SnapDirectory 'dir' -MatchPattern $pattern -WhatIf 6>$null
Assert-Equal 'WhatIf destroys nothing' $global:DestroyCalls.Count 0
Assert-Equal 'WhatIf still reports matches' $result.Matched 3

$global:SnapshotFixture = @(); $global:DestroyCalls = @()
$result = Remove-PureFADirectorySnapshotMatch -Array 'fake' -SnapDirectory 'dir' -MatchPattern $pattern 6>$null
Assert-Equal 'no snapshots at all' $result.Matched 0

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Resolve-PureVeeamSetting: precedence'
$cfg = [pscustomobject]@{ Endpoint = 'from-config'; IgnoreCertificateError = $true; SnapLifetime = '48h' }
Assert-Equal 'parameter beats config' (Resolve-PureVeeamSetting -Name 'Endpoint' -Bound @{ Endpoint = 'from-param' } -Config $cfg -EnvName 'T_EP' -Default 'from-default') 'from-param'
Assert-Equal 'config beats env'       (Resolve-PureVeeamSetting -Name 'Endpoint' -Bound @{} -Config $cfg -EnvName 'T_EP' -Default 'from-default') 'from-config'
$env:T_EP = 'from-env'
Assert-Equal 'env beats default'      (Resolve-PureVeeamSetting -Name 'Absent' -Bound @{} -Config $cfg -EnvName 'T_EP' -Default 'from-default') 'from-env'
Remove-Item Env:T_EP
Assert-Equal 'default is last resort' (Resolve-PureVeeamSetting -Name 'Absent' -Bound @{} -Config $cfg -EnvName 'T_EP' -Default 'from-default') 'from-default'
Assert-Equal 'null when nothing supplies a value' ($null -eq (Resolve-PureVeeamSetting -Name 'Absent' -Bound @{} -Config $cfg)) 'True'
Assert-Throws 'Required throws a named error' { Resolve-PureVeeamSetting -Name 'Absent' -Bound @{} -Config $cfg -EnvName 'T_EP' -Required } "Required setting 'Absent' was not supplied"

# The trap this guards against: an unbound [switch] must not override a 'true' in the config.
Assert-Equal 'unbound switch keeps config true' ([bool](Resolve-PureVeeamSetting -Name 'IgnoreCertificateError' -Bound @{} -Config $cfg -Default $false)) 'True'
Assert-Equal 'explicitly bound $false wins'     ([bool](Resolve-PureVeeamSetting -Name 'IgnoreCertificateError' -Bound @{ IgnoreCertificateError = [switch]$false } -Config $cfg -Default $true)) 'False'
Assert-Equal 'string value from config'         (Resolve-PureVeeamSetting -Name 'SnapLifetime' -Bound @{} -Config $cfg -Default '7d') '48h'
$cfgEmpty = [pscustomobject]@{ Endpoint = '' }
Assert-Equal 'empty config value falls through' (Resolve-PureVeeamSetting -Name 'Endpoint' -Bound @{} -Config $cfgEmpty -Default 'from-default') 'from-default'

# Regression: $PSBoundParameters is a PSBoundParametersDictionary, which implements
# IDictionary.Contains explicitly, so only ContainsKey is callable on it. A Hashtable stand-in
# hides that difference, so exercise the real type.
function Test-RealBoundParameters {
	param([string] $Endpoint, [switch] $IgnoreCertificateError)
	Resolve-PureVeeamSetting -Name 'Endpoint' -Bound $PSBoundParameters -Config $cfg -Default 'from-default'
}
Assert-Equal 'real $PSBoundParameters, bound'   (Test-RealBoundParameters -Endpoint 'from-real-param') 'from-real-param'
Assert-Equal 'real $PSBoundParameters, unbound' (Test-RealBoundParameters) 'from-config'

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Get-PureVeeamConfig'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('faveeam-cfg-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
	Assert-Equal 'absent default config is not an error' ($null -eq (Get-PureVeeamConfig -ScriptRoot $tmp)) 'True'
	Assert-Throws 'explicit missing config throws' { Get-PureVeeamConfig -Path (Join-Path $tmp 'nope.json') } 'was not found'
	'{ "Endpoint": "cfg-host" }' | Set-Content (Join-Path $tmp 'fa-veeam-config.json')
	Assert-Equal 'default config file is picked up' (Get-PureVeeamConfig -ScriptRoot $tmp 6>$null).Endpoint 'cfg-host'
	'{ not json' | Set-Content (Join-Path $tmp 'bad.json')
	Assert-Throws 'malformed JSON throws' { Get-PureVeeamConfig -Path (Join-Path $tmp 'bad.json') 6>$null } 'could not be read as JSON'

	# Comments. ConvertFrom-Json accepts // and /* */ but not #, verified on 7.4 and 7.6. The
	# sample configuration relies on this, so a future parser change has to fail here.
	@'
// leading comment
{
	/* block */
	"Endpoint": "commented-host", // trailing comment
	"FileSharePath": "https://not-a-comment/share"
}
'@ | Set-Content (Join-Path $tmp 'commented.json')
	$commented = Get-PureVeeamConfig -Path (Join-Path $tmp 'commented.json') 6>$null
	Assert-Equal '// and /* */ comments are accepted' $commented.Endpoint 'commented-host'
	# Proof that comments are not stripped by hand: naive stripping would truncate this at '//'.
	Assert-Equal 'a // inside a value survives' $commented.FileSharePath 'https://not-a-comment/share'

	'{ "Endpoint": "x" # nope' + [Environment]::NewLine + '}' | Set-Content (Join-Path $tmp 'hash.json')
	Assert-Throws '# comments are rejected, not silently ignored' {
		Get-PureVeeamConfig -Path (Join-Path $tmp 'hash.json') 6>$null
	} 'could not be read as JSON'

	# The resolved path is recorded on the object, because Get-PureVeeamConfig runs before
	# Start-Transcript and so its own console message never reaches the log.
	$loaded = Get-PureVeeamConfig -ScriptRoot $tmp 6>$null
	Assert-Equal 'resolved config path is recorded' $loaded.PureVeeamConfigPath (Join-Path $tmp 'fa-veeam-config.json')

	# Veeam launches job scripts with an unpredictable working directory, so a relative path that
	# misses the working directory is retried next to the script.
	'{ "Endpoint": "fallback-host" }' | Set-Content (Join-Path $tmp 'side.json')
	$pushed = Get-Location
	Set-Location ([System.IO.Path]::GetTempPath())
	try {
		$loaded = Get-PureVeeamConfig -Path 'side.json' -ScriptRoot $tmp 3>$null 6>$null
		Assert-Equal 'relative path falls back to the script directory' $loaded.Endpoint 'fallback-host'
		Assert-Throws 'both locations named when neither exists' {
			Get-PureVeeamConfig -Path 'absent.json' -ScriptRoot $tmp 3>$null 6>$null
		} "Tried 'absent.json' and "
	} finally {
		Set-Location $pushed
	}

	Write-TestSection 'API token resolution'
	$clixml = Join-Path $tmp 'tok.clixml'
	ConvertTo-SecureString 'super-secret-token' -AsPlainText -Force | Export-Clixml -Path $clixml
	$secure = Unprotect-PureVeeamSecret -Path $clixml 6>$null
	Assert-Equal 'CliXml SecureString round-trip' ([System.Net.NetworkCredential]::new('', $secure).Password) 'super-secret-token'

	$credXml = Join-Path $tmp 'cred.clixml'
	[pscredential]::new('pureuser', (ConvertTo-SecureString 'cred-token' -AsPlainText -Force)) | Export-Clixml -Path $credXml
	$secure = Unprotect-PureVeeamSecret -Path $credXml 6>$null
	Assert-Equal 'CliXml PSCredential round-trip' ([System.Net.NetworkCredential]::new('', $secure).Password) 'cred-token'

	Assert-Throws 'missing token file' { Unprotect-PureVeeamSecret -Path (Join-Path $tmp 'nope.apitoken') } 'was not found'
	Set-Content -Path (Join-Path $tmp 'empty.apitoken') -Value '' -NoNewline
	Assert-Throws 'empty token file' { Unprotect-PureVeeamSecret -Path (Join-Path $tmp 'empty.apitoken') } 'is empty'

	$secure = Get-PureFAApiToken -ApiTokenFile $clixml 6>$null
	Assert-Equal 'token from file' ([System.Net.NetworkCredential]::new('', $secure).Password) 'super-secret-token'
	$env:PUREFA_API_TOKEN = 'env-token'
	$secure = Get-PureFAApiToken -ApiTokenFile $clixml 3>$null 6>$null
	Assert-Equal 'env beats file' ([System.Net.NetworkCredential]::new('', $secure).Password) 'env-token'
	$secure = Get-PureFAApiToken -ApiToken (ConvertTo-SecureString 'param-token' -AsPlainText -Force) -ApiTokenFile $clixml 3>$null 6>$null
	Assert-Equal 'parameter beats env' ([System.Net.NetworkCredential]::new('', $secure).Password) 'param-token'
	Remove-Item Env:PUREFA_API_TOKEN
	$secure = Get-PureFAApiToken -Config ([pscustomobject]@{ ApiTokenFile = $clixml }) 6>$null
	Assert-Equal 'token file named in config' ([System.Net.NetworkCredential]::new('', $secure).Password) 'super-secret-token'
	Assert-Equal 'no source returns null' ($null -eq (Get-PureFAApiToken -Config ([pscustomobject]@{}) 6>$null)) 'True'

	Write-TestSection 'DPAPI round-trip (Windows only)'
	if (Test-IsWindowsHost) {
		$dpapi = Join-Path $tmp 'fa01.apitoken'
		Protect-PureVeeamSecret -Secret (ConvertTo-SecureString 'dpapi-token' -AsPlainText -Force) -Path $dpapi 6>$null
		$secure = Unprotect-PureVeeamSecret -Path $dpapi 6>$null
		Assert-Equal 'LocalMachine DPAPI round-trip' ([System.Net.NetworkCredential]::new('', $secure).Password) 'dpapi-token'
		Assert-Equal 'blob is not CliXml' ([bool]((Get-Content -LiteralPath $dpapi -Raw) -like '*<Objs*')) 'False'
		Assert-Throws 'empty token rejected' { Protect-PureVeeamSecret -Secret (New-Object System.Security.SecureString) -Path $dpapi } 'is empty'
	} else {
		Write-TestSkipped 'LocalMachine DPAPI round-trip' 'requires Windows'
	}

	Write-TestSection 'Connect-PureFAArray'
	Assert-Throws 'no credentials at all' { Connect-PureFAArray -Endpoint 'fa01' } 'No FlashArray credentials are available'

	Write-TestSection 'Get-PureVeeamVBRCredential'
	Assert-Equal 'nothing configured returns null' ($null -eq (Get-PureVeeamVBRCredential 6>$null)) 'True'

	$vbrPassword = Join-Path $tmp 'vbr.clixml'
	ConvertTo-SecureString 'vbr-secret' -AsPlainText -Force | Export-Clixml -Path $vbrPassword
	$cred = Get-PureVeeamVBRCredential -UserName 'HOST\veeam-automation' -PasswordFile $vbrPassword 6>$null
	Assert-Equal 'user name is carried through' $cred.UserName 'HOST\veeam-automation'
	Assert-Equal 'password is decrypted'        $cred.GetNetworkCredential().Password 'vbr-secret'

	$explicit = [pscredential]::new('HOST\other', (ConvertTo-SecureString 'x' -AsPlainText -Force))
	$cred = Get-PureVeeamVBRCredential -Credential $explicit -UserName 'HOST\veeam-automation' -PasswordFile $vbrPassword 6>$null
	Assert-Equal 'explicit credential wins' $cred.UserName 'HOST\other'

	Assert-Throws 'password file without a user name' {
		Get-PureVeeamVBRCredential -PasswordFile $vbrPassword 6>$null
	} 'no user name'
	Assert-Throws 'user name without a password file' {
		Get-PureVeeamVBRCredential -UserName 'HOST\veeam-automation' 6>$null
	} 'no password'

	# Veeam requires DOMAIN\Username or UPN format, so a bare name is worth warning about.
	$warnings = @()
	$cred = Get-PureVeeamVBRCredential -UserName 'veeam-automation' -PasswordFile $vbrPassword -WarningVariable warnings -WarningAction SilentlyContinue 6>$null
	Assert-Equal 'bare user name still builds a credential' $cred.UserName 'veeam-automation'
	Assert-Equal 'bare user name warns about the format' ([bool](($warnings -join ' ') -match 'DOMAIN.Username or UPN')) 'True'

	Write-TestSection 'Test-PureVeeamTcpPort'
    # Port 1 on a loopback address: nothing listens there, and it fails fast.
	Assert-Equal 'closed port reports false' (Test-PureVeeamTcpPort -ComputerName '127.0.0.1' -Port 1 -TimeoutMilliseconds 2000) 'False'
	Assert-Equal 'unresolvable host reports false' (Test-PureVeeamTcpPort -ComputerName 'no-such-host.invalid' -Port 443 -TimeoutMilliseconds 2000) 'False'
	$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
	$listener.Start()
	try {
		$boundPort = $listener.LocalEndpoint.Port
		Assert-Equal 'listening port reports true' (Test-PureVeeamTcpPort -ComputerName '127.0.0.1' -Port $boundPort -TimeoutMilliseconds 2000) 'True'
	} finally {
		$listener.Stop()
	}

	Write-TestSection 'Start-PureVeeamLog: profile-based transcript names'
	$logDir = Join-Path $tmp 'log'
	$scriptPath = Join-Path $tmp 'fa-file-veeam-snapshot-pre-backup.ps1'
	$pre = Start-PureVeeamLog -ScriptPath $scriptPath -Phase 'pre' `
		-ConfigPath (Join-Path $tmp 'mucfa75-nas.json') -LogDirectory $logDir -RetentionDays 0 6>$null
	Stop-PureVeeamLog
	Assert-Equal 'name is <profile>-<timestamp>-pre.log' `
		([bool]((Split-Path -Leaf $pre) -match '^mucfa75-nas-\d{14}-pre\.log$')) 'True'

	$post = Start-PureVeeamLog -ScriptPath $scriptPath -Phase 'post' `
		-ConfigPath (Join-Path $tmp 'mucfa75-nas.json') -LogDirectory $logDir -RetentionDays 0 6>$null
	Stop-PureVeeamLog
	Assert-Equal 'post phase is in the name' `
		([bool]((Split-Path -Leaf $post) -match '^mucfa75-nas-\d{14}-post\.log$')) 'True'

	$noProfile = Start-PureVeeamLog -ScriptPath $scriptPath -Phase 'pre' -LogDirectory $logDir -RetentionDays 0 6>$null
	Stop-PureVeeamLog
	Assert-Equal 'no config file falls back to default' `
		([bool]((Split-Path -Leaf $noProfile) -match '^default-\d{14}-pre\.log$')) 'True'

	# A plain alphabetical sort has to group a profile and interleave its phases by run time.
	$names = @('b-prof-20260101000000-pre.log', 'a-prof-20260102000000-post.log',
		'a-prof-20260101000000-pre.log') | Sort-Object
	Assert-Equal 'sorting groups by profile then run time' ($names -join ' ') `
		'a-prof-20260101000000-pre.log a-prof-20260102000000-post.log b-prof-20260101000000-pre.log'

	Assert-Throws 'phase is constrained' {
		Start-PureVeeamLog -ScriptPath $scriptPath -Phase 'middle' -LogDirectory $logDir 6>$null
	} 'ValidateSet|does not belong'

	Write-TestSection 'Test-PureVeeamTlsTrust'
	# Never trusted, never a hang: both failure shapes must return promptly with Trusted false,
	# because the caller only refuses to connect on a completed-but-untrusted result.
	$closed = Test-PureVeeamTlsTrust -ComputerName '127.0.0.1' -Port 1 -TimeoutMilliseconds 2000
	Assert-Equal 'closed port does not complete' $closed.Completed 'False'
	Assert-Equal 'closed port is not trusted'    $closed.Trusted   'False'
	Assert-Equal 'closed port explains why'      ([bool]$closed.Detail) 'True'

	$unresolvable = Test-PureVeeamTlsTrust -ComputerName 'no-such-host.invalid' -Port 443 -TimeoutMilliseconds 2000
	Assert-Equal 'unresolvable host does not complete' $unresolvable.Completed 'False'

	# A listener that accepts the socket but speaks no TLS: the handshake must fail rather than
	# block, otherwise the probe would reproduce the very hang it exists to prevent.
	$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
	$listener.Start()
	try {
		$mute = Test-PureVeeamTlsTrust -ComputerName '127.0.0.1' -Port $listener.LocalEndpoint.Port -TimeoutMilliseconds 2000
		Assert-Equal 'non-TLS listener does not complete' $mute.Completed 'False'
		Assert-Equal 'non-TLS listener is not trusted'    $mute.Trusted   'False'
	} finally {
		$listener.Stop()
	}
} finally {
	Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$counters = Get-TestCounters
Write-Host ''
Write-Host '---------------------------------------'
Write-Host "PureVeeamFA unit tests -- passed: $($counters.Passed)  failed: $($counters.Failed)  skipped: $($counters.Skipped)"
if ($counters.Failed -gt 0) { exit 1 }
exit 0
