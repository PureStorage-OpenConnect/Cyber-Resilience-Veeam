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
	Everpure NAS backup-from-snapshot helpers for Veeam Backup & Replication 13.1.

	One code base for FlashArray File and FlashBlade, SMB and NFS, Windows backup servers and
	the Veeam Software Appliance. PowerShell 7 and REST only: no Pure SDK module and, on the
	appliance, no Veeam module. The layers in lib/ are dot-sourced here in dependency order.

	Set-StrictMode is deliberately off: Veeam inventory objects and REST documents vary between
	releases, and a strict-mode failure on a missing property would hide the descriptive errors.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

$script:EvpModuleRoot = $PSScriptRoot

# The manifest is the single source of the version (semantic versioning, see CHANGELOG.md). It
# is read from the file rather than from the loaded module object so the value is right even
# when the .psm1 is imported directly, as older installations and ad-hoc sessions do.
$script:EvpVersion = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1')).ModuleVersion

# Module functions run with the module's own preference, not the caller's. Without this a .NET
# method exception (file access denied, for example) is written and execution carries on, which
# produced a transcript saying "Wrote secret" after the write had failed.
$ErrorActionPreference = 'Stop'

foreach ($layer in 'Common', 'Secrets', 'Logging', 'Http', 'Veeam', 'Pure', 'Discovery', 'Orchestrate') {
	. (Join-Path $PSScriptRoot 'lib' "$layer.ps1")
}

function Get-EvpModuleRoot {
	<# Install root of this module, used for the default log directory on Windows. #>
	[CmdletBinding()]
	[OutputType([string])]
	param()
	return $script:EvpModuleRoot
}

function Get-EvpVersion {
	<# Version of these scripts, as declared in EverpureVeeamNas.psd1 (MAJOR.MINOR.PATCH). #>
	[CmdletBinding()]
	[OutputType([string])]
	param()
	return $script:EvpVersion
}

Export-ModuleMember -Function @(
	# Common
	'Get-EvpPlatform', 'Initialize-EvpEnvironment', 'Get-EvpConfig', 'Read-EvpArraysFile', 'Add-EvpArraysFileEntry','New-EvpShareRecord', 'ConvertTo-EvpMilliseconds',
	'Get-EvpShareProtocol', 'Split-EvpSharePath', 'Get-EvpNormalizedSharePath', 'Get-EvpStorageSnapshotPath',
	'Get-EvpTimestamp', 'Get-EvpDefaultSnapshotTag', 'New-EvpSnapshotName', 'Get-EvpSnapshotMatchPattern', 'Get-EvpSnapshotTimestamp', 'Get-EvpSentinelDirectoryName',
	# Secrets
	'ConvertFrom-EvpSecureString', 'Assert-EvpSecretWriter', 'Protect-EvpSecret', 'Unprotect-EvpSecret', 'Test-EvpSecretFile',
	# Logging
	'Get-EvpDefaultLogDirectory', 'Start-EvpLog', 'Stop-EvpLog', 'Write-EvpSection',
	# Http
	'Set-EvpHttpInvoker', 'Invoke-EvpHttp', 'Get-EvpHttpErrorText', 'Get-EvpServerCertificateHash',
	# Veeam
	'Connect-EvpVeeam', 'Disconnect-EvpVeeam', 'Test-EvpVeeamModule', 'Get-EvpVeeamShares', 'Find-EvpVeeamShare', 'Set-EvpVeeamStorageSnapshotPath',
	'Get-EvpVeeamJob', 'Find-EvpVeeamJobByName', 'Get-EvpVeeamActiveJobSessions', 'Assert-EvpVeeamJobSession',
	# Pure
	'Connect-EvpArray', 'Invoke-EvpArrayApi', 'Get-EvpArrayFileInterfaces', 'Get-EvpFleetMemberSessions','Resolve-EvpArraySource', 'New-EvpArraySnapshot', 'Get-EvpArraySnapshots', 'Remove-EvpArraySnapshots',
	# Discovery
	'Get-EvpRunShares', 'Resolve-EvpShareHostAddress', 'New-EvpArrayPool', 'Expand-EvpFleets', 'Get-EvpArrayNames', 'Open-EvpArraySession', 'Connect-EvpArraysForShares', 'Get-EvpDefaultStateDirectory', 'Get-EvpStatePath',
	'Read-EvpState', 'Get-EvpCachedShareArray', 'Get-EvpOrphanSources', 'Invoke-EvpOrphanCleanup', 'Save-EvpState',
	# Orchestrate
	'Get-EvpExitCodeTable', 'Write-EvpPlan', 'Invoke-EvpPrePhase', 'Invoke-EvpPostPhase', 'Invoke-EvpVerifyPhase',
	'Get-EvpModuleRoot', 'Get-EvpVersion'
)
