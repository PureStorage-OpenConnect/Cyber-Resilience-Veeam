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
	Shared helpers for the FlashArray File pre/post backup scripts in this repository.

	This module deliberately holds no configuration of its own. Settings are resolved by the
	calling script through Resolve-PureVeeamSetting, which reads (in order of precedence)
	explicit parameters, a JSON configuration file, environment variables, then defaults.

	Secrets are never written to a script, a configuration file or a transcript. The FlashArray
	API token is held as a SecureString and only unwrapped at the Connect-Pfa2Array call site.

	Requires PowerShell 7 (pwsh.exe), because the Veeam.Backup.PowerShell module ships only for
	PowerShell 7. The #Requires statements below make a run under Windows PowerShell 5.1 fail
	immediately with a clear message rather than part-way through with a missing-cmdlet error.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

# Note: Set-StrictMode is deliberately not enabled here. These helpers inspect Veeam inventory
# objects whose shape varies between releases, and a strict-mode failure on a missing property
# would mask the descriptive errors below.

#region Configuration and settings resolution

function Get-PureVeeamConfig {
	<#
	.SYNOPSIS
		Loads the JSON configuration file used by the FlashArray File backup scripts.
	.DESCRIPTION
		Locates the configuration file from, in order of precedence: the Path parameter, the
		FA_VEEAM_CONFIG environment variable, then 'fa-veeam-config.json' next to the calling
		script. A missing file is only an error when the location was specified explicitly;
		otherwise the scripts fall back to parameters and environment variables.
	.PARAMETER Path
		Explicit path to a JSON configuration file.
	.PARAMETER ScriptRoot
		Directory to probe for the default 'fa-veeam-config.json'. Pass $PSScriptRoot.
	.OUTPUTS
		PSCustomObject, or $null when no configuration file is in use.
	#>
	[CmdletBinding()]
	param(
		[string] $Path,
		[string] $ScriptRoot
	)

	$explicit = $false
	if ($Path) {
		$explicit = $true
	} else {
		$fromEnv = [Environment]::GetEnvironmentVariable('FA_VEEAM_CONFIG')
		if ($fromEnv) {
			$Path = $fromEnv
			$explicit = $true
		} elseif ($ScriptRoot) {
			$Path = Join-Path $ScriptRoot 'fa-veeam-config.json'
		}
	}

	if (-not $Path) { return $null }

	$resolvedPath = $Path
	$fallbackPath = $null
	if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
		# Veeam launches job scripts with an unpredictable working directory, so a relative
		# -ConfigFile that misses is retried next to the script before giving up.
		if ($ScriptRoot -and -not [System.IO.Path]::IsPathRooted($Path)) {
			$fallbackPath = Join-Path $ScriptRoot $Path
			if (Test-Path -LiteralPath $fallbackPath -PathType Leaf) {
				Write-Warning "Configuration file '$Path' was not found relative to the working directory '$((Get-Location).Path)'; using '$fallbackPath' instead. Pass an absolute path when Veeam invokes the script."
				$resolvedPath = $fallbackPath
			}
		}
		if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
			if ($explicit) {
				$tried = "'$Path'"
				if ($fallbackPath) { $tried += " and '$fallbackPath'" }
				throw "Configuration file was not found. Tried $tried."
			}
			Write-Verbose "No configuration file at '$Path'; using parameters and environment variables only."
			return $null
		}
	}

	try {
		$raw = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop
		$config = $raw | ConvertFrom-Json -ErrorAction Stop
	} catch {
		throw "Configuration file '$resolvedPath' could not be read as JSON: $($_.Exception.Message)"
	}

	Write-Host "Using configuration file '$resolvedPath'."

	if ($config.PSObject.Properties.Name -contains 'ApiToken' -and $config.ApiToken) {
		Write-Warning "Configuration file '$resolvedPath' contains a plaintext 'ApiToken'. Prefer 'ApiTokenFile' pointing at an encrypted token created by fa-veeam-credential-setup.ps1."
	}

	# Recorded so the caller can echo it inside the transcript. This function necessarily runs
	# before Start-Transcript, because it supplies the log directory and retention settings, so
	# the message above lands on the console rather than in the log.
	$config | Add-Member -NotePropertyName 'PureVeeamConfigPath' -NotePropertyValue $resolvedPath -Force

	return $config
}

function Resolve-PureVeeamSetting {
	<#
	.SYNOPSIS
		Resolves a single setting from parameters, configuration file, environment or default.
	.DESCRIPTION
		Precedence, highest first:
		  1. A parameter the caller explicitly bound on the command line
		  2. A matching key in the JSON configuration file
		  3. An environment variable
		  4. The supplied default
		Explicit binding is detected with $PSBoundParameters.ContainsKey rather than by testing
		the value, so an unspecified [switch] parameter does not silently override a 'true' in
		the configuration file.
	.PARAMETER Name
		Parameter name as it appears in the calling script's param() block.
	.PARAMETER Bound
		The caller's $PSBoundParameters.
	.PARAMETER Config
		Configuration object from Get-PureVeeamConfig, or $null.
	.PARAMETER ConfigKey
		Configuration file key, when it differs from Name.
	.PARAMETER EnvName
		Environment variable to consult.
	.PARAMETER Default
		Value to use when no other source supplies one.
	.PARAMETER Required
		Throw a descriptive error instead of returning $null when nothing supplies a value.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $Name,
		[System.Collections.IDictionary] $Bound,
		$Config,
		[string] $ConfigKey,
		[string] $EnvName,
		$Default,
		[switch] $Required
	)

	# ContainsKey, not Contains: $PSBoundParameters implements IDictionary.Contains explicitly, so
	# only ContainsKey is callable on it. Hashtable exposes both.
	if ($Bound -and $Bound.ContainsKey($Name)) {
		return $Bound[$Name]
	}

	if (-not $ConfigKey) { $ConfigKey = $Name }
	if ($Config -and ($Config.PSObject.Properties.Name -contains $ConfigKey)) {
		$fromConfig = $Config.$ConfigKey
		if ($null -ne $fromConfig -and "$fromConfig" -ne '') {
			return $fromConfig
		}
	}

	if ($EnvName) {
		$fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
		if ($fromEnv) { return $fromEnv }
	}

	if ($PSBoundParameters.ContainsKey('Default')) {
		return $Default
	}

	if ($Required) {
		$hint = "Supply -$Name on the command line"
		if ($ConfigKey) { $hint += ", set '$ConfigKey' in the configuration file" }
		if ($EnvName) { $hint += ", or set the $EnvName environment variable" }
		throw "Required setting '$Name' was not supplied. $hint."
	}

	return $null
}

