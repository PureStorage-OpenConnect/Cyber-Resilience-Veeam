# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#  Disclaimer
    The sample module and documentation are provided AS IS and are not supported by
	the author or the author's employer, unless otherwise agreed in writing. You bear
	all risk relating to the use or performance of the sample script and documentation.
	The author and the author's employer disclaim all express or implied warranties
	(including, without limitation, any warranties of merchantability, title, infringement
	or fitness for a particular purpose). In no event shall the author, the author's employer
	or anyone else involved in the creation, production, or delivery of the scripts be liable
	for any damages whatsoever arising out of the use or performance of the sample script and
	documentation (including, without limitation, damages for loss of business profits,
	business interruption, loss of business information, or other pecuniary loss), even if
	such person has been advised of the possibility of such damages. #>

<#
.SYNOPSIS
	Veeam pre-backup script: snapshots a FlashArray File Managed Directory and points the Veeam
	file share at the new snapshot path. Works for both SMB shares and NFS exports.

.DESCRIPTION
	Backing up a share or export from a snapshot gives a consistent point in time and works
	around locked or open files.

	The script creates a FlashArray File Managed Directory snapshot named
	'<ClientName>.<SuffixPrefix><timestamp>' (by default 'Veeam.Backup20260817093153'), then
	updates the Veeam inventory entry for the share so the job reads from
	'<share>\.snapshot\<snapshot name>' (SMB) or '<export>/.snapshot/<snapshot name>' (NFS).

	The correct Veeam cmdlet is chosen from the type of the inventory object, so the same script
	handles SMB shares (VBRNASSMBServer) and NFS exports (VBRNASNFSServer). The share is looked
	up with Get-VBRUnstructuredServer, which replaced the obsolete Get-VBRNASServer in Veeam
	Backup & Replication 12.1.

	No credentials or endpoints are stored in this file. Every setting is resolved from, in order
	of precedence: an explicit parameter, the JSON configuration file, an environment variable,
	then the built-in default. Authentication uses a FlashArray API token held as a SecureString
	and read from an encrypted file created by fa-veeam-credential-setup.ps1.

	Prerequisites:
	  Install-Module -Name PureStoragePowerShellSDK2 -Scope AllUsers
	  .\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken

.PARAMETER ConfigFile
	Path to the JSON configuration file. Defaults to the FA_VEEAM_CONFIG environment variable,
	then 'fa-veeam-config.json' beside this script. Use one configuration file per file share.

.PARAMETER Endpoint
	FlashArray management IP address or FQDN. Config key 'Endpoint', environment variable
	PUREFA_ENDPOINT.

.PARAMETER ApiToken
	FlashArray API token as a SecureString. Normally left unset in favour of ApiTokenFile.

.PARAMETER ApiTokenFile
	Path to the encrypted API token file. Config key 'ApiTokenFile', environment variable
	PUREFA_API_TOKEN_FILE.

.PARAMETER Credential
	FlashArray user name and password, used only when no API token is available.

.PARAMETER SnapDirectory
	Managed Directory as shown in the FlashArray directory list, for example
	'user-shares01::user-shares01:lab-files'. Config key 'SnapDirectory', environment variable
	PUREFA_SNAP_DIRECTORY.

.PARAMETER FileSharePath
	File share name exactly as it appears in the Veeam inventory, for example
	'\\172.16.16.15\lab-files' (SMB) or '172.16.16.15:/lab-files' (NFS). Config key
	'FileSharePath', environment variable VEEAM_FILE_SHARE_PATH.

.PARAMETER SnapClientName
	FlashArray snapshot client name, the part before the dot. Defaults to 'Veeam'.

.PARAMETER SnapSuffixPrefix
	Text placed before the timestamp in the snapshot suffix. Defaults to 'Backup'.

.PARAMETER SnapLifetime
	How long the array keeps the snapshot, as a duration: '7d', '48h', '1d12h', '6h30m', '90m'.
	Defaults to '7d'. Use 'none' for no expiry.

	This is a safety net, not the primary cleanup mechanism -- the post-backup script destroys the
	snapshot after the job. It matters when that script does not run, for instance because the job
	was cancelled or the Veeam service restarted, so snapshots do not accumulate unnoticed.

	FlashArray accepts 5m to 365d for this value; anything else is rejected before the array is
	contacted.

