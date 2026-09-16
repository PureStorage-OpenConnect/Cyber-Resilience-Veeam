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
	One-time helper that encrypts a secret to a file for the FlashArray File pre/post backup
	scripts, and optionally verifies it works.

.DESCRIPTION
	Handles the two secrets these scripts need, selected with -SecretType:

	  FlashArrayApiToken  the FlashArray API token             (both scripts)
	  VeeamPassword       the password for a Veeam user account (pre-backup script only)

	The Veeam password is needed because Veeam runs job scripts as the Veeam Backup Service
	account, which defaults to LOCAL SYSTEM and therefore presents as the machine account. Veeam
	accepts only local and domain user accounts for authentication, so a machine account can be
	granted no role and cannot connect. Give the pre-backup script a dedicated Veeam user instead.

	Run this on the Veeam Backup & Replication server. It prompts for the secret, encrypts it with
	Windows DPAPI at LocalMachine scope, and hardens the file ACL.

	LocalMachine scope is deliberate: Veeam runs pre/post job scripts as the Veeam Backup Service
	account, frequently LOCAL SYSTEM, which is not the account an administrator uses to run this
	helper. A CurrentUser-scope blob would be undecryptable by that service account.

	The consequence is that the file ACL, not the encryption scope, is the real security
	boundary. By default this script disables ACL inheritance and grants Full Control to
	NT AUTHORITY\SYSTEM and BUILTIN\Administrators only.

	Get an API token from the FlashArray GUI under Settings > Users and Policies > Users, or from
	the CLI with 'pureadmin create --api-token <user>'. Use a dedicated account with the least
	privilege that still allows creating and destroying Managed Directory snapshots.

.PARAMETER Path
	Destination for the encrypted file, for example 'C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken'.

.PARAMETER SecretType
	Which secret this file holds: 'FlashArrayApiToken' (default) or 'VeeamPassword'.

.PARAMETER Secret
	The secret as a SecureString. Omit to be prompted, which keeps it out of the shell history and
	the process command line.

.PARAMETER Endpoint
	FlashArray management IP address or FQDN. Required with -Verify for a FlashArrayApiToken.

.PARAMETER VBRUser
	Veeam user name in DOMAIN\Username or UPN format -- HOSTNAME\Username on a workgroup server.
	Required with -Verify for a VeeamPassword.

.PARAMETER VBRServer
	Veeam Backup & Replication server used when verifying a VeeamPassword. Defaults to localhost.

.PARAMETER ForceAcceptTlsCertificate
	Accept the backup server's TLS certificate without validating it when verifying a
	VeeamPassword. Defaults to true, matching the pre-backup script. Pass
	-ForceAcceptTlsCertificate:$false to validate it instead.

.PARAMETER Verify
	After writing the file, decrypt it and open a real connection to -Endpoint. Prints the array
	name only, never the token.

.PARAMETER VerifyOnly
	Verify an existing token file without writing a new one.

.PARAMETER IgnoreCertificateError
	Skip FlashArray TLS certificate validation during -Verify. Defaults to true.

.PARAMETER SkipAclHardening
	Leave the file ACL as inherited from the parent directory. Only sensible when the directory
	is already restricted appropriately.

.PARAMETER Force
	Overwrite an existing token file without prompting.

.EXAMPLE
	.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken

	Prompts for the FlashArray API token, writes the encrypted file and hardens its ACL.

.EXAMPLE
	.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken -Endpoint fa01.lab.local -Verify

	Writes the API token, then proves it decrypts and connects to the array.