function ConvertTo-PureVeeamKeepFor {
	<#
	.SYNOPSIS
		Converts a human duration such as '7d', '48h' or '6h30m' into a FlashArray keep_for value.
		The array expresses keep_for in milliseconds, so that is what this returns.
	.DESCRIPTION
		FlashArray expresses directory snapshot retention (keep_for) in milliseconds, which is an
		awkward unit for a snapshot that lives for days. This accepts a compact duration instead.

		Units, combinable in descending order: w (weeks), d (days), h (hours), m (minutes),
		s (seconds). For example '7d', '48h', '1d12h', '6h30m', '90m'.

		'none', 'never', 'off', '0' and an empty value all mean no expiry and return 0, which
		callers turn into omitting -KeepFor altogether.

		A bare number is rejected, because its unit would be anyone's guess.

		Pure documents the valid keep_for range as 300 seconds to 31,536,000 seconds (365 days),
		so values outside it are rejected here with a clear message rather than at the API.
	.PARAMETER Duration
		The duration string to convert.
	.OUTPUTS
		Int64 milliseconds, or 0 meaning no expiry.
	.EXAMPLE
		ConvertTo-PureVeeamKeepFor -Duration '6h30m'

		Returns 23400000.
	#>
	[CmdletBinding()]
	[OutputType([long])]
	param(
		[AllowNull()] [AllowEmptyString()] [string] $Duration
	)

	$minimumMs = 300000L        # 300 seconds
	$maximumMs = 31536000000L   # 365 days

	if ([string]::IsNullOrWhiteSpace($Duration)) { return 0L }

	$text = $Duration.Trim()
	if ($text -in @('0', 'none', 'never', 'off', 'unlimited')) { return 0L }

	if ($text -match '^\d+$') {
		throw "Snapshot lifetime '$text' has no unit, so its meaning is ambiguous. Use a duration such as '7d', '48h', '1d12h', '6h30m' or '90m', or 'none' for no expiry."
	}

	$pattern = '^(?:(?<w>\d+)w)?(?:(?<d>\d+)d)?(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?$'
	$parsed = [regex]::Match($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	if (-not $parsed.Success -or [string]::IsNullOrEmpty($parsed.Value)) {
		throw "Could not parse snapshot lifetime '$Duration'. Use units w, d, h, m and s in descending order, for example '7d', '48h', '1d12h', '6h30m' or '90m'; or 'none' for no expiry."
	}

	$factors = @{ w = 604800000L; d = 86400000L; h = 3600000L; m = 60000L; s = 1000L }
	$totalMs = 0L
	foreach ($unit in 'w', 'd', 'h', 'm', 's') {
		$group = $parsed.Groups[$unit]
		if ($group.Success) { $totalMs += ([long]$group.Value) * $factors[$unit] }
	}

	# An explicit zero-valued duration such as '0h' is treated the same as 'none'.
	if ($totalMs -eq 0) { return 0L }

	if ($totalMs -lt $minimumMs -or $totalMs -gt $maximumMs) {
		throw "Snapshot lifetime '$Duration' resolves to $totalMs ms, which is outside the range FlashArray accepts for keep_for (5m to 365d). Choose a value in that range, or 'none' for no expiry."
	}

	return $totalMs
}

#endregion

#region Secret handling

function Assert-PureVeeamDpapi {
	<# Ensures the Windows DPAPI wrapper type is loadable. Private helper. #>
	[CmdletBinding()]
	param()

	if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
		try {
			Add-Type -AssemblyName 'System.Security' -ErrorAction Stop
		} catch {
			Write-Verbose "Add-Type System.Security failed: $($_.Exception.Message)"
		}
	}

	if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
		throw 'Windows DPAPI (System.Security.Cryptography.ProtectedData) is unavailable. Encrypted API token files are supported on Windows only.'
	}
}

function ConvertFrom-PureVeeamSecureString {
	<# Unwraps a SecureString to a plain string. Private helper; keep the result short-lived. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [System.Security.SecureString] $SecureString
	)

	return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

function Protect-PureVeeamSecret {
	<#
	.SYNOPSIS
		Encrypts a secret to a file using Windows DPAPI, LocalMachine scope.
	.DESCRIPTION
		Used for both the FlashArray API token and the Veeam password, which need identical
		storage.

		LocalMachine scope means any account on this host that can read the file can decrypt it,
		which is what allows the Veeam Backup Service (frequently LOCAL SYSTEM) to use a secret
		created by an administrator. The file ACL is therefore the actual security boundary --
		see fa-veeam-credential-setup.ps1, which hardens it.
	.PARAMETER Secret
		The secret as a SecureString.
	.PARAMETER Path
		Destination file. Overwritten if it exists.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [System.Security.SecureString] $Secret,
		[Parameter(Mandatory)] [string] $Path
	)

	Assert-PureVeeamDpapi

	$fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
	$bytes = $null
	$plain = $null
	try {
		$plain = ConvertFrom-PureVeeamSecureString -SecureString $Secret
		if ([string]::IsNullOrWhiteSpace($plain)) {
			throw 'The supplied secret is empty.'
		}
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
		$blob = [System.Security.Cryptography.ProtectedData]::Protect(
			$bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)

		if ($PSCmdlet.ShouldProcess($fullPath, 'Write encrypted secret')) {
			[System.IO.File]::WriteAllBytes($fullPath, $blob)
			Write-Host "Wrote encrypted secret to '$fullPath' ($($blob.Length) bytes)."
		}
	} finally {
		if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
		$plain = $null
	}
}

