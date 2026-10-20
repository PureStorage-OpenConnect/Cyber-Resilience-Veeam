# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	One HTTP layer for Veeam REST and Purity REST, built on HttpClient rather than
	Invoke-RestMethod so that: (1) non-2xx responses come back as data instead of exceptions
	with the body hidden, (2) the three TLS policies 'skip', 'system' and 'thumbprint:<hex>'
	are handled identically for every endpoint, (3) tests can replace the whole layer with
	Set-EvpHttpInvoker and assert on exactly which calls were made.
#>

$script:EvpHttpClients = @{}

function Initialize-EvpHttpHook {
	<# The test hook lives in the global scope on purpose: it must survive the entry script's Import-Module -Force. #>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Test hook that must outlive a module reload; unset in production.')]
	[CmdletBinding()]
	param()
	if (-not (Get-Variable -Name EvpHttpInvoker -Scope Global -ErrorAction SilentlyContinue)) { $global:EvpHttpInvoker = $null }
}
Initialize-EvpHttpHook

function Set-EvpHttpInvoker {
	<#
	.SYNOPSIS
		Test hook: replaces the HTTP transport with a script block.
	.DESCRIPTION
		The script block receives one argument, the request as an ordered hashtable with the
		keys Method, Uri, Headers, Body, ContentType, Tls and TimeoutSec, and must return an
		object with StatusCode, Headers and Body. Pass $null to restore the real transport.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Test hook; changes nothing outside this process.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'See Initialize-EvpHttpHook.')]
	[CmdletBinding()]
	param([AllowNull()] [scriptblock] $ScriptBlock)
	$global:EvpHttpInvoker = $ScriptBlock
}

