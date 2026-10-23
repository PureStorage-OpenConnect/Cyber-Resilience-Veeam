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

	Windows: run from an elevated PowerShell (Run as administrator). The ACL leaves only SYSTEM
	and Administrators, and a non-elevated session carries a UAC-filtered token in which the
	Administrators group is deny-only. Such a session could write the file but never read it
	back, so the helper refuses it before asking for the secret and writes nothing. -VerifyOnly
	in a non-elevated session fails with access denied. Linux: no root needed to verify; the owner can read the 0640
	file. Only chgrp veeam-grp-data needs root or membership in that group (a warning is
	printed when it fails).

	For array API tokens, name the array: -Array fa01 -Endpoint fa01.example.com adds the array to
	jobs/arrays.jsonc (creating the file if needed, token file secrets/fa01.token), prompts for its
	token, stores it and verifies it against the array. Without -Endpoint, -Array takes the token
	file, endpoint and TLS policy of an array already in the file, for example to replace its
	token. -Array * does that for every array in the file. -Path with -Endpoint still works, and is the
	form for the Veeam password of an explicit Veeam user (SecretType VeeamPassword). The secret
	is prompted for unless -Secret is given, so it never appears in a command line or shell
	history.

.PARAMETER Array
	Name of one or more arrays in the arrays file, or * for all of them. The token file path,
	endpoint and TLS policy come from there. Verifies by default (see -NoVerify).

.PARAMETER ArraysFile
	Arrays file for -Array. Defaults to jobs/arrays.jsonc beside this script.

.PARAMETER NoVerify
	With -Array: store the token without logging in to the array, for an array that is not
	reachable from here yet.

.PARAMETER Path
	Destination file, typically jobs/secrets/<array>.token or jobs/secrets/vbr.pwd.

.PARAMETER SecretType
	ArrayApiToken (default) or VeeamPassword.

.PARAMETER Secret
	The secret as a SecureString. Prompted for when omitted. Only with a single target.

.PARAMETER Endpoint
	Array management address. With -Array: adds the array to the arrays file if it is not there
	yet (an existing entry with another endpoint is an error; edit the file to change it). With
	-Path: required with -Verify for an API token.

.PARAMETER Tls
	TLS policy: skip (default), system, or thumbprint:<hex>. With -Array -Endpoint it is written
	into the new entry; with -Path it applies to the verification call.

.PARAMETER Verify
	With -Path: after writing, log in to the array (or Veeam, with -VBRUser) to prove the secret
	works. -Array always verifies unless -NoVerify is given.

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
	.\Protect-EverpureVeeamSecret.ps1 -Array fa01 -Endpoint fa01.example.com

	Adds fa01 to jobs\arrays.jsonc, prompts for its API token, stores it in
	jobs\secrets\fa01.token and logs in to the array to prove it works.

.EXAMPLE
	.\Protect-EverpureVeeamSecret.ps1 -Array fa01

	Replaces the token of fa01, an array already in jobs\arrays.jsonc.

.EXAMPLE
	psexec -s pwsh -File .\Protect-EverpureVeeamSecret.ps1 -Array * -VerifyOnly

	Proves that the Veeam service account can read and use every array's token.

.EXAMPLE
	.\Protect-EverpureVeeamSecret.ps1 -Path .\jobs\secrets\fa01.token -Endpoint fa01.example.com -Verify