function Unprotect-PureVeeamSecret {
	<#
	.SYNOPSIS
		Reads an encrypted secret file and returns its contents as a SecureString.
	.DESCRIPTION
		Accepts either a LocalMachine-scope DPAPI blob written by Protect-PureVeeamSecret, or a
		CliXml file produced by Export-CliXml (SecureString or PSCredential). Supporting both
		means an existing CurrentUser-scope CliXml file keeps working unchanged.
	.PARAMETER Path
		Path to the encrypted secret file.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
		Justification = 'Decryption necessarily yields a plaintext string; wrapping it back into a SecureString is the purpose of this function. The plaintext is not persisted.')]
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $Path
	)

	$fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
		throw "Encrypted secret file '$fullPath' was not found. Create it with fa-veeam-credential-setup.ps1."
	}

	$bytes = [System.IO.File]::ReadAllBytes($fullPath)
	if ($bytes.Length -eq 0) {
		throw "Encrypted secret file '$fullPath' is empty."
	}

	# CliXml files are XML text starting with an <Objs> element; DPAPI blobs are binary.
	$headLength = [Math]::Min(64, $bytes.Length)
	$head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $headLength)
	if ($head -like '*<Objs*') {
		$imported = Import-Clixml -LiteralPath $fullPath
		if ($imported -is [System.Security.SecureString]) { return $imported }
		if ($imported -is [System.Management.Automation.PSCredential]) { return $imported.Password }
		throw "CliXml file '$fullPath' contains a $($imported.GetType().Name); expected a SecureString or a PSCredential."
	}

	Assert-PureVeeamDpapi

	$clear = $null
	try {
		try {
			$clear = [System.Security.Cryptography.ProtectedData]::Unprotect(
				$bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
		} catch {
			throw "Failed to decrypt '$fullPath'. The file must have been created on this host by fa-veeam-credential-setup.ps1 (LocalMachine DPAPI scope). Underlying error: $($_.Exception.Message)"
		}
		$plain = [System.Text.Encoding]::UTF8.GetString($clear)
		return (ConvertTo-SecureString -String $plain -AsPlainText -Force)
	} finally {
		if ($clear) { [Array]::Clear($clear, 0, $clear.Length) }
	}
}

function Get-PureFAApiToken {
	<#
	.SYNOPSIS
		Resolves the FlashArray API token from the first available source.
	.DESCRIPTION
		Order of precedence:
		  1. -ApiToken parameter
		  2. PUREFA_API_TOKEN environment variable (plaintext; warns)
		  3. Plaintext 'ApiToken' in the configuration file (warns)
		  4. Encrypted token file from -ApiTokenFile, config 'ApiTokenFile', or
		     PUREFA_API_TOKEN_FILE
		Returns $null when no source supplies a token, letting the caller fall back to a
		PSCredential.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
		Justification = 'The environment variable and configuration-file sources are inherently plaintext, and both warn when used. Converting to a SecureString is the best available handling.')]
	[CmdletBinding()]
	param(
		[System.Security.SecureString] $ApiToken,
		[string] $ApiTokenFile,
		$Config
	)

	if ($ApiToken) {
		Write-Host 'Using the FlashArray API token supplied as a parameter.'
		return $ApiToken
	}

	$fromEnv = [Environment]::GetEnvironmentVariable('PUREFA_API_TOKEN')
	if ($fromEnv) {
		Write-Warning 'Using the plaintext PUREFA_API_TOKEN environment variable. A machine-scoped environment variable is readable by any user on this host; prefer an encrypted token file for production use.'
		return (ConvertTo-SecureString -String $fromEnv -AsPlainText -Force)
	}

	if ($Config -and ($Config.PSObject.Properties.Name -contains 'ApiToken') -and $Config.ApiToken) {
		Write-Warning 'Using the plaintext ApiToken from the configuration file. Prefer ApiTokenFile with an encrypted token.'
		return (ConvertTo-SecureString -String $Config.ApiToken -AsPlainText -Force)
	}

	if (-not $ApiTokenFile) {
		$ApiTokenFile = Resolve-PureVeeamSetting -Name 'ApiTokenFile' -Config $Config -EnvName 'PUREFA_API_TOKEN_FILE'
	}

	if ($ApiTokenFile) {
		Write-Host "Reading encrypted FlashArray API token from '$ApiTokenFile'."
		return (Unprotect-PureVeeamSecret -Path $ApiTokenFile)
	}

	return $null
}

function Get-PureVeeamVBRCredential {
	<#
	.SYNOPSIS
		Builds the PSCredential used to authenticate to Veeam Backup & Replication.
	.DESCRIPTION
		Veeam runs pre/post job scripts as the Veeam Backup Service account, which defaults to
		LOCAL SYSTEM and therefore presents on the network as the machine account. Veeam accepts
		"only local and domain user accounts" for authentication, so a machine account cannot be
		granted a role and cannot connect -- hence this explicit credential.

		The user name is not a secret and lives in the configuration file; only the password is
		read from a LocalMachine-DPAPI file created by fa-veeam-credential-setup.ps1.

		Returns $null when nothing is configured, in which case the caller connects with the
		inherited identity. That still works where the Veeam Backup Service already runs as a
		user account holding a Veeam role.
	.PARAMETER Credential
		A complete PSCredential, taking precedence over UserName and PasswordFile.
	.PARAMETER UserName
		Veeam user name, in DOMAIN\Username or UPN format. On a workgroup server that means
		HOSTNAME\Username.
	.PARAMETER PasswordFile
		Path to the encrypted password file for UserName.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'PasswordFile',
		Justification = 'PasswordFile is a filesystem path, not a password. The password itself is only ever held as a SecureString.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
		Justification = 'The pair here is a user name and a path to an encrypted file, not a plaintext password. Building the PSCredential this rule recommends is exactly what this function returns.')]
	[CmdletBinding()]
	param(
		[System.Management.Automation.PSCredential] $Credential,
		[string] $UserName,
		[string] $PasswordFile
	)

	if ($Credential) {
		Write-Host "Using the Veeam credential supplied as a parameter ('$($Credential.UserName)')."
		return $Credential
	}

	if (-not $UserName -and -not $PasswordFile) { return $null }

	if (-not $UserName) {
		throw "A Veeam password file was configured but no user name. Set 'VBRUser' as well, in DOMAIN\Username or UPN format (HOSTNAME\Username on a workgroup server)."
	}
	if (-not $PasswordFile) {
		throw "Veeam user name '$UserName' was configured but no password. Set 'VBRPasswordFile' to a file created by fa-veeam-credential-setup.ps1."
	}

	if ($UserName -notmatch '[\\@]') {
		Write-Warning "Veeam user name '$UserName' has no domain or host prefix. Veeam expects DOMAIN\Username or UPN format; on a workgroup server use HOSTNAME\Username."
	}

	Write-Host "Reading the Veeam password for '$UserName' from '$PasswordFile'."
	$password = Unprotect-PureVeeamSecret -Path $PasswordFile
	return [System.Management.Automation.PSCredential]::new($UserName, $password)
}

