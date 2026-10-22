# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Secret storage. Windows: DPAPI at LocalMachine scope plus a hardened ACL, so the Veeam
	Backup Service (LOCAL SYSTEM) can read what an administrator wrote. Linux: a plain file
	readable only by its owner and group, because nothing host-unique is visible inside the
	appliance sandbox and a key file beside the secret would protect nothing. On both platforms
	the file permissions are the real boundary; see docs/unified-nas-snapshot-plan.md section 2.
#>

function ConvertFrom-EvpSecureString {
	<# Unwraps a SecureString. Keep the result short-lived. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] [System.Security.SecureString] $SecureString)
	return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Assert-EvpDpapi {
	[CmdletBinding()]
	param()
	if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
		try { Add-Type -AssemblyName 'System.Security' -ErrorAction Stop } catch {
			Write-Verbose "Add-Type System.Security failed: $($_.Exception.Message)"
		}
	}
	if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
		throw 'Windows DPAPI (System.Security.Cryptography.ProtectedData) is unavailable on this host.'
	}
}

function Get-EvpUnixFileMode {
	<# 'mode owner:group' of a file. GNU stat first (Linux), BSD stat as a fallback (macOS dev boxes). #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] [string] $Path)
	$out = (& stat -c '%a %U:%G' $Path 2>$null) -join ''
	if ($LASTEXITCODE -ne 0 -or -not $out) { $out = (& stat -f '%Lp %Su:%Sg' $Path 2>$null) -join '' }
	return $out
}

function Protect-EvpSecret {
	<#
	.SYNOPSIS
		Writes a secret to a file, protected the way the current platform allows.
	.PARAMETER Secret
		The secret as a SecureString.
	.PARAMETER Path
		Destination file. Overwritten if it exists.
	.PARAMETER Platform
		From Get-EvpPlatform.
	.PARAMETER SkipAclHardening
		Windows only: leave the file ACL alone instead of restricting it to SYSTEM and Administrators.
	.PARAMETER Group
		Linux only: group to give read access, so the sandbox executor can read the file.
		Defaults to 'veeam-grp-data', the group the appliance executor account belongs to.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [System.Security.SecureString] $Secret,
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] $Platform,
		[switch] $SkipAclHardening,
		[string] $Group = 'veeam-grp-data'
	)

	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	$plain = ConvertFrom-EvpSecureString -SecureString $Secret
	if ([string]::IsNullOrWhiteSpace($plain)) { throw 'The supplied secret is empty.' }
	$parent = Split-Path -Parent $fullPath
	if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
		if ($PSCmdlet.ShouldProcess($parent, 'Create directory')) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
	}

	if ($Platform.IsWindows) {
		Assert-EvpDpapi
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
		try {
			$blob = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
		} finally { [Array]::Clear($bytes, 0, $bytes.Length) }
		if ($PSCmdlet.ShouldProcess($fullPath, 'Write DPAPI-protected secret')) {
			try { [System.IO.File]::WriteAllBytes($fullPath, $blob) } catch [System.UnauthorizedAccessException] {
				throw "Access to '$fullPath' is denied for $($Platform.Identity). Run this from an elevated PowerShell (Administrators rights are filtered by UAC in a normal session), or grant yourself write access to the secrets folder."
			}
			Write-Host "Wrote DPAPI (LocalMachine) protected secret to '$fullPath' ($($blob.Length) bytes)."
			if (-not $SkipAclHardening) {
				try {
					$acl = [System.Security.AccessControl.FileSecurity]::new()
					$acl.SetAccessRuleProtection($true, $false)
					foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
						$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
					}
					Set-Acl -LiteralPath $fullPath -AclObject $acl
					Write-Host 'ACL restricted to NT AUTHORITY\SYSTEM and BUILTIN\Administrators.'
				} catch {
					Write-Warning "Could not harden the ACL on '$fullPath': $($_.Exception.Message). Restrict it manually: at LocalMachine scope, read access equals knowing the secret."
				}
			} else {
				Write-Warning 'ACL hardening skipped. Any account able to read this file can decrypt it.'
			}
		}
		return
	}

	# Linux (and anything else): plain text, owner and group readable only.
	if ($PSCmdlet.ShouldProcess($fullPath, 'Write permission-protected secret')) {
		[System.IO.File]::WriteAllText($fullPath, $plain, [System.Text.UTF8Encoding]::new($false))
		& chmod 0640 $fullPath 2>$null
		$grpOk = $false
		if ($Group) {
			& chgrp $Group $fullPath 2>$null
			$grpOk = ($LASTEXITCODE -eq 0)
		}
		$mode = Get-EvpUnixFileMode -Path $fullPath
		Write-Host "Wrote secret to '$fullPath' (mode $mode)."
		if ($Group -and -not $grpOk) {
			Write-Warning "Could not set group '$Group' on '$fullPath'. On the appliance the job script runs as veeam-usr-scriptexecutor, a member of veeam-grp-data; without that group it cannot read the file."
		}
	}
}

