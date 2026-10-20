# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Real-transport tests for lib/Http.ps1 against a throw-away local HTTPS server.

.DESCRIPTION
	The other suites replace the transport, so they cannot catch defects in the transport
	itself, such as a TLS callback that needs a PowerShell runspace on a thread that has none.
	This suite starts a minimal HTTPS server (TcpListener + SslStream) with a self-signed
	certificate in a background job and exercises every TLS policy: skip, a matching and a
	mismatching thumbprint pin (SHA-1 and SHA-256), and 'system', which must reject the
	self-signed certificate. It also checks that non-2xx responses come back as data.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
Initialize-TestCounters
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'EverpureVeeamNas.psm1') -Force

# --- self-signed certificate for 127.0.0.1 -----------------------------------------------------
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=evp-test', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
$san.AddIpAddress([System.Net.IPAddress]::Loopback)
$request.CertificateExtensions.Add($san.Build())
$cert = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddHours(1))
$pfxPassword = 'evp-test'
$pfx = [Convert]::ToBase64String($cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pfxPassword))
$sha1 = $cert.Thumbprint
$sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($cert.RawData))

# --- minimal HTTPS server in a background process ------------------------------------------------
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()

$server = Start-Job -ArgumentList $port, $pfx, $pfxPassword -ScriptBlock {
	param($port, $pfxBase64, $password)
	$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($pfxBase64), $password,
		[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
	$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
	$listener.Start()
	$deadline = (Get-Date).AddSeconds(90)
	while ((Get-Date) -lt $deadline) {
		if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
		$client = $listener.AcceptTcpClient()
		try {
			$ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
			try {
				$ssl.AuthenticateAsServer($cert, $false, [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13, $false)
				$buffer = [byte[]]::new(8192)
				$text = ''
				while (-not $text.Contains("`r`n`r`n")) {
					$n = $ssl.Read($buffer, 0, $buffer.Length)
					if ($n -le 0) { break }
					$text += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $n)
				}
				$firstLine = ($text -split "`r`n")[0]
				$path = ($firstLine -split ' ')[1]
				$status = if ($path -like '/missing*') { '404 Not Found' } else { '200 OK' }
				$body = '{"path":"' + $path + '","ok":true}'
				$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
				$head = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nX-Test: yes`r`nConnection: close`r`n`r`n"
				$headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
				$ssl.Write($headBytes, 0, $headBytes.Length)
				$ssl.Write($bytes, 0, $bytes.Length)
				$ssl.Flush()
			} catch { } finally { $ssl.Dispose() }
		} finally { $client.Dispose() }
	}
	$listener.Stop()
}

# Wait until the server listens.
$ready = $false
for ($i = 0; $i -lt 100 -and -not $ready; $i++) {
	try { $probe = [System.Net.Sockets.TcpClient]::new(); $probe.Connect('127.0.0.1', $port); $probe.Dispose(); $ready = $true } catch { Start-Sleep -Milliseconds 100 }
}
$base = "https://127.0.0.1:$port"

try {
	Write-TestSection 'Real transport: TLS policies'
	if (-not $ready) { throw 'test HTTPS server did not start' }
	$r = Invoke-EvpHttp -Uri "$base/api/api_version" -Tls skip
	Assert-Equal 'skip: status 200'      $r.StatusCode 200
	Assert-Equal 'skip: body parsed'     $r.Body.path '/api/api_version'
	Assert-Equal 'skip: header read'     $r.Headers['X-Test'] 'yes'
	$r = Invoke-EvpHttp -Uri "$base/x" -Tls "thumbprint:$sha1"
	Assert-Equal 'SHA-1 pin matches'     $r.StatusCode 200
	$r = Invoke-EvpHttp -Uri "$base/x" -Tls "thumbprint:$($sha256.ToLowerInvariant())"
	Assert-Equal 'SHA-256 pin matches (case-insensitive)' $r.StatusCode 200
	Assert-Throws 'wrong pin rejected' { Invoke-EvpHttp -Uri "$base/x" -Tls ('thumbprint:' + ('0' * 40)) } 'failed'
	Assert-Throws 'system policy rejects self-signed' { Invoke-EvpHttp -Uri "$base/x" -Tls system } 'failed'
	$r = Invoke-EvpHttp -Uri "$base/missing" -Tls skip
	Assert-Equal 'non-2xx is data, not an exception' $r.StatusCode 404
	Assert-Equal 'non-2xx Success flag'  $r.Success 'False'
	Assert-True  'error text helper'     ((Get-EvpHttpErrorText $r) -like 'HTTP 404*')
	$r = Invoke-EvpHttp -Method POST -Uri "$base/login" -Headers @{ 'api-token' = 't' } -Body @{ a = 1 } -Tls skip
	Assert-Equal 'POST with JSON body'   $r.StatusCode 200
	Assert-Throws 'connection refused is a clean transport error' { Invoke-EvpHttp -Uri 'https://127.0.0.1:9/x' -Tls skip -TimeoutSec 5 } '^HTTP GET https://127\.0\.0\.1:9/x failed:'
} finally {
	Stop-Job $server -ErrorAction SilentlyContinue
	Remove-Job $server -Force -ErrorAction SilentlyContinue
}

Complete-TestRun