.EXAMPLE
	.\Protect-EverpureVeeamSecret.ps1 -Path .\jobs\secrets\vbr.pwd -SecretType VeeamPassword -VBRUser 'VBR01\veeam-automation' -Verify
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Path',
	Justification = 'Path is the destination file for the protected secret, not a password.')]
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false, DefaultParameterSetName = 'Path')]
param(
	[Parameter(Mandatory, ParameterSetName = 'Array')] [string[]] $Array,
	[Parameter(ParameterSetName = 'Array')] [string] $ArraysFile,
	[Parameter(ParameterSetName = 'Array')] [switch] $NoVerify,
	[Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
	[Parameter(ParameterSetName = 'Path')] [ValidateSet('ArrayApiToken', 'VeeamPassword')] [string] $SecretType = 'ArrayApiToken',
	[string] $Endpoint,
	[ValidatePattern('^(skip|system|thumbprint:([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}))$')] [string] $Tls = 'skip',
	[Parameter(ParameterSetName = 'Path')] [switch] $Verify,
	[Parameter(ParameterSetName = 'Path')] [string] $VBRUser,
	[Parameter(ParameterSetName = 'Path')] [string] $VBRServer = 'localhost',
	[System.Security.SecureString] $Secret,
	[switch] $VerifyOnly,
	[switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1') -Force -ErrorAction Stop
$platform = Get-EvpPlatform
$byArray = ($PSCmdlet.ParameterSetName -eq 'Array')
$isToken = $byArray -or ($SecretType -eq 'ArrayApiToken')

# What to write: one entry per array from the arrays file, or the one file named by -Path.
if ($byArray) {
	$arraysPath = if ($ArraysFile) { $ArraysFile } else { Join-Path (Join-Path $PSScriptRoot 'jobs') 'arrays.jsonc' }
	$arraysPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($arraysPath)
	# -Endpoint: add the array to the arrays file first (creating the file from the sample).
	if ($Endpoint) {
		if ($Array.Count -ne 1 -or $Array[0] -eq '*') { throw '-Endpoint adds one array: give exactly one name with -Array.' }
		if ($VerifyOnly) { throw '-Endpoint adds an array and stores its token; -VerifyOnly only tests an existing token. Leave one of them out.' }
		# Before anything is written: a session that cannot write the token must not add the array either.
		Assert-EvpSecretWriter -Platform $platform
		if (-not (Test-Path -LiteralPath $arraysPath -PathType Leaf)) {
			$null = New-Item -ItemType Directory -Path (Split-Path -Parent $arraysPath) -Force
			Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'arrays.sample.jsonc') -Destination $arraysPath
			Write-Host "Created '$arraysPath' from arrays.sample.jsonc."
		}
		$existing = (Read-EvpArraysFile -Path $arraysPath)[$Array[0]]
		if (-not $existing) {
			Add-EvpArraysFileEntry -Path $arraysPath -Name $Array[0] -Endpoint $Endpoint -Tls $Tls
			Write-Host "Added array '$($Array[0])' ($Endpoint) to '$arraysPath', token file secrets/$($Array[0]).token."
		} elseif ($existing.Endpoint -ne $Endpoint) {
			throw "Array '$($Array[0])' is already in '$arraysPath' with endpoint '$($existing.Endpoint)'. Edit the entry there, or leave -Endpoint out to store its token."
		} else {
			Write-Host "Array '$($Array[0])' is already in '$arraysPath' with this endpoint."
		}
	}
	$defined = Read-EvpArraysFile -Path $arraysPath
	if ($defined.Count -eq 0) { throw "The arrays file '$arraysPath' lists no arrays yet. Add one with -Array <name> -Endpoint <management address>." }
	$names = if ($Array -contains '*') { @($defined.Keys) } else { $Array }
	$unknown = @($names | Where-Object { -not $defined.Contains($_) })
	if ($unknown.Count) { throw "Not in '$arraysPath': $($unknown -join ', '). Arrays defined there: $($defined.Keys -join ', '). Add one with -Array <name> -Endpoint <management address>." }
	$targets = @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Path = $defined[$_].ApiTokenFile; Endpoint = $defined[$_].Endpoint; Tls = $defined[$_].Tls } })
	$doVerify = -not $NoVerify
} else {
	$targets = @([pscustomobject]@{ Name = $Endpoint; Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path); Endpoint = $Endpoint; Tls = $Tls })
	$doVerify = $Verify -or $VerifyOnly
	if ($doVerify -and $isToken -and -not $Endpoint) { throw 'Specify -Endpoint with -Verify or -VerifyOnly so the token can be tested against the array, or use -Array <name> to take it from arrays.jsonc.' }
	if ($doVerify -and -not $isToken -and -not $VBRUser) { throw 'Specify -VBRUser with -Verify or -VerifyOnly so the password can be tested against Veeam.' }
}
if ($VerifyOnly) { $doVerify = $true }
if ($Secret -and $targets.Count -gt 1) { throw '-Secret can only be given for a single array; leave it out to be prompted for each.' }