function Test-PureVeeamTcpPort {
	<#
	.SYNOPSIS
		Reports whether a TCP port accepts a connection within a timeout.
	.DESCRIPTION
		Used by the Veeam connection preflight so that "the service is not listening" is visible
		in the transcript rather than inferred from a later, vaguer failure.
	.PARAMETER ComputerName
		Host to probe.
	.PARAMETER Port
		TCP port to probe.
	.PARAMETER TimeoutMilliseconds
		How long to wait before giving up.
	#>
	[CmdletBinding()]
	[OutputType([bool])]
	param(
		[Parameter(Mandatory)] [string] $ComputerName,
		[int] $Port = 443,
		[int] $TimeoutMilliseconds = 5000
	)

	$client = $null
	try {
		$client = [System.Net.Sockets.TcpClient]::new()
		$connect = $client.BeginConnect($ComputerName, $Port, $null, $null)
		if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
		$client.EndConnect($connect)
		return $true
	} catch {
		Write-Verbose "TCP probe of ${ComputerName}:$Port failed: $($_.Exception.Message)"
		return $false
	} finally {
		if ($client) { $client.Dispose() }
	}
}

function Test-PureVeeamTlsTrust {
	<#
	.SYNOPSIS
		Reports whether the TLS certificate presented on a port validates against this machine's
		trust store.
	.DESCRIPTION
		Exists because of a specific failure mode: when the backup server presents a certificate
		this machine does not trust, Connect-VBRServer asks whether to accept it. Under the Veeam
		Backup Service there is nobody to answer, so the cmdlet blocks until Veeam kills the script
		at its own timeout -- a job that stalls for a quarter of an hour and a log that stops after
		'Connecting to ...'. Knowing the answer before connecting turns that into a fast, explicit
		failure naming ForceAcceptTlsCertificate.

		The handshake deliberately completes even when validation fails, because the point is to
		read back the policy errors rather than to establish a usable connection.
	.PARAMETER ComputerName
		Host to probe.
	.PARAMETER Port
		TCP port to probe.
	.PARAMETER TimeoutMilliseconds
		How long to wait for the connection and the handshake.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
		Justification = 'The certificate validation callback must declare the full delegate signature, so the sender and chain arguments are named but unused.')]
	param(
		[Parameter(Mandatory)] [string] $ComputerName,
		[int] $Port = 443,
		[int] $TimeoutMilliseconds = 5000
	)

	$result = [ordered]@{
		Completed    = $false
		Trusted      = $false
		PolicyErrors = 'None'
		Subject      = $null
		Detail       = $null
	}

	$client = $null
	$stream = $null
	$ssl = $null
	try {
		$client = [System.Net.Sockets.TcpClient]::new()
		$connect = $client.BeginConnect($ComputerName, $Port, $null, $null)
		if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
			$result['Detail'] = 'the connection timed out'
			return [pscustomobject]$result
		}
		$client.EndConnect($connect)

		# The callback records what validation found and then accepts regardless, so that
		# AuthenticateAsClient returns instead of throwing and the errors survive to be reported.
		$observed = @{ Errors = $null; Subject = $null }
		$callback = {
			param($senderObject, $certificate, $chain, $sslPolicyErrors)
			$observed['Errors'] = $sslPolicyErrors
			if ($certificate) { $observed['Subject'] = $certificate.Subject }
			return $true
		}

		$stream = $client.GetStream()
		$stream.ReadTimeout = $TimeoutMilliseconds
		$stream.WriteTimeout = $TimeoutMilliseconds
		$ssl = [System.Net.Security.SslStream]::new($stream, $false, $callback)
		$ssl.AuthenticateAsClient($ComputerName)

		$result['Completed'] = $true
		$result['Subject'] = $observed['Subject']
		$errors = $observed['Errors']
		$result['PolicyErrors'] = if ($null -eq $errors) { 'None' } else { $errors.ToString() }
		$result['Trusted'] = ($result['PolicyErrors'] -eq 'None')
		return [pscustomobject]$result
	} catch {
		$result['Detail'] = $_.Exception.Message
		Write-Verbose "TLS probe of ${ComputerName}:$Port failed: $($_.Exception.Message)"
		return [pscustomobject]$result
	} finally {
		if ($ssl) { $ssl.Dispose() }
		if ($stream) { $stream.Dispose() }
		if ($client) { $client.Dispose() }
	}
}

#endregion

#region FlashArray connection