.PARAMETER SnapshotMatchPattern
	Regular expression identifying snapshots created by this script. Only used by -SweepOrphans.
	The default 'Veeam\.Backup\d{14}' matches the names this script produces with the default
	SnapClientName and SnapSuffixPrefix; change all three together.

.PARAMETER SweepOrphans
	After successfully pointing Veeam at the new snapshot, destroy any older snapshot matching
	SnapshotMatchPattern. With the default lifecycle the post-backup script has already removed
	the previous one, so a match here is a leftover from a run whose cleanup never completed.

.PARAMETER NoFailSafePath
	Disable the fail-safe described in the notes below, leaving the share's storage snapshot path
	untouched when this script fails.

.PARAMETER SnapshotRootDirName
	Snapshot root directory on the share. Defaults to '.snapshot'.

.PARAMETER IgnoreCertificateError
	Skip FlashArray TLS certificate validation. Defaults to true.

.PARAMETER SetProcessingModeStorageSnapshot
	Also force the share's processing mode to StorageSnapshot. Off by default, leaving the mode
	configured in the Veeam console untouched.

.PARAMETER VBRServer
	Veeam Backup & Replication server to open a PowerShell session against. Defaults to
	localhost.

.PARAMETER VBRUser
	Veeam user name, in DOMAIN\Username or UPN format -- HOSTNAME\Username on a workgroup server.
	Config key 'VBRUser'.

	Veeam runs job scripts as the Veeam Backup Service account, which defaults to LOCAL SYSTEM and
	so presents as the machine account. Veeam accepts only local and domain user accounts for
	authentication, so a machine account can be granted no role and cannot connect. Set this and
	VBRPasswordFile to a dedicated user holding a Veeam role.

	Leave both unset to connect with the inherited identity, which works only where the Veeam
	Backup Service already runs as a user account with a Veeam role.

.PARAMETER VBRPasswordFile
	Path to the encrypted password file for VBRUser, created by fa-veeam-credential-setup.ps1.
	Config key 'VBRPasswordFile'.

.PARAMETER VBRCredential
	A complete PSCredential for Veeam, taking precedence over VBRUser and VBRPasswordFile.

.PARAMETER ForceAcceptTlsCertificate
	Accept the backup server's TLS certificate without validating it. Defaults to true, because a
	stock Veeam installation presents a self-signed certificate and Connect-VBRServer otherwise
	prompts to accept it -- a prompt nobody can answer when the Veeam Backup Service runs the
	script. Pass -ForceAcceptTlsCertificate:$false, or set the config key to false, to validate the
	certificate instead. Config key 'ForceAcceptTlsCertificate'.

.PARAMETER LogDirectory
	Transcript directory. Defaults to a 'log' folder beside this script.

.PARAMETER LogRetentionDays
	Delete this script's transcripts older than this many days. 0 disables pruning.

.EXAMPLE
	.\fa-file-veeam-snapshot-pre-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json

	Normal unattended use. Wire this command into the Veeam job's pre-job script setting.

.EXAMPLE
	.\fa-file-veeam-snapshot-pre-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json -WhatIf

	Dry run. Reports the snapshot it would create and the path it would set, and changes nothing.

.EXAMPLE
	.\fa-file-veeam-snapshot-pre-backup.ps1 -Endpoint fa01.lab.local `
		-ApiTokenFile C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken `
		-SnapDirectory 'user-shares01::user-shares01:lab-files' `
		-FileSharePath '172.16.16.15:/lab-files'

	Fully parameterised, no configuration file, against an NFS export.

.EXAMPLE
	.\fa-file-veeam-snapshot-pre-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json `
		-SnapLifetime '48h' -SweepOrphans

	Two-day snapshot lifetime, and clean up any snapshot left behind by an earlier run whose
	post-backup script did not complete.

