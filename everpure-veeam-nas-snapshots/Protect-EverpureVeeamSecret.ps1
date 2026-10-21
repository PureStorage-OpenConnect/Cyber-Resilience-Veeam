# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#  Disclaimer
	The sample script and documentation are provided AS IS and are not supported by
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
	Stores an array API token or the Veeam password in a protected file, and optionally
	verifies it against the array or the backup server.

.DESCRIPTION
	Windows: the secret is encrypted with DPAPI at LocalMachine scope and the file ACL is
	restricted to SYSTEM and Administrators, so the Veeam Backup Service (LOCAL SYSTEM) can read
	what an administrator wrote. Linux (Veeam Software Appliance): the secret is written as a
	plain file with mode 0640 and group veeam-grp-data, which is the group of the account that
	runs job scripts in the sandbox. On both platforms the file permissions are the real
	boundary; see the README.

	Run it once per array (SecretType ArrayApiToken) and, if an explicit Veeam user is
	configured, once for its password (SecretType VeeamPassword). The secret is prompted for
	unless -Secret is given, so it never appears in a command line or shell history.

.PARAMETER Path
	Destination file, typically secrets/<array>.token or secrets/vbr.pwd beside the job
	configuration files.

.PARAMETER SecretType
	ArrayApiToken (default) or VeeamPassword.

.PARAMETER Secret
	The secret as a SecureString. Prompted for when omitted.

.PARAMETER Endpoint
	Array management address, required with -Verify for an API token.

.PARAMETER Tls
	TLS policy for the verification call: skip (default), system, or thumbprint:<hex>.

.PARAMETER Verify
	After writing, log in to the array (or Veeam, with -VBRUser) to prove the secret works.

.PARAMETER VerifyOnly
	Verify an existing file without rewriting it. Run this under the Veeam service account
	(psexec -s pwsh ...) to prove that account can read the file.

.PARAMETER VBRUser
	Veeam user name for the VeeamPassword verification.

.PARAMETER VBRServer
	Veeam server for the VeeamPassword verification. Defaults to localhost.

.PARAMETER Force
	Overwrite an existing file without asking.

.EXAMPLE
	.\Protect-EverpureVeeamSecret.ps1 -Path .\jobs\secrets\fa01.token -Endpoint fa01.lab.local -Verify

.EXAMPLE
	.\Protect-EverpureVeeamSecret.ps1 -Path .\jobs\secrets\vbr.pwd -SecretType VeeamPassword -VBRUser 'VBR01\veeam-automation' -Verify
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Path',
	Justification = 'Path is the destination file for the protected secret, not a password.')]
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[Parameter(Mandatory)] [string] $Path,
	[ValidateSet('ArrayApiToken', 'VeeamPassword')] [string] $SecretType = 'ArrayApiToken',
	[System.Security.SecureString] $Secret,
	[string] $Endpoint,
	[string] $Tls = 'skip',
	[switch] $Verify,
	[switch] $VerifyOnly,
	[string] $VBRUser,
	[string] $VBRServer = 'localhost',
	[switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1') -Force -ErrorAction Stop
$platform = Get-EvpPlatform
$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
$isToken = ($SecretType -eq 'ArrayApiToken')

if (($Verify -or $VerifyOnly) -and $isToken -and -not $Endpoint) { throw 'Specify -Endpoint with -Verify or -VerifyOnly so the token can be tested against the array.' }
if (($Verify -or $VerifyOnly) -and -not $isToken -and -not $VBRUser) { throw 'Specify -VBRUser with -Verify or -VerifyOnly so the password can be tested against Veeam.' }

Write-Host ''
Write-Host "Secret type : $SecretType"
Write-Host "File        : $fullPath"
Write-Host "Platform    : $($platform.Name), running as $($platform.Identity)"
Write-Host ''

if (-not $VerifyOnly) {
	if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and -not $Force) {
		$answer = Read-Host "File '$fullPath' exists. Overwrite? [y/N]"
		if ($answer -notmatch '^[Yy]') { throw 'Aborted; the existing file was left untouched. Use -Force to overwrite, or -VerifyOnly to test it.' }
	}
	if (-not $Secret) {
		$prompt = if ($isToken) { "API token$(if ($Endpoint) { " for '$Endpoint'" })" } else { "Veeam password$(if ($VBRUser) { " for '$VBRUser'" })" }
		$Secret = Read-Host -Prompt $prompt -AsSecureString
	}
	if (-not $Secret -or $Secret.Length -eq 0) { throw 'No secret was supplied.' }
	Protect-EvpSecret -Secret $Secret -Path $fullPath -Platform $platform
}

$report = Test-EvpSecretFile -Path $fullPath -Platform $platform
Write-Host "Protection  : $($report.Protection)"
Write-Host "Permissions : $($report.Permissions)"
foreach ($w in $report.Warnings) { Write-Warning $w }

if ($Verify -or $VerifyOnly) {
	Write-Host ''
	Initialize-EvpEnvironment -Platform $platform -WritableDirectory (Split-Path -Parent $fullPath)
	$stored = Unprotect-EvpSecret -Path $fullPath -Platform $platform
	if ($isToken) {
		$arrayConfig = [ordered]@{ Name = $Endpoint; Endpoint = $Endpoint; ApiTokenFile = $fullPath; Platform = 'auto'; Tls = $Tls }
		$session = Connect-EvpArray -ArrayConfig $arrayConfig -ApiToken $stored
		Write-Host ''
		Write-Host "Verification succeeded: $($session.Platform) '$($session.ArrayName)', Purity $($session.PurityVersion), REST $($session.ApiVersion)."
	} else {
		$config = [ordered]@{ Veeam = [ordered]@{ Backend = 'PowerShell'; Server = $VBRServer; Port = 9419; User = $VBRUser; PasswordFile = $fullPath; Tls = $Tls; ForceAcceptTlsCertificate = $true; ApiVersion = '1.3-rev2'; AcknowledgeRestDefect = $false } }
		if (-not (Test-EvpVeeamModule)) { $config.Veeam.Backend = 'Rest' }
		$session = Connect-EvpVeeam -Config $config -Platform $platform
		$shares = Get-EvpVeeamShares -Session $session
		Disconnect-EvpVeeam -Session $session
		Write-Host ''
		Write-Host "Verification succeeded: '$VBRUser' can see $($shares.Count) SMB/NFS share(s) through the $($session.Backend) backend."
	}
	if ($platform.IsWindows) {
		Write-Host 'Confirm the Veeam service account can read the file too: psexec -s pwsh -File .\Protect-EverpureVeeamSecret.ps1 -Path ... -VerifyOnly ...'
	}
}

Write-Host ''
if ($isToken) { Write-Host "Next: reference this file from the job configuration as Arrays[].ApiTokenFile (relative to the config file or absolute)." }
else { Write-Host "Next: set Veeam.User to '$VBRUser' and Veeam.PasswordFile to this file in the job configuration." }