function Connect-PureFAArray {
	<#
	.SYNOPSIS
		Connects to a FlashArray using an API token, or a PSCredential as a fallback.
	.PARAMETER Endpoint
		Management IP address or FQDN of the FlashArray.
	.PARAMETER ApiToken
		FlashArray API token as a SecureString. Preferred.
	.PARAMETER Credential
		User name and password, used only when no API token is available.
	.PARAMETER IgnoreCertificateError
		Skip TLS certificate validation. Defaults to $true, which matches a FlashArray presenting
		its own self-signed certificate.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $Endpoint,
		[System.Security.SecureString] $ApiToken,
		[System.Management.Automation.PSCredential] $Credential,
		[bool] $IgnoreCertificateError = $true
	)

	if (-not $ApiToken -and -not $Credential) {
		throw "No FlashArray credentials are available for '$Endpoint'. Create an encrypted API token file with fa-veeam-credential-setup.ps1 and reference it with -ApiTokenFile or the 'ApiTokenFile' configuration key, or pass -Credential."
	}

	$connectParams = @{
		Endpoint    = $Endpoint
		ErrorAction = 'Stop'
	}
	if ($IgnoreCertificateError) { $connectParams['IgnoreCertificateError'] = $true }

	if ($ApiToken) {
		# Connect-Pfa2Array takes the token as a plain String, so unwrap it here and nowhere else.
		$connectParams['ApiToken'] = ConvertFrom-PureVeeamSecureString -SecureString $ApiToken
		$method = 'an API token'
	} else {
		$connectParams['Credential'] = $Credential
		$method = "user name '$($Credential.UserName)'"
	}

	Write-Host "Connecting to FlashArray '$Endpoint' using $method..."
	try {
		$array = Connect-Pfa2Array @connectParams
	} catch {
		throw "Failed to connect to FlashArray '$Endpoint': $($_.Exception.Message)"
	} finally {
		if ($connectParams.ContainsKey('ApiToken')) { $connectParams['ApiToken'] = $null }
		$connectParams.Remove('ApiToken')
	}

	Write-Host "Connected to FlashArray '$Endpoint'."
	return $array
}

#endregion

#region FlashArray snapshots

function Remove-PureFADirectorySnapshotMatch {
	<#
	.SYNOPSIS
		Destroys FlashArray File directory snapshots whose names match a pattern.
	.DESCRIPTION
		Marks matching snapshots destroyed. They are not eradicated, so they stay recoverable
		until the array's eradication delay expires.

		Shared by both backup scripts: the post-backup script uses it to clean up the snapshot the
		job read from, and the pre-backup script's -SweepOrphans mode uses it to clear leftovers
		from earlier runs whose post-backup script never completed.
	.PARAMETER Array
		Connected FlashArray, from Connect-PureFAArray.
	.PARAMETER SnapDirectory
		Managed Directory whose snapshots are examined.
	.PARAMETER MatchPattern
		Regular expression matched against snapshot names.
	.PARAMETER ExcludeName
		Snapshot names to leave alone even when they match the pattern. Matched against both the
		full '<dir>.<client>.<suffix>' name and the client-visible '<client>.<suffix>' tail, so
		the pre-backup script can pass the snapshot it has just pointed Veeam at.
	.OUTPUTS
		A summary object carrying Matched, Destroyed, AlreadyDestroyed and Kept counts.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] $Array,
		[Parameter(Mandatory)] [string] $SnapDirectory,
		[Parameter(Mandatory)] [string] $MatchPattern,
		[string[]] $ExcludeName = @()
	)

	$snapshots = @(Get-Pfa2DirectorySnapshot -Array $Array -SourceNames $SnapDirectory -ErrorAction Stop)
	$matching = @($snapshots | Where-Object { $_.Name -match $MatchPattern })

	$summary = [pscustomobject]@{
		Matched          = $matching.Count
		Destroyed        = 0
		AlreadyDestroyed = 0
		Kept             = 0
	}

	if ($matching.Count -eq 0) { return $summary }

	Write-Host "$($matching.Count) snapshot(s) on '$SnapDirectory' match '$MatchPattern'."

	foreach ($snapshot in $matching) {
		$excluded = $false
		foreach ($name in $ExcludeName) {
			if ($name -and ($snapshot.Name -eq $name -or $snapshot.Name.EndsWith(".$name"))) {
				$excluded = $true
				break
			}
		}
		if ($excluded) {
			Write-Host "Keeping snapshot '$($snapshot.Name)'."
			$summary.Kept++
			continue
		}

		if ($snapshot.Destroyed) {
			Write-Host "Snapshot '$($snapshot.Name)' was already destroyed."
			$summary.AlreadyDestroyed++
			continue
		}

		Write-Host "Destroying snapshot '$($snapshot.Name)'..."
		if ($PSCmdlet.ShouldProcess($snapshot.Name, 'Destroy FlashArray File directory snapshot')) {
			Update-Pfa2DirectorySnapshot -Array $Array -Ids $snapshot.Id -Destroyed:$true -ErrorAction Stop | Out-Null
			Write-Host "Destroyed snapshot '$($snapshot.Name)'."
			$summary.Destroyed++
		}
	}

	return $summary
}

#endregion

#region Logging

function Start-PureVeeamLog {
	<#
	.SYNOPSIS
		Starts a PowerShell transcript in a 'log' directory and prunes old transcripts.
	.DESCRIPTION
		Transcripts are named '<profile>-<timestamp>-<phase>.log', so that a plain alphabetical
		sort of the log directory groups every file for one profile together, and within that
		orders them by run time with each run's pre and post transcripts adjacent.
	.PARAMETER ScriptPath
		Full path of the calling script. Pass $PSCommandPath.
	.PARAMETER Phase
		Which half of the job this is: 'pre' or 'post'.
	.PARAMETER ConfigPath
		Resolved configuration file path. Its base name becomes the profile name, so one
		configuration file per job also means one set of transcripts per job. Falls back to
		'default' when the run is configured entirely from parameters and the environment.
	.PARAMETER LogDirectory
		Override for the log directory. Defaults to a 'log' folder beside the script.
	.PARAMETER RetentionDays
		Delete this profile's transcripts older than this many days. 0 disables pruning.
	.OUTPUTS
		The transcript path.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Starting a transcript is not a state change a caller would want to confirm, and -WhatIf must not suppress logging of the run it is describing.')]
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $ScriptPath,
		[Parameter(Mandatory)] [ValidateSet('pre', 'post')] [string] $Phase,
		[string] $ConfigPath,
		[string] $LogDirectory,
		[int] $RetentionDays = 30
	)

	$profileName = 'default'
	if ($ConfigPath) {
		$candidate = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
		if (-not [string]::IsNullOrWhiteSpace($candidate)) { $profileName = $candidate }
	}

	if (-not $LogDirectory) {
		$LogDirectory = Join-Path (Split-Path -Parent $ScriptPath) 'log'
	}
	if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
		New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
	}

	# Profile first, then a sortable timestamp, then the phase: an alphabetical listing groups a
	# profile's transcripts together and keeps each run's pre and post next to each other.
	$logPath = Join-Path $LogDirectory ('{0}-{1}-{2}.log' -f $profileName, (Get-Date -Format 'yyyyMMddHHmmss'), $Phase)

	try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript was running.' }
	Start-Transcript -Path $logPath | Out-Null
	Write-Host "Transcript: $logPath"

	if ($RetentionDays -gt 0) {
		$cutoff = (Get-Date).AddDays(-$RetentionDays)
		# Both patterns: this profile's transcripts, and any left over from the earlier
		# per-script naming scheme, which would otherwise never be pruned.
		$stale = @(Get-ChildItem -LiteralPath $LogDirectory -Filter "$profileName-*.log" -File -ErrorAction SilentlyContinue |
			Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -ne $logPath })
		foreach ($old in $stale) {
			try {
				Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
				Write-Host "Pruned transcript older than $RetentionDays days: $($old.Name)"
			} catch {
				Write-Warning "Could not prune '$($old.Name)': $($_.Exception.Message)"
			}
		}
	}

	return $logPath
}