.NOTES
	While this is a fully functional script, it is intended as a starting point for someone with
	PowerShell skills to adapt to their environment.

	Fail-safe on error: if this script fails after it has resolved the file share, it points the
	share's storage snapshot path at a deliberately non-existent snapshot before exiting non-zero.

	The reason is that Veeam does not necessarily abort a job when a pre-job script fails. Without
	this, a failed run could leave the share pointing at the previous run's snapshot, and the job
	would quietly back up stale data and report success. A path that cannot be read turns that
	silent staleness into a visible job failure. Disable it with -NoFailSafePath.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'VBRPasswordFile',
	Justification = 'VBRPasswordFile is a filesystem path, not a password. The password itself is only ever held as a SecureString.')]
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[string] $ConfigFile,
	[string] $Endpoint,
	[System.Security.SecureString] $ApiToken,
	[string] $ApiTokenFile,
	[System.Management.Automation.PSCredential] $Credential,
	[string] $SnapDirectory,
	[string] $FileSharePath,
	[string] $SnapClientName = 'Veeam',
	[string] $SnapSuffixPrefix = 'Backup',
	[string] $SnapLifetime = '7d',
	[string] $SnapshotMatchPattern = 'Veeam\.Backup\d{14}',
	[switch] $SweepOrphans,
	[switch] $NoFailSafePath,
	[string] $SnapshotRootDirName = '.snapshot',
	[switch] $IgnoreCertificateError,
	[switch] $SetProcessingModeStorageSnapshot,
	[string] $VBRServer = 'localhost',
	[string] $VBRUser,
	[string] $VBRPasswordFile,
	[System.Management.Automation.PSCredential] $VBRCredential,
	[switch] $ForceAcceptTlsCertificate,
	[string] $LogDirectory,
	[int] $LogRetentionDays = 30
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'PureVeeamFA.psm1') -Force -ErrorAction Stop
Import-Module -Name 'PureStoragePowerShellSDK2' -ErrorAction Stop

$config = Get-PureVeeamConfig -Path $ConfigFile -ScriptRoot $PSScriptRoot

$logDirectoryValue = Resolve-PureVeeamSetting -Name 'LogDirectory' -Bound $PSBoundParameters -Config $config -EnvName 'FA_VEEAM_LOG_DIR' -Default $LogDirectory
$logRetentionValue = [int](Resolve-PureVeeamSetting -Name 'LogRetentionDays' -Bound $PSBoundParameters -Config $config -EnvName 'FA_VEEAM_LOG_RETENTION_DAYS' -Default $LogRetentionDays)

# The profile name in the transcript file name comes from this. $config is $null when the run is
# configured entirely from parameters and the environment.
$configPathValue = if ($config) { $config.PureVeeamConfigPath } else { $null }

