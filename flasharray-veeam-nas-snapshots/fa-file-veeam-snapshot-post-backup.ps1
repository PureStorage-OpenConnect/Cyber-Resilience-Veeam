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

# Warning!!! This script will DESTROY snapshots.
# Use At Your Own Risk!

<#
.SYNOPSIS
	Veeam post-backup script: destroys the FlashArray File Managed Directory snapshots created by
	fa-file-veeam-snapshot-pre-backup.ps1.

.DESCRIPTION
	This script is optional. The pre-backup script gives every snapshot a lifespan, so snapshots
	can simply be left to expire instead.

	Snapshots are marked destroyed but are not eradicated, so they remain on the array for the
	duration of the eradication delay. Every snapshot on the Managed Directory whose name matches
	SnapshotMatchPattern is destroyed, so a run also sweeps up leftovers from earlier runs whose
	cleanup never completed.

	No credentials or endpoints are stored in this file. Every setting is resolved from, in order
	of precedence: an explicit parameter, the JSON configuration file, an environment variable,
	then the built-in default. Authentication uses a FlashArray API token held as a SecureString
	and read from an encrypted file created by fa-veeam-credential-setup.ps1.

	Note that after this script runs, the Veeam file share configuration still points at the
	now-destroyed snapshot path until the next successful pre-backup run.

	Prerequisites:
	  Install-Module -Name PureStoragePowerShellSDK2 -Scope AllUsers
	  .\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken

.PARAMETER ConfigFile
	Path to the JSON configuration file. Defaults to the FA_VEEAM_CONFIG environment variable,
	then 'fa-veeam-config.json' beside this script.

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

.PARAMETER SnapshotMatchPattern
	Regular expression matched against snapshot names. The default 'Veeam\.Backup\d{14}' matches
	the client name 'Veeam' plus the suffix 'Backup' plus a 14-digit timestamp, as produced by
	fa-file-veeam-snapshot-pre-backup.ps1.

.PARAMETER FailIfNoSnapshots
	Exit with code 1 when nothing matches. Off by default: finding nothing to clean up is a
	normal outcome once a snapshot has aged out through its lifespan, and failing the Veeam job
	over it is misleading.

.PARAMETER IgnoreCertificateError
	Skip FlashArray TLS certificate validation. Defaults to true.

.PARAMETER LogDirectory
	Transcript directory. Defaults to a 'log' folder beside this script.

.PARAMETER LogRetentionDays
	Delete this script's transcripts older than this many days. 0 disables pruning.

.EXAMPLE
	.\fa-file-veeam-snapshot-post-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json

	Normal unattended use. Wire this command into the Veeam job's post-job script setting.

.EXAMPLE
	.\fa-file-veeam-snapshot-post-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json -WhatIf

	Lists the snapshots that would be destroyed without destroying any of them.

.NOTES
	While this is a fully functional script, it is intended as a starting point for someone with
	PowerShell skills to adapt to their environment.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[string] $ConfigFile,
	[string] $Endpoint,
	[System.Security.SecureString] $ApiToken,
	[string] $ApiTokenFile,
	[System.Management.Automation.PSCredential] $Credential,
	[string] $SnapDirectory,
	[string] $SnapshotMatchPattern = 'Veeam\.Backup\d{14}',
	[switch] $FailIfNoSnapshots,
	[switch] $IgnoreCertificateError,
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

$null = Start-PureVeeamLog -ScriptPath $PSCommandPath -Phase 'post' -ConfigPath $configPathValue `
	-LogDirectory $logDirectoryValue -RetentionDays $logRetentionValue

try {
	$endpointValue = Resolve-PureVeeamSetting -Name 'Endpoint' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_ENDPOINT' -Required
	$snapDirectoryValue = Resolve-PureVeeamSetting -Name 'SnapDirectory' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_SNAP_DIRECTORY' -Required
	$apiTokenFileValue = Resolve-PureVeeamSetting -Name 'ApiTokenFile' -Bound $PSBoundParameters -Config $config -EnvName 'PUREFA_API_TOKEN_FILE' -Default $ApiTokenFile
	$matchPatternValue = Resolve-PureVeeamSetting -Name 'SnapshotMatchPattern' -Bound $PSBoundParameters -Config $config -Default $SnapshotMatchPattern
	$failIfNoneValue = [bool](Resolve-PureVeeamSetting -Name 'FailIfNoSnapshots' -Bound $PSBoundParameters -Config $config -Default $false)
	$ignoreCertValue = [bool](Resolve-PureVeeamSetting -Name 'IgnoreCertificateError' -Bound $PSBoundParameters -Config $config -Default $true)

	$configDescription = 'none (parameters and environment only)'
	if ($config -and $config.PureVeeamConfigPath) { $configDescription = $config.PureVeeamConfigPath }

	Write-Host ''
	Write-Host "Configuration file : $configDescription"
	Write-Host "FlashArray         : $endpointValue"
	Write-Host "Managed Directory  : $snapDirectoryValue"
	Write-Host "Snapshot pattern   : $matchPatternValue"
	Write-Host ''

	$token = Get-PureFAApiToken -ApiToken $ApiToken -ApiTokenFile $apiTokenFileValue -Config $config
	$flashArray = Connect-PureFAArray -Endpoint $endpointValue -ApiToken $token -Credential $Credential -IgnoreCertificateError $ignoreCertValue

	Write-Host "Retrieving directory snapshots for '$snapDirectoryValue'..."
	# Destroys every match, so a run also sweeps up snapshots left by earlier runs whose cleanup
	# never completed.
	# -WhatIf is forwarded explicitly: $WhatIfPreference does not cross the module boundary on
	# PowerShell 7.4, so without this a dry run would really destroy snapshots.
	$result = Remove-PureFADirectorySnapshotMatch -Array $flashArray `
		-SnapDirectory $snapDirectoryValue `
		-MatchPattern $matchPatternValue `
		-WhatIf:$WhatIfPreference

	if ($result.Matched -eq 0) {
		$message = "Found no directory snapshots on '$snapDirectoryValue' matching '$matchPatternValue'. Nothing to clean up."
		if ($failIfNoneValue) {
			throw $message
		}
		# Not an error: the pre-backup snapshot may simply have aged out through its lifetime,
		# and failing the Veeam job over that would be misleading.
		Write-Warning $message
	} else {
		Write-Host ''
		Write-Host "Destroyed: $($result.Destroyed). Already destroyed: $($result.AlreadyDestroyed)."
		Write-Host 'Destroyed snapshots remain recoverable until the array eradication delay expires.'
	}

	Write-Host 'Post-backup script completed.'
	$exitCode = 0
} catch {
	Write-Host ''
	Write-Host "Post-backup script FAILED: $($_.Exception.Message)"
	Write-Host $_.ScriptStackTrace
	$exitCode = 1
} finally {
	Stop-PureVeeamLog
}

exit $exitCode