function Stop-PureVeeamLog {
	<# Stops the transcript, tolerating the case where none is running. #>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Closes the transcript from a finally block; prompting or skipping under -WhatIf would leave the transcript open.')]
	[CmdletBinding()]
	param()

	try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript was running.' }
}

#endregion

#region Veeam

function Connect-PureVeeamBackupServer {
	<#
	.SYNOPSIS
		Ensures a usable Veeam PowerShell session exists, reusing one if already present.
	.DESCRIPTION
		Veeam invokes pre/post job scripts in a fresh pwsh.exe, so the Veeam module usually needs
		importing and connecting.

		When Get-VBRServerSession is available and reports no session, a failed Connect-VBRServer
		is treated as fatal. Continuing in that state is worse than stopping: the next Veeam cmdlet
		typically blocks until Veeam's own script timeout kills the run, which produces a job that
		hangs for a quarter of an hour and a log that stops mid-sentence.

		Only when the session cannot be probed at all does a failed connect fall back to a warning,
		since the host may legitimately be connected already.
	.PARAMETER Server
		Veeam Backup & Replication server to connect to. Defaults to localhost.
	.PARAMETER Credential
		Veeam credential from Get-PureVeeamVBRCredential. When omitted, the inherited identity is
		used, which fails on v13 if that identity is a machine account.
	.PARAMETER ForceAcceptTlsCertificate
		Accept the backup server's TLS certificate without validating it. Defaults to $true: a
		stock Veeam installation presents a self-signed certificate, and Connect-VBRServer then
		prompts to accept it, which is unanswerable under the Veeam Backup Service. Set $false to
		validate the certificate, in which case an untrusted one is reported by the preflight
		below rather than left to hang.
	.PARAMETER Port
		Port probed by the preflight. Veeam's own default is 443.
	#>
	[CmdletBinding()]
	param(
		[string] $Server = 'localhost',
		[System.Management.Automation.PSCredential] $Credential,
		[bool] $ForceAcceptTlsCertificate = $true,
		[int] $Port = 443
	)

	if (-not (Get-Module -Name 'Veeam.Backup.PowerShell')) {
		try {
			Import-Module -Name 'Veeam.Backup.PowerShell' -ErrorAction Stop -WarningAction SilentlyContinue
		} catch {
			Write-Verbose "Could not import Veeam.Backup.PowerShell: $($_.Exception.Message)"
		}
	}

	if (-not (Get-Command -Name 'Connect-VBRServer' -ErrorAction SilentlyContinue)) {
		Write-Verbose 'Connect-VBRServer is unavailable; assuming the host provides the Veeam cmdlets.'
		return
	}

	# Whether an existing session can be told apart from no session decides how hard to fail below.
	$canProbeSession = [bool](Get-Command -Name 'Get-VBRServerSession' -ErrorAction SilentlyContinue)
	if ($canProbeSession) {
		$session = $null
		try { $session = Get-VBRServerSession -ErrorAction Stop } catch { $session = $null }
		if ($session) {
			Write-Host 'Reusing the existing Veeam Backup & Replication session.'
			return
		}
	}

	# Preflight, so that a failure below is self-explanatory from the transcript alone.
	$identity = 'unknown'
	try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch {
		Write-Verbose 'Could not determine the current Windows identity.'
	}
	# LOCAL SYSTEM presents as the machine account, whose name ends in '$'. Veeam accepts only
	# local and domain user accounts, so that identity can never authenticate.
	$isMachineAccount = $identity.EndsWith('$')
	$portReachable = Test-PureVeeamTcpPort -ComputerName $Server -Port $Port

	if ($Credential) {
		$authDescription = "explicit credential '$($Credential.UserName)'"
	} else {
		$authDescription = "inherited identity '$identity'"
	}

	# UserInteractive is false for a process started by a service, which is exactly the case where
	# an unanswerable certificate prompt turns into a hang. Treat anything unreadable as
	# interactive, so an inaccurate reading can only cost a warning, never a false refusal.
	$interactive = $true
	try { $interactive = [Environment]::UserInteractive } catch {
		Write-Verbose 'Could not determine whether this session is interactive.'
	}

	$certDescription = 'not probed'
	$tls = $null
	if ($portReachable -and -not $ForceAcceptTlsCertificate) {
		$tls = Test-PureVeeamTlsTrust -ComputerName $Server -Port $Port
		if (-not $tls.Completed) {
			$certDescription = "could not be read ($($tls.Detail))"
		} elseif ($tls.Trusted) {
			$certDescription = 'trusted'
		} else {
			$certDescription = "NOT trusted ($($tls.PolicyErrors))"
		}
	} elseif ($ForceAcceptTlsCertificate) {
		$certDescription = 'accepted without validation (ForceAcceptTlsCertificate)'
	}

	Write-Host 'Veeam connection preflight:'
	Write-Host "  Running as     : $identity"
	Write-Host "  Target         : ${Server}:$Port"
	Write-Host "  Port reachable : $portReachable"
	Write-Host "  Certificate    : $certDescription"
	Write-Host "  Interactive    : $interactive"
	Write-Host "  Authenticating : $authDescription"

	if (-not $portReachable) {
		Write-Warning "Nothing is accepting connections on ${Server}:$Port. Check that the Veeam Backup Service and, on v13 and later, the identity service are running."
	}
	if ($isMachineAccount -and -not $Credential) {
		Write-Warning "This script is running as the machine account '$identity' with no explicit Veeam credential. Veeam accepts only local and domain user accounts, so a machine account cannot be granted a role and cannot authenticate. Configure 'VBRUser' and 'VBRPasswordFile'."
	}
	if ($tls -and $tls.Completed -and -not $tls.Trusted) {
		# Connect-VBRServer will ask whether to accept this certificate. Answering is possible at a
		# console and impossible under the Veeam Backup Service, where the prompt blocks until
		# Veeam's script timeout. Refuse now rather than hang for fifteen minutes.
		$certMessage = "The certificate presented by ${Server}:$Port is not trusted by this machine ($($tls.PolicyErrors))"
		if ($tls.Subject) { $certMessage += ", subject '$($tls.Subject)'" }
		if ($interactive) {
			Write-Warning "$certMessage. Connect-VBRServer will prompt to accept it. Restore 'ForceAcceptTlsCertificate' to its default of true so that unattended runs under the Veeam Backup Service do not stall on that prompt."
		} else {
			throw "$certMessage, and this session is not interactive. Connect-VBRServer would prompt to accept the certificate with nobody to answer, and block until Veeam's script timeout. Restore 'ForceAcceptTlsCertificate' to its default of true, or install a certificate this machine trusts."
		}
	}

	$connectParams = @{
		Server      = $Server
		ErrorAction = 'Stop'
	}
	if ($Credential) { $connectParams['Credential'] = $Credential }
	if ($ForceAcceptTlsCertificate) { $connectParams['ForceAcceptTlsCertificate'] = $true }

	Write-Host "Connecting to Veeam Backup & Replication server '$Server'..."
	try {
		Connect-VBRServer @connectParams
		Write-Host "Connected to Veeam Backup & Replication server '$Server'."
		return
	} catch {
		$detail = $_.Exception.Message

		if (-not $canProbeSession) {
			Write-Warning "Could not open a Veeam session to '$Server': $detail. Continuing, because this host may already be connected and there is no way to check."
			return
		}

		# There is demonstrably no session and connecting failed. Continuing would leave the next
		# Veeam cmdlet to block until Veeam's own script timeout kills the run, so stop now with
		# something actionable.
		$hints = [System.Collections.Generic.List[string]]::new()
		if ($isMachineAccount -and -not $Credential) {
			$hints.Add("this script is running as the machine account '$identity', which Veeam cannot authenticate -- set 'VBRUser' and 'VBRPasswordFile' to a local or domain user holding a Veeam role")
		} elseif ($Credential) {
			$hints.Add("check that '$($Credential.UserName)' holds a Veeam Backup & Replication role and that the password in the encrypted file is current")
		} else {
			$hints.Add("check that '$identity' holds a Veeam Backup & Replication role")
		}
		if (-not $portReachable) {
			$hints.Add("nothing is listening on ${Server}:$Port, so check the Veeam Backup Service and the identity service")
		}
		if (-not $ForceAcceptTlsCertificate) {
			$hints.Add("'ForceAcceptTlsCertificate' has been turned off, so a self-signed certificate on the backup server would be rejected -- its default is true")
		}

		throw "Could not open a Veeam session to '$Server': $detail. Next steps: $($hints -join '; ')."
	}
}