function Read-EvpSecretBytes {
	<#
	.SYNOPSIS
		Reads a secret file and turns an access-denied error into platform-specific advice.
	.DESCRIPTION
		On Windows the file ACL allows only SYSTEM and Administrators, and a non-elevated session
		carries a UAC-filtered token in which Administrators is deny-only, so the usual cause is a
		missing elevation. On Linux the file is mode 0640, so the reader must own it or belong to
		the file's group.
	#>
	[CmdletBinding()]
	[OutputType([byte[]])]
	param(
		[Parameter(Mandatory)] [string] $FullPath,
		[Parameter(Mandatory)] $Platform
	)

	try {
		return [System.IO.File]::ReadAllBytes($FullPath)
	} catch [System.UnauthorizedAccessException] {
		if ($Platform.IsWindows) {
			throw "Access to '$FullPath' is denied for $($Platform.Identity). The file ACL allows only SYSTEM and Administrators. Run this from an elevated PowerShell (Administrators rights are filtered by UAC in a normal session), or as the Veeam service account (psexec -s pwsh ...)."
		}
		throw "Access to '$FullPath' is denied for $($Platform.Identity). The file is permission-protected (normally mode 0640); the reading account must own it or belong to its group (veeam-grp-data on the appliance)."
	}
}

function Unprotect-EvpSecret {
	<#
	.SYNOPSIS
		Reads a secret file written by Protect-EvpSecret and returns a SecureString.
	.DESCRIPTION
		Accepts a LocalMachine DPAPI blob, a CliXml export of a SecureString or PSCredential,
		or a plain-text file (the Linux format). Plain text on Windows works but warns.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
		Justification = 'Decryption necessarily yields plaintext; wrapping it in a SecureString is the purpose of this function.')]
	[CmdletBinding()]
	[OutputType([System.Security.SecureString])]
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] $Platform
	)

	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
		throw "Secret file '$fullPath' was not found. Create it with Protect-EverpureVeeamSecret.ps1."
	}
	$bytes = Read-EvpSecretBytes -FullPath $fullPath -Platform $Platform
	if ($bytes.Length -eq 0) { throw "Secret file '$fullPath' is empty." }

	$head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(64, $bytes.Length))
	if ($head -like '*<Objs*') {
		$imported = Import-Clixml -LiteralPath $fullPath
		if ($imported -is [System.Security.SecureString]) { return $imported }
		if ($imported -is [System.Management.Automation.PSCredential]) { return $imported.Password }
		throw "CliXml file '$fullPath' contains a $($imported.GetType().Name); expected a SecureString or a PSCredential."
	}

	$isText = -not ($bytes | Select-Object -First 512 | Where-Object { $_ -lt 9 -or ($_ -gt 13 -and $_ -lt 32) -or $_ -eq 127 })
	if ($Platform.IsWindows -and -not $isText) {
		Assert-EvpDpapi
		$clear = $null
		try {
			try {
				$clear = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
			} catch {
				throw "Failed to decrypt '$fullPath'. The file must have been created on this host with LocalMachine DPAPI scope. Underlying error: $($_.Exception.Message)"
			}
			return (ConvertTo-SecureString -String ([System.Text.Encoding]::UTF8.GetString($clear)) -AsPlainText -Force)
		} finally { if ($clear) { [Array]::Clear($clear, 0, $clear.Length) } }
	}

	if (-not $isText) { throw "Secret file '$fullPath' is binary but DPAPI is only available on Windows. Re-create it on this host." }
	if ($Platform.IsWindows) { Write-Warning "Secret file '$fullPath' is plain text. Re-create it with Protect-EverpureVeeamSecret.ps1 to get DPAPI protection." }
	$text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimEnd("`r", "`n")
	if ([string]::IsNullOrWhiteSpace($text)) { throw "Secret file '$fullPath' contains only whitespace." }
	return (ConvertTo-SecureString -String $text -AsPlainText -Force)
}

function Test-EvpSecretFile {
	<#
	.SYNOPSIS
		Reports how a secret file is protected, for the verify phase. Reads no secret.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] $Platform
	)

	$warnings = [System.Collections.Generic.List[string]]::new()
	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
		return [pscustomobject]@{ Path = $fullPath; Exists = $false; Protection = 'missing'; Permissions = ''; Warnings = @('file does not exist') }
	}
	$bytes = Read-EvpSecretBytes -FullPath $fullPath -Platform $Platform
	$head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, [Math]::Min(64, $bytes.Length))
	$isText = -not ($bytes | Select-Object -First 512 | Where-Object { $_ -lt 9 -or ($_ -gt 13 -and $_ -lt 32) -or $_ -eq 127 })
	$protection = if ($head -like '*<Objs*') { 'CliXml' } elseif ($isText) { 'plain text, file permissions' } else { 'DPAPI LocalMachine' }
	$permissions = ''
	if ($Platform.IsWindows) {
		try {
			$acl = Get-Acl -LiteralPath $fullPath
			$permissions = ($acl.Access | ForEach-Object { "$($_.IdentityReference):$($_.FileSystemRights)" }) -join '; '
			foreach ($rule in $acl.Access) {
				if ($rule.IdentityReference.Value -match 'Everyone|Authenticated Users|BUILTIN\\Users') { $warnings.Add("'$($rule.IdentityReference)' has access; restrict the ACL to SYSTEM and Administrators") }
			}
			if ($isText) { $warnings.Add('plain text on Windows; re-create with Protect-EverpureVeeamSecret.ps1 for DPAPI') }
		} catch { $warnings.Add("ACL could not be read: $($_.Exception.Message)") }
	} else {
		$permissions = Get-EvpUnixFileMode -Path $fullPath
		if ($permissions -match '^\d*(\d)\s') {
			if ([int]$Matches[1] -band 4) { $warnings.Add('world-readable; chmod 0640') }
		}
	}
	return [pscustomobject]@{ Path = $fullPath; Exists = $true; Protection = $protection; Permissions = $permissions; Warnings = @($warnings) }
}