$null = Start-PureVeeamLog -ScriptPath $PSCommandPath -Phase 'pre' -ConfigPath $configPathValue `
	-LogDirectory $logDirectoryValue -RetentionDays $logRetentionValue

# Declared before the try so the fail-safe in the catch can tell how far the run got.
$nasServer = $null
$fileSharePathValue = $null
$snapshotRootValue = '.snapshot'

try {
	# Resolve every setting before touching anything, so a misconfiguration fails fast.
	$endpointValue = Resolve-PureVeeamSetting -Name 'Endpoint' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_ENDPOINT' -Required
	$snapDirectoryValue = Resolve-PureVeeamSetting -Name 'SnapDirectory' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_SNAP_DIRECTORY' -Required
	$fileSharePathValue = Resolve-PureVeeamSetting -Name 'FileSharePath' -Bound $PSBoundParameters -Config $config -EnvName 'VEEAM_FILE_SHARE_PATH' -Required
	$apiTokenFileValue = Resolve-PureVeeamSetting -Name 'ApiTokenFile' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_API_TOKEN_FILE' -Default $ApiTokenFile
	$snapClientNameValue = Resolve-PureVeeamSetting -Name 'SnapClientName' -Bound $PSBoundParameters -Config $config -Default $SnapClientName
	$snapSuffixPrefixValue = Resolve-PureVeeamSetting -Name 'SnapSuffixPrefix' -Bound $PSBoundParameters -Config $config -Default $SnapSuffixPrefix
	$snapLifetimeValue = Resolve-PureVeeamSetting -Name 'SnapLifetime' -Bound $PSBoundParameters -Config $config -Default $SnapLifetime
	$matchPatternValue = Resolve-PureVeeamSetting -Name 'SnapshotMatchPattern' -Bound $PSBoundParameters -Config $config -Default $SnapshotMatchPattern
	$sweepOrphansValue = [bool](Resolve-PureVeeamSetting -Name 'SweepOrphans' -Bound $PSBoundParameters -Config $config -Default $false)
	$noFailSafeValue = [bool](Resolve-PureVeeamSetting -Name 'NoFailSafePath' -Bound $PSBoundParameters -Config $config -Default $false)
	$snapshotRootValue = Resolve-PureVeeamSetting -Name 'SnapshotRootDirName' -Bound $PSBoundParameters -Config $config -Default $SnapshotRootDirName
	$ignoreCertValue = [bool](Resolve-PureVeeamSetting -Name 'IgnoreCertificateError' -Bound $PSBoundParameters -Config $config -Default $true)
	$setProcessingModeValue = [bool](Resolve-PureVeeamSetting -Name 'SetProcessingModeStorageSnapshot' -Bound $PSBoundParameters -Config $config -Default $false)
	$vbrServerValue = Resolve-PureVeeamSetting -Name 'VBRServer' -Bound $PSBoundParameters -Config $config -Default $VBRServer
	$vbrUserValue = Resolve-PureVeeamSetting -Name 'VBRUser' -Bound $PSBoundParameters -Config $config -EnvName 'VEEAM_VBR_USER' -Default $VBRUser
	$vbrPasswordFileValue = Resolve-PureVeeamSetting -Name 'VBRPasswordFile' -Bound $PSBoundParameters -Config $config -EnvName 'VEEAM_VBR_PASSWORD_FILE' -Default $VBRPasswordFile
	$forceTlsValue = [bool](Resolve-PureVeeamSetting -Name 'ForceAcceptTlsCertificate' -Bound $PSBoundParameters -Config $config -Default $true)

	# Reject a malformed lifetime before contacting anything.
	$keepForMs = ConvertTo-PureVeeamKeepFor -Duration $snapLifetimeValue

	$snapSuffix = '{0}{1}' -f $snapSuffixPrefixValue, (Get-Date -Format 'yyyyMMddHHmmss')
	$snapshotName = '{0}.{1}' -f $snapClientNameValue, $snapSuffix

	if ($keepForMs -gt 0) {
		$lifetimeDescription = '{0} ({1} ms)' -f [TimeSpan]::FromMilliseconds($keepForMs).ToString(), $keepForMs
	} else {
		$lifetimeDescription = 'no expiry (relies on the post-backup script for cleanup)'
	}

	$configDescription = 'none (parameters and environment only)'
	if ($config -and $config.PureVeeamConfigPath) { $configDescription = $config.PureVeeamConfigPath }

	Write-Host ''
	Write-Host "Configuration file : $configDescription"
	Write-Host "FlashArray         : $endpointValue"
	Write-Host "Managed Directory  : $snapDirectoryValue"
	Write-Host "Veeam file share   : $fileSharePathValue"
	Write-Host "Snapshot to create : $snapDirectoryValue.$snapshotName"
	Write-Host "Snapshot lifetime  : $lifetimeDescription"
	Write-Host ''

	# Resolve the Veeam share first: a typo in the share name should not leave an orphan
	# snapshot behind on the array.
	$vbrCredentialValue = Get-PureVeeamVBRCredential -Credential $VBRCredential -UserName $vbrUserValue -PasswordFile $vbrPasswordFileValue
	Connect-PureVeeamBackupServer -Server $vbrServerValue `
		-Credential $vbrCredentialValue `
		-ForceAcceptTlsCertificate:$forceTlsValue
	$nasServer = Get-PureVeeamUnstructuredServer -Name $fileSharePathValue

	$token = Get-PureFAApiToken -ApiToken $ApiToken -ApiTokenFile $apiTokenFileValue -Config $config
	$flashArray = Connect-PureFAArray -Endpoint $endpointValue -ApiToken $token -Credential $Credential -IgnoreCertificateError $ignoreCertValue

	$newSnapshotParams = @{
		Array       = $flashArray
		SourceNames = $snapDirectoryValue
		ClientName  = $snapClientNameValue
		Suffix      = $snapSuffix
		ErrorAction = 'Stop'
	}
	# KeepFor is optional on the array; omitting it means the snapshot never expires.
	if ($keepForMs -gt 0) { $newSnapshotParams['KeepFor'] = $keepForMs }

	Write-Host "Creating FlashArray File directory snapshot '$snapDirectoryValue.$snapshotName'..."
	if ($PSCmdlet.ShouldProcess("$endpointValue/$snapDirectoryValue", "New-Pfa2DirectorySnapshot -Suffix '$snapSuffix'")) {
		$directorySnapshot = New-Pfa2DirectorySnapshot @newSnapshotParams
		Write-Host "Created snapshot '$($directorySnapshot.Name)'."
	} else {
		Write-Host 'Skipped snapshot creation (-WhatIf); continuing to show the resulting Veeam configuration.'
	}

	# -WhatIf must be forwarded explicitly to every module function that changes something:
	# $WhatIfPreference does not cross the module boundary on PowerShell 7.4, so without this a
	# dry run really repoints the file share.
	$appliedPath = Set-PureVeeamStorageSnapshotPath -Server $nasServer `
		-SnapshotName $snapshotName `
		-SharePath $fileSharePathValue `
		-SnapshotRootDirName $snapshotRootValue `
		-SetProcessingModeStorageSnapshot:$setProcessingModeValue `
		-WhatIf:$WhatIfPreference

	# Only sweep once Veeam is pointed at the new snapshot, so a failure above never leaves the
	# share pointing at something this script has just destroyed.
	if ($sweepOrphansValue) {
		Write-Host ''
		Write-Host "Sweeping snapshots matching '$matchPatternValue' left over from earlier runs..."
		$sweep = Remove-PureFADirectorySnapshotMatch -Array $flashArray `
			-SnapDirectory $snapDirectoryValue `
			-MatchPattern $matchPatternValue `
			-ExcludeName $snapshotName `
			-WhatIf:$WhatIfPreference
		Write-Host "Sweep result: matched $($sweep.Matched), destroyed $($sweep.Destroyed), already destroyed $($sweep.AlreadyDestroyed), kept $($sweep.Kept)."
	}

	Write-Host ''
	Write-Host "Pre-backup script completed. Veeam will read '$fileSharePathValue' from '$appliedPath'."
	$exitCode = 0
} catch {
	Write-Host ''
	Write-Host "Pre-backup script FAILED: $($_.Exception.Message)"
	Write-Host $_.ScriptStackTrace
	$exitCode = 1

	# Veeam does not necessarily abort a job when its pre-job script fails. Leaving the share
	# pointed at the previous run's snapshot would let the job quietly back up stale data and
	# report success, so make the path unreadable instead and turn that into a visible failure.
	if ($nasServer -and -not $noFailSafeValue) {
		try {
			$sentinel = '__veeam-pre-backup-failed-{0}__' -f (Get-Date -Format 'yyyyMMddHHmmss')
			$null = Set-PureVeeamStorageSnapshotPath -Server $nasServer `
				-SnapshotName $sentinel `
				-SharePath $fileSharePathValue `
				-SnapshotRootDirName $snapshotRootValue `
				-WhatIf:$WhatIfPreference
			Write-Host "Fail-safe applied: the share now points at a non-existent snapshot path, so the job will fail rather than back up stale data. Re-run this script successfully to restore it."
		} catch {
			Write-Warning "Could not apply the fail-safe snapshot path: $($_.Exception.Message)"
			Write-Warning 'Check the share''s storage snapshot path manually before the next job run; it may still point at an older snapshot.'
		}
	}
} finally {
	Stop-PureVeeamLog
}

exit $exitCode