function Get-PureVeeamSourceLabel {
	<#
	.SYNOPSIS
		Returns something recognisable to call a Veeam unstructured data source.
	.DESCRIPTION
		Veeam does not populate Name consistently. On 13.1 every unstructured source reports an
		empty Name and carries the share path in Path instead, so anything that needs a name -- a
		log message, a ShouldProcess target, or the prefix a snapshot path is built from -- has to
		fall back rather than print or build from an empty string.
	.PARAMETER Server
		Inventory object, or $null.
	.PARAMETER Fallback
		Used when the object carries nothing usable. Typically the name that was searched for.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] [AllowNull()] $Server,
		[string] $Fallback
	)

	if ($null -ne $Server) {
		foreach ($candidate in @($Server.Name, $Server.Path, $Server.ServerName)) {
			if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
		}
	}
	if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback }
	return ''
}

function Get-PureVeeamUnstructuredServer {
	<#
	.SYNOPSIS
		Returns exactly one unstructured data source (file share) from the Veeam inventory.
	.DESCRIPTION
		Prefers Get-VBRUnstructuredServer (Veeam Backup & Replication 12.1 and later) and falls
		back to the obsolete Get-VBRNASServer on older releases.

		-Name returns an array and can legitimately match more than one source, because file
		shares and object storage share the same namespace. Binding a multi-element array to a
		-Server parameter fails confusingly, so require a single unambiguous match here.
	.PARAMETER Name
		File share name exactly as it appears in the Veeam inventory, for example
		'\\172.16.16.15\lab-files' (SMB) or '172.16.16.15:/lab-files' (NFS).
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] [string] $Name
	)

	if (Get-Command -Name 'Get-VBRUnstructuredServer' -ErrorAction SilentlyContinue) {
		$getCmdlet = 'Get-VBRUnstructuredServer'
	} elseif (Get-Command -Name 'Get-VBRNASServer' -ErrorAction SilentlyContinue) {
		Write-Warning 'Get-VBRUnstructuredServer is unavailable; falling back to the obsolete Get-VBRNASServer. Upgrade to Veeam Backup & Replication 12.1 or later.'
		$getCmdlet = 'Get-VBRNASServer'
	} else {
		throw 'Neither Get-VBRUnstructuredServer nor Get-VBRNASServer is available. Verify that the Veeam.Backup.PowerShell module is installed and that this script runs on the Veeam Backup & Replication server.'
	}

	$found = @(& $getCmdlet -Name $Name -ErrorAction Stop)

	if ($found.Count -eq 0) {
		throw "No unstructured data source named '$Name' was found in the Veeam inventory. The name must match the file share exactly as it appears there, for example '\\172.16.16.15\lab-files' for SMB or '172.16.16.15:/lab-files' for NFS."
	}
	if ($found.Count -gt 1) {
		$types = ($found | ForEach-Object { $_.GetType().Name }) -join ', '
		throw "Found $($found.Count) unstructured data sources named '$Name' ($types). Refine the name so that it identifies exactly one file share."
	}

	$label = Get-PureVeeamSourceLabel -Server $found[0] -Fallback $Name
	Write-Host "Found Veeam unstructured data source '$label' of type $($found[0].GetType().Name)."
	return $found[0]
}