.EXAMPLE
	.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\vbr.pwd -SecretType VeeamPassword `
		-VBRUser 'CXC-VEEAM-VBR\veeam-automation' -Verify

	Writes the Veeam password, then proves it opens a Veeam session and can read the inventory.

.EXAMPLE
	.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken -Endpoint fa01.lab.local -VerifyOnly

	Verifies an existing file without rewriting it. Run this under the Veeam Backup Service account
	to confirm that account can read it, for example:
	  psexec -s -i pwsh.exe -File .\fa-veeam-credential-setup.ps1 -Path ... -VerifyOnly ...

.NOTES
	While this is a fully functional script, it is intended as a starting point for someone with
	PowerShell skills to adapt to their environment.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Path',
	Justification = 'Path is the destination file for the encrypted secret, not a password.')]
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[Parameter(Mandatory)] [string] $Path,
	[ValidateSet('FlashArrayApiToken', 'VeeamPassword')] [string] $SecretType = 'FlashArrayApiToken',
	[System.Security.SecureString] $Secret,
	[string] $Endpoint,
	[string] $VBRUser,
	[string] $VBRServer = 'localhost',
	[bool] $ForceAcceptTlsCertificate = $true,
	[switch] $Verify,
	[switch] $VerifyOnly,
	[bool] $IgnoreCertificateError = $true,
	[switch] $SkipAclHardening,
	[switch] $Force
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'PureVeeamFA.psm1') -Force -ErrorAction Stop

if (-not ($env:OS -eq 'Windows_NT' -or [System.Environment]::OSVersion.Platform -eq 'Win32NT')) {
	throw 'This helper writes a Windows DPAPI-protected file and runs on Windows only.'
}

$isApiToken = ($SecretType -eq 'FlashArrayApiToken')

if ($Verify -or $VerifyOnly) {
	if ($isApiToken -and -not $Endpoint) {
		throw 'Specify -Endpoint together with -Verify or -VerifyOnly so the API token can be tested against the array.'
	}
	if (-not $isApiToken -and -not $VBRUser) {
		throw 'Specify -VBRUser together with -Verify or -VerifyOnly so the password can be tested against Veeam.'
	}
}

$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

Write-Host ''
Write-Host "Secret type      : $SecretType"
Write-Host "Encrypted file   : $fullPath"
Write-Host "Current identity : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host ''

if (-not $VerifyOnly) {
	if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and -not $Force) {
		$answer = Read-Host "File '$fullPath' already exists. Overwrite? [y/N]"
		if ($answer -notmatch '^[Yy]') {
			throw 'Aborted; the existing file was left untouched. Use -Force to overwrite without prompting, or -VerifyOnly to test it.'
		}
	}

	if (-not $Secret) {
		if ($isApiToken) {
			$prompt = 'FlashArray API token'
			if ($Endpoint) { $prompt = "FlashArray API token for '$Endpoint'" }
		} else {
			$prompt = 'Veeam password'
			if ($VBRUser) { $prompt = "Veeam password for '$VBRUser'" }
		}
		$Secret = Read-Host -Prompt $prompt -AsSecureString
	}
	if (-not $Secret -or $Secret.Length -eq 0) {
		throw 'No secret was supplied.'
	}

	$parentDir = Split-Path -Parent $fullPath
	if ($parentDir -and -not (Test-Path -LiteralPath $parentDir -PathType Container)) {
		if ($PSCmdlet.ShouldProcess($parentDir, 'Create directory')) {
			New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
		}
	}

	Protect-PureVeeamSecret -Secret $Secret -Path $fullPath

	if ($SkipAclHardening) {
		Write-Warning 'ACL hardening skipped. Because the secret is protected at LocalMachine scope, any account able to read this file can decrypt it -- restrict the parent directory yourself.'
	} elseif ($PSCmdlet.ShouldProcess($fullPath, 'Restrict ACL to SYSTEM and Administrators')) {
		try {
			$acl = [System.Security.AccessControl.FileSecurity]::new()
			# Disable inheritance and drop the inherited rules rather than copying them.
			$acl.SetAccessRuleProtection($true, $false)
			foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
				$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
					$identity, 'FullControl', 'Allow'))
			}
			Set-Acl -LiteralPath $fullPath -AclObject $acl
			Write-Host 'ACL restricted to NT AUTHORITY\SYSTEM and BUILTIN\Administrators.'
			(Get-Acl -LiteralPath $fullPath).Access |
				Select-Object -Property IdentityReference, FileSystemRights, AccessControlType |
				Format-Table -AutoSize | Out-String | Write-Host
		} catch {
			Write-Warning "Could not harden the ACL on '$fullPath': $($_.Exception.Message)"
			Write-Warning 'Restrict access to this file manually. At LocalMachine DPAPI scope, read access is equivalent to knowing the secret.'
		}
	}
}

if ($Verify -or $VerifyOnly) {
	Write-Host ''
	if ($isApiToken) {
		Write-Host "Verifying '$fullPath' against FlashArray '$Endpoint'..."
		Import-Module -Name 'PureStoragePowerShellSDK2' -ErrorAction Stop

		$token = Unprotect-PureVeeamSecret -Path $fullPath
		$array = Connect-PureFAArray -Endpoint $Endpoint -ApiToken $token -IgnoreCertificateError $IgnoreCertificateError
		$arrayInfo = Get-Pfa2Array -Array $array -ErrorAction Stop

		Write-Host ''
		Write-Host "Verification succeeded. Array name: $($arrayInfo.Name), Purity version: $($arrayInfo.Version)"
	} else {
		Write-Host "Verifying '$fullPath' by connecting to Veeam server '$VBRServer' as '$VBRUser'..."

		$credential = Get-PureVeeamVBRCredential -UserName $VBRUser -PasswordFile $fullPath
		Connect-PureVeeamBackupServer -Server $VBRServer `
			-Credential $credential `
			-ForceAcceptTlsCertificate:$ForceAcceptTlsCertificate

		# Connect-PureVeeamBackupServer throws when it cannot establish a session, so reaching
		# here means the credential was accepted. Prove it by reading something back.
		$shares = @(Get-VBRUnstructuredServer -ErrorAction Stop)
		Write-Host ''
		Write-Host "Verification succeeded. The session can see $($shares.Count) unstructured data source(s)."
		try { Disconnect-VBRServer -ErrorAction Stop } catch {
			Write-Verbose 'Disconnect-VBRServer was unavailable or already disconnected.'
		}
	}

	Write-Host 'Confirm the Veeam Backup Service account can also read this file by re-running with'
	Write-Host '-VerifyOnly under that account, for example: psexec -s -i pwsh.exe -File ...'
}

Write-Host ''
if ($isApiToken) {
	Write-Host 'Next step: reference this file from your configuration as "ApiTokenFile", or pass'
	Write-Host "-ApiTokenFile '$fullPath' to the pre/post backup scripts."
} else {
	Write-Host 'Next step: reference this file from your configuration as "VBRPasswordFile", alongside'
	Write-Host '"VBRUser", or pass -VBRPasswordFile and -VBRUser to the pre-backup script:'
	Write-Host "  `"VBRUser`": `"$VBRUser`","
	Write-Host "  `"VBRPasswordFile`": `"$($fullPath -replace '\\', '\\')`""
}