# Before the overwrite question and the secret prompt, not after them.
if (-not $VerifyOnly) { Assert-EvpSecretWriter -Platform $platform }

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($t in $targets) {
	Write-Host ''
	Write-Host "Secret type : $(if ($isToken) { 'ArrayApiToken' } else { 'VeeamPassword' })"
	if ($byArray) { Write-Host "Array       : $($t.Name) ($($t.Endpoint))" }
	Write-Host "File        : $($t.Path)"
	Write-Host "Platform    : $($platform.Name), running as $($platform.Identity)$(if ($platform.IsWindows) { $(if ($platform.IsElevated) { ' (elevated)' } else { ' (not elevated)' }) })"
	Write-Host ''
	try {
		if (-not $VerifyOnly) {
			if ((Test-Path -LiteralPath $t.Path -PathType Leaf) -and -not $Force) {
				$answer = Read-Host "File '$($t.Path)' exists. Overwrite? [y/N]"
				if ($answer -notmatch '^[Yy]') { throw 'Aborted; the existing file was left untouched. Use -Force to overwrite, or -VerifyOnly to test it.' }
			}
			$value = $Secret
			if (-not $value) {
				$prompt = if ($isToken) { "API token$(if ($t.Endpoint) { " for '$($t.Endpoint)'" })" } else { "Veeam password$(if ($VBRUser) { " for '$VBRUser'" })" }
				$value = Read-Host -Prompt $prompt -AsSecureString
			}
			if (-not $value -or $value.Length -eq 0) { throw 'No secret was supplied.' }
			Protect-EvpSecret -Secret $value -Path $t.Path -Platform $platform
		}

		$report = Test-EvpSecretFile -Path $t.Path -Platform $platform
		Write-Host "Protection  : $($report.Protection)"
		Write-Host "Permissions : $($report.Permissions)"
		foreach ($w in $report.Warnings) { Write-Warning $w }

		if ($doVerify) {
			Write-Host ''
			Initialize-EvpEnvironment -Platform $platform -WritableDirectory (Split-Path -Parent $t.Path)
			$stored = Unprotect-EvpSecret -Path $t.Path -Platform $platform
			if ($isToken) {
				$arrayConfig = [ordered]@{ Name = $t.Name; Endpoint = $t.Endpoint; ApiTokenFile = $t.Path; Platform = 'auto'; Tls = $t.Tls }
				$session = Connect-EvpArray -ArrayConfig $arrayConfig -ApiToken $stored
				Write-Host ''
				Write-Host "Verification succeeded: $($session.Platform) '$($session.ArrayName)', Purity $($session.PurityVersion), REST $($session.ApiVersion)."
				if ($t.Tls -eq 'skip') {
					try {
						$hash = Get-EvpServerCertificateHash -ComputerName $t.Endpoint
						Write-Host "Certificate : SHA-256 $hash"
						Write-Host "              Compare it with the certificate shown on the array, then pin it with"
						Write-Host "              `"Tls`": `"thumbprint:$hash`" in this array's entry in arrays.jsonc so the token cannot be intercepted."
					} catch { Write-Warning $_.Exception.Message }
				}
			} else {
				$config = [ordered]@{ Veeam = [ordered]@{ Backend = 'PowerShell'; Server = $VBRServer; Port = 9419; User = $VBRUser; PasswordFile = $t.Path; Tls = $Tls; ForceAcceptTlsCertificate = $true; ApiVersion = '1.3-rev2'; AcknowledgeRestDefect = $false } }
				if (-not (Test-EvpVeeamModule)) { $config.Veeam.Backend = 'Rest' }
				$session = Connect-EvpVeeam -Config $config -Platform $platform
				$shares = Get-EvpVeeamShares -Session $session
				Disconnect-EvpVeeam -Session $session
				Write-Host ''
				Write-Host "Verification succeeded: '$VBRUser' can see $($shares.Count) SMB/NFS share(s) through the $($session.Backend) backend."
			}
		}
	} catch {
		if ($targets.Count -eq 1) { throw }
		Write-Warning "$($t.Name): $($_.Exception.Message)"
		$failed.Add($t.Name)
	}
}

Write-Host ''
if ($doVerify -and $platform.IsWindows -and -not $VerifyOnly) {
	$how = if ($byArray) { "-Array $($Array -join ',') -VerifyOnly" } else { '-Path ... -VerifyOnly ...' }
	Write-Host "Confirm the Veeam service account can read the file too: psexec -s pwsh -File .\Protect-EverpureVeeamSecret.ps1 $how"
}
if ($failed.Count) { throw "$($failed.Count) of $($targets.Count) array(s) failed: $($failed -join ', '). See the warnings above." }
if ($byArray) { Write-Host 'Done. The job configurations find the token through arrays.jsonc; nothing else to set.' }
elseif ($isToken) { Write-Host "Next: reference this file as ApiTokenFile of the array in jobs\arrays.jsonc (relative to that file's folder, or absolute). Next time -Array <name> takes path and endpoint from there." }
else { Write-Host "Next: set Veeam.User to '$VBRUser' and Veeam.PasswordFile to this file in the job configuration." }