function Initialize-EvpCertificatePin {
	<#
	.SYNOPSIS
		Compiles the certificate-pinning validator once per process.
	.DESCRIPTION
		TLS validation callbacks run on .NET thread-pool threads that have no PowerShell
		runspace, so a PowerShell script block cannot be used there ("There is no Runspace
		available to run scripts in this thread"). The validator is therefore plain C#,
		compiled in memory on first use. 'skip' needs no compilation: it uses the delegate
		.NET ships for that purpose.
	#>
	[CmdletBinding()]
	param()
	if ('Everpure.Veeam.CertificatePin' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Everpure.Veeam
{
	public static class CertificatePin
	{
		// Accepts exactly one certificate, identified by its SHA-1 thumbprint (40 hex) or the
		// SHA-256 hash of its DER encoding (64 hex). Chain and policy errors are ignored on
		// purpose: the pin is the trust decision.
		public static Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> Create(string expectedHex)
		{
			string expected = (expectedHex ?? string.Empty).Replace(":", string.Empty).Replace(" ", string.Empty).ToUpperInvariant();
			return (request, certificate, chain, errors) =>
			{
				if (certificate == null) { return false; }
				string actual = expected.Length == 64
					? Convert.ToHexString(SHA256.HashData(certificate.RawData))
					: certificate.Thumbprint;
				return string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
			};
		}
	}
}
'@ -ErrorAction Stop
}

function Get-EvpHttpClient {
	<# One HttpClient per TLS policy, cached for the life of the process. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] [string] $Tls, [int] $TimeoutSec = 60)

	$key = "$Tls|$TimeoutSec"
	if ($script:EvpHttpClients.ContainsKey($key)) { return $script:EvpHttpClients[$key] }

	$handler = [System.Net.Http.HttpClientHandler]::new()
	if ($Tls -eq 'skip') {
		$handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
	} elseif ($Tls -like 'thumbprint:*') {
		Initialize-EvpCertificatePin
		$handler.ServerCertificateCustomValidationCallback = [Everpure.Veeam.CertificatePin]::Create($Tls.Substring(11))
	}
	$client = [System.Net.Http.HttpClient]::new($handler)
	$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
	$script:EvpHttpClients[$key] = $client
	return $client
}

function Invoke-EvpHttp {
	<#
	.SYNOPSIS
		Sends one HTTP request and returns status, headers and the parsed body.
	.DESCRIPTION
		Never throws on an HTTP error status; the caller decides what a 4xx or 5xx means.
		Throws on transport failures (DNS, refused, TLS, timeout) with a one-line message.
		A JSON response body is parsed; anything else is returned as a string.
	.PARAMETER Body
		A hashtable or object is serialised as JSON. A string is sent as-is with ContentType.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'See Initialize-EvpHttpHook.')]
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string] $Method = 'GET',
		[Parameter(Mandatory)] [string] $Uri,
		[hashtable] $Headers = @{},
		$Body,
		[string] $ContentType = 'application/json',
		[string] $Tls = 'skip',
		[int] $TimeoutSec = 60
	)

	$request = [ordered]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body; ContentType = $ContentType; Tls = $Tls; TimeoutSec = $TimeoutSec }
	if ($global:EvpHttpInvoker) { return (& $global:EvpHttpInvoker $request) }

	$client = Get-EvpHttpClient -Tls $Tls -TimeoutSec $TimeoutSec
	$message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
	try {
		foreach ($k in $Headers.Keys) { $message.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) | Out-Null }
		if ($null -ne $Body) {
			$text = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 16 -Compress }
			$message.Content = [System.Net.Http.StringContent]::new($text, [System.Text.Encoding]::UTF8, $ContentType)
		}
		try {
			$response = $client.SendAsync($message).GetAwaiter().GetResult()
		} catch {
			$ex = $_.Exception
			while ($ex.InnerException) { $ex = $ex.InnerException }
			throw "HTTP $Method $Uri failed: $($ex.Message)"
		}
		try {
			$raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
			$parsed = $raw
			$mediaType = $response.Content.Headers.ContentType.MediaType
			if ($raw -and ($mediaType -like '*json*' -or $raw.TrimStart().StartsWith('{') -or $raw.TrimStart().StartsWith('['))) {
				try { $parsed = $raw | ConvertFrom-Json -Depth 32 } catch { $parsed = $raw }
			}
			$headerTable = @{}
			foreach ($h in $response.Headers) { $headerTable[$h.Key] = ($h.Value -join ', ') }
			return [pscustomobject]@{
				StatusCode = [int]$response.StatusCode
				Success    = $response.IsSuccessStatusCode
				Headers    = $headerTable
				Body       = $parsed
				Raw        = $raw
			}
		} finally { $response.Dispose() }
	} finally { $message.Dispose() }
}

function Get-EvpHttpErrorText {
	<# Best-effort one-line description of an error response body from Veeam or Purity. #>
	[CmdletBinding()]
	[OutputType([string])]
	param($Response)
	$b = $Response.Body
	if ($null -eq $b) { return "HTTP $($Response.StatusCode)" }
	if ($b -is [string]) { return "HTTP $($Response.StatusCode): $($b.Substring(0, [Math]::Min(300, $b.Length)))" }
	$parts = [System.Collections.Generic.List[string]]::new()
	foreach ($name in 'message', 'errorCode', 'error', 'error_description') {
		if ($b.PSObject.Properties.Name -contains $name -and $b.$name) { $parts.Add([string]$b.$name) }
	}
	if ($b.PSObject.Properties.Name -contains 'errors' -and $b.errors) {
		foreach ($e in @($b.errors)) {
			$t = @($e.message, $e.context) | Where-Object { $_ } | Select-Object -First 2
			if ($t) { $parts.Add(($t -join ' / ')) }
		}
	}
	if ($parts.Count -eq 0) { $parts.Add(($b | ConvertTo-Json -Compress -Depth 4).Substring(0, [Math]::Min(300, ($b | ConvertTo-Json -Compress -Depth 4).Length))) }
	return "HTTP $($Response.StatusCode): $($parts -join '; ')"
}