function Set-PureVeeamStorageSnapshotPath {
	<#
	.SYNOPSIS
		Points a Veeam file share at a FlashArray File storage snapshot path.
	.DESCRIPTION
		Chooses the correct Veeam cmdlet from the concrete type of the inventory object, which is
		what makes this work for both SMB shares and NFS exports:

		  VBRNASSMBServer      -> Set-VBRNASSMBServer       (backslash separators)
		  VBRNASNFSServer      -> Set-VBRNASNFSServer       (forward slash separators)
		  VBRNASFilerSMBServer -> Set-VBRNasFilerSMBServer  (backslash separators)
		  VBRNASFilerNFSServer -> Set-VBRNasFilerNFSServer  (forward slash separators)

		Optional arguments are added only when the resolved cmdlet actually declares them,
		because these four cmdlets do not share an identical parameter set.
	.PARAMETER Server
		Inventory object from Get-PureVeeamUnstructuredServer.
	.PARAMETER SnapshotName
		Snapshot directory name as it appears under the snapshot root, '<ClientName>.<Suffix>'.
	.PARAMETER SharePath
		Share path to build the snapshot path from. Defaults to the inventory object's name.
	.PARAMETER SnapshotRootDirName
		Snapshot root directory on the share. Defaults to '.snapshot'.
	.PARAMETER StorageSnapshotPath
		Complete snapshot path, bypassing path construction entirely.
	.PARAMETER SetProcessingModeStorageSnapshot
		Also force the share's processing mode to StorageSnapshot. Off by default so that the
		mode configured in the Veeam console is left alone.
	.OUTPUTS
		The storage snapshot path that was applied.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] $Server,
		[Parameter(Mandatory)] [string] $SnapshotName,
		[string] $SharePath,
		[string] $SnapshotRootDirName = '.snapshot',
		[string] $StorageSnapshotPath,
		[switch] $SetProcessingModeStorageSnapshot
	)

	$dispatch = @{
		'VBRNASSMBServer'      = @{ Cmdlet = 'Set-VBRNASSMBServer';      Separator = '\' }
		'VBRNASNFSServer'      = @{ Cmdlet = 'Set-VBRNASNFSServer';      Separator = '/' }
		'VBRNASFilerSMBServer' = @{ Cmdlet = 'Set-VBRNasFilerSMBServer'; Separator = '\' }
		'VBRNASFilerNFSServer' = @{ Cmdlet = 'Set-VBRNasFilerNFSServer'; Separator = '/' }
	}

	$typeName = $Server.GetType().Name
	$label = Get-PureVeeamSourceLabel -Server $Server -Fallback $SharePath
	if (-not $dispatch.ContainsKey($typeName)) {
		throw "Veeam unstructured data source '$label' has type '$typeName', which these scripts do not support. Supported types: $(($dispatch.Keys | Sort-Object) -join ', '). Backup from storage snapshot requires the share to be registered as an SMB or NFS file share."
	}

	$cmdletName = $dispatch[$typeName].Cmdlet
	$separator = $dispatch[$typeName].Separator

	$command = Get-Command -Name $cmdletName -ErrorAction SilentlyContinue
	if (-not $command) {
		throw "The Veeam cmdlet '$cmdletName' needed for a '$typeName' source is not available in this version of the Veeam PowerShell module."
	}

	if (-not $StorageSnapshotPath) {
		# $label, not $Server.Name: on 13.1 Name is empty and the share path lives in Path, so
		# building from Name would yield a path that begins at the separator.
		if (-not $SharePath) { $SharePath = $label }
		if (-not $SharePath) {
			throw "Cannot build a storage snapshot path for the '$typeName' source because it reports no name or path. Pass -SharePath with the share exactly as it appears in the Veeam inventory."
		}
		$StorageSnapshotPath = '{0}{1}{2}{1}{3}' -f $SharePath.TrimEnd('\', '/'), $separator, $SnapshotRootDirName, $SnapshotName
	}

	$setParams = @{
		Server              = $Server
		StorageSnapshotPath = $StorageSnapshotPath
		ErrorAction         = 'Stop'
	}
	if ($command.Parameters.ContainsKey('EnableDirectBackupFailover')) {
		$setParams['EnableDirectBackupFailover'] = $false
	}
	if ($SetProcessingModeStorageSnapshot -and $command.Parameters.ContainsKey('ProcessingMode')) {
		$setParams['ProcessingMode'] = 'StorageSnapshot'
	}

	Write-Host "Pointing $typeName '$label' at storage snapshot path '$StorageSnapshotPath' using $cmdletName..."
	if ($PSCmdlet.ShouldProcess($label, "$cmdletName -StorageSnapshotPath '$StorageSnapshotPath'")) {
		& $cmdletName @setParams | Out-Null
		Write-Host 'Veeam file share configuration updated.'
	}

	return $StorageSnapshotPath
}

#endregion

Export-ModuleMember -Function @(
	'Get-PureVeeamConfig'
	'Resolve-PureVeeamSetting'
	'ConvertTo-PureVeeamKeepFor'
	'Remove-PureFADirectorySnapshotMatch'
	'Protect-PureVeeamSecret'
	'Unprotect-PureVeeamSecret'
	'Get-PureFAApiToken'
	'Connect-PureFAArray'
	'Start-PureVeeamLog'
	'Stop-PureVeeamLog'
	'Get-PureVeeamVBRCredential'
	'Test-PureVeeamTcpPort'
	'Test-PureVeeamTlsTrust'
	'Connect-PureVeeamBackupServer'
	'Get-PureVeeamSourceLabel'
	'Get-PureVeeamUnstructuredServer'
	'Set-PureVeeamStorageSnapshotPath'
)
