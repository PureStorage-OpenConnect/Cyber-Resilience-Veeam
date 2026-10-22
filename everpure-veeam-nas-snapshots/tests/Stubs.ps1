# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Test doubles shared by the suites and by the end-to-end child process.

	HTTP: New-EvpMockResponder returns a script block for Set-EvpHttpInvoker that answers from a
	route table shaped like the lab arrays and the Veeam REST API, and appends every request as
	one JSON line to a call log, so tests assert on exactly which calls were made.

	Veeam: Install-VeeamStubModule writes a stub 'Veeam.Backup.PowerShell' module into a folder
	to prepend to PSModulePath. The inventory objects are real .NET types created with Add-Type,
	because the adapter dispatches on the concrete type name; a PSCustomObject would not do.
	Stub cmdlets log with [System.IO.File]::AppendAllText, not Add-Content, because Add-Content
	honours -WhatIf and would silently drop the log during the -WhatIf cases.
#>

function Add-CallLogEntry {
	param([string] $Path, $Entry)
	if (-not $Path) { return }
	[System.IO.File]::AppendAllText($Path, (($Entry | ConvertTo-Json -Compress -Depth 8) + "`n"))
}

function Read-CallLog {
	param([Parameter(Mandatory)] [string] $Path)
	if (-not (Test-Path -LiteralPath $Path)) { return @() }
	return @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function New-MockResponse {
	param([int] $Status = 200, $Body = $null, [hashtable] $Headers = @{})
	# Round-trip through JSON so the body has the same shape as a real parsed response
	# (PSCustomObject with properties), not a hashtable.
	$raw = ''
	$parsed = $null
	if ($null -ne $Body) {
		$raw = $Body | ConvertTo-Json -Compress -Depth 16
		$parsed = $raw | ConvertFrom-Json -Depth 32
	}
	[pscustomobject]@{ StatusCode = $Status; Success = ($Status -ge 200 -and $Status -lt 300); Headers = $Headers; Body = $parsed; Raw = $raw }
}

function New-EvpMockResponder {
	<#
	.SYNOPSIS
		Scripted HTTP responder. Routes are "METHOD regex-on-unescaped-uri" -> scriptblock($request, $match).
	.PARAMETER Routes
		Ordered hashtable; the first matching route answers. A route may return a response from
		New-MockResponse or a plain body (wrapped as 200).
	.PARAMETER CallLog
		File that receives one JSON line per request (Method, Uri, Body).
	#>
	param([Parameter(Mandatory)] [System.Collections.IDictionary] $Routes, [string] $CallLog)
	$routesCopy = $Routes
	$logPath = $CallLog
	return {
		param($request)
		$uri = [uri]::UnescapeDataString($request.Uri)
		Add-CallLogEntry -Path $logPath -Entry ([ordered]@{ Method = $request.Method; Uri = $uri; Body = $request.Body; Headers = @($request.Headers.Keys) })
		foreach ($key in $routesCopy.Keys) {
			$method, $pattern = $key -split ' ', 2
			if ($request.Method -ne $method) { continue }
			$m = [regex]::Match($uri, $pattern)
			if (-not $m.Success) { continue }
			$result = & $routesCopy[$key] $request $m
			if ($result -is [psobject] -and $result.PSObject.Properties.Name -contains 'StatusCode') { return $result }
			return (New-MockResponse -Body $result)
		}
		return (New-MockResponse -Status 404 -Body @{ errors = @(@{ message = "no mock route for $($request.Method) $uri" }) })
	}.GetNewClosure()
}

function New-LabRoutes {
	<#
	.SYNOPSIS
		Route table modelled on the lab: FlashArray 'fa' (realm exports), FlashBlade 'fb', Veeam REST 'vbr'.
	.PARAMETER State
		Hashtable the routes mutate: FaSnapshots, FbSnapshots (lists), VeeamShares (list of models),
		VeeamBuild, FaLoginStatus, FbSnapshotDirEnabled, VeeamSaveResult.
	#>
	param([Parameter(Mandatory)] [hashtable] $State)
	$routes = [ordered]@{}

	# --- FlashArray ----------------------------------------------------------------------
	$routes['GET ^https://fa/api/api_version$'] = { @{ version = @('1.19', '2.0', '2.4', '2.42') } }
	$routes['POST ^https://fa/api/2\.42/login$'] = {
		param($r)
		if ($State.FaLoginStatus -and $State.FaLoginStatus -ne 200) { return (New-MockResponse -Status $State.FaLoginStatus -Body @{ errors = @(@{ message = 'invalid credentials' }) }) }
		if ($r.Headers['api-token'] -ne 'fa-token') { return (New-MockResponse -Status 401 -Body @{ errors = @(@{ message = 'invalid api token' }) }) }
		New-MockResponse -Body @{ username = 'svc-backup' } -Headers @{ 'x-auth-token' = 'fa-session' }
	}
	$routes['GET ^https://fa/api/2\.42/arrays$'] = { @{ items = @(@{ name = 'fa01'; os = 'Purity//FA'; version = '6.8.5' }) } }
	$routes['GET ^https://fa/api/2\.42/directory-exports\?export_names=(.+)$'] = {
		param($r, $m)
		$name = $m.Groups[1].Value
		$items = switch ($name) {
			'finance-smb' { @(@{ export_name = $name; directory = @{ name = 'fs01:finance-smb' }; policy = @{ name = 'smb-simple'; resource_type = 'policies/smb' } }) }
			'finance-nfs' { @(@{ export_name = $name; directory = @{ name = 'fs01:finance-nfs' }; policy = @{ name = 'nfs-simple'; resource_type = 'policies/nfs' } }) }
			'shared' { @(
					@{ export_name = $name; directory = @{ name = 'fs01:shared' }; policy = @{ name = 'smb-simple'; resource_type = 'policies/smb' } },
					@{ export_name = $name; directory = @{ name = 'fs01:shared' }; policy = @{ name = 'nfs-simple'; resource_type = 'policies/nfs' } }) }
			'ambiguous' { @(
					@{ export_name = $name; directory = @{ name = 'fs:a' }; policy = @{ name = 'p1'; resource_type = 'policies/smb' } },
					@{ export_name = $name; directory = @{ name = 'fs:b' }; policy = @{ name = 'p2'; resource_type = 'policies/smb' } }) }
			default { @() }
		}
		@{ items = $items }
	}
	$routes['GET ^https://fa/api/2\.42/directories\?names=(.+)$'] = { param($r, $m); @{ items = @(@{ name = $m.Groups[1].Value }) } }
	$routes['POST ^https://fa/api/2\.42/directory-snapshots\?source_names=(.+)$'] = {
		param($r, $m)
		$src = $m.Groups[1].Value
		$name = '{0}.{1}.{2}' -f $src, $r.Body.client_name, $r.Body.suffix
		$State.FaSnapshots += , @{ name = $name; source = @{ name = $src }; destroyed = $false; created = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
		@{ items = @(@{ name = $name }) }
	}
	$routes['GET ^https://fa/api/2\.42/directory-snapshots\?source_names=(.+)$'] = {
		param($r, $m)
		$src = $m.Groups[1].Value
		@{ items = @($State.FaSnapshots | Where-Object { $_.source.name -eq $src }) }
	}
	$routes['PATCH ^https://fa/api/2\.42/directory-snapshots\?names=(.+)$'] = {
		param($r, $m)
		$name = $m.Groups[1].Value
		foreach ($s in $State.FaSnapshots) { if ($s.name -eq $name) { $s.destroyed = $true } }
		@{ items = @(@{ name = $name; destroyed = $true }) }
	}

	# --- FlashBlade ----------------------------------------------------------------------
	$routes['GET ^https://fb/api/api_version$'] = { @{ versions = @('1.8', '2.0', '2.17') } }
	$routes['POST ^https://fb/api/login$'] = {
		param($r)
		if ($r.Headers['api-token'] -ne 'fb-token') { return (New-MockResponse -Status 401 -Body @{ errors = @(@{ message = 'invalid api token' }) }) }
		New-MockResponse -Body @{ username = 'svc-backup' } -Headers @{ 'x-auth-token' = 'fb-session' }
	}
	$routes['GET ^https://fb/api/2\.17/arrays$'] = { @{ items = @(@{ name = 'fb01'; os = 'Purity//FB'; version = '4.5.2' }) } }
	$routes['GET ^https://fb/api/2\.17/file-systems\?names=(.+)$'] = {
		param($r, $m)
		$name = $m.Groups[1].Value
		if ($name -in 'projects-nfs', 'projects-smb', 'renamed-fs') {
			$enabled = if ($null -ne $State.FbSnapshotDirEnabled) { $State.FbSnapshotDirEnabled } else { $true }
			return @{ items = @(@{ name = $name; snapshot_directory_enabled = $enabled; nfs = @{ export_name = '' }; smb = @{ share_name = '' } }) }
		}
		# An unknown name is an error, not an empty list.
		New-MockResponse -Status 400 -Body @{ errors = @(@{ message = 'File system does not exist.'; context = $name }) }
	}
	$routes["GET ^https://fb/api/2\.17/file-system-exports\?filter=export_name='(.+)'$"] = {
		param($r, $m)
		# Shaped like Purity//FB 4.8.7. projects-nfs has no export entry, like a release without
		# file-system-exports, so the file system name fallback is exercised too.
		$exports = @(
			@{ export_name = 'custom-share'; policy_type = 'SMB'; member = @{ name = 'renamed-fs' }; server = @{ name = 'srv1' } },
			@{ export_name = 'custom-share'; policy_type = 'NFS'; member = @{ name = 'other-fs' }; server = @{ name = 'srv1' } },
			@{ export_name = 'projects-nfs'; policy_type = 'SMB'; member = @{ name = 'unrelated-fs' }; server = @{ name = 'srv1' } },
			@{ export_name = 'dup-share'; policy_type = 'SMB'; member = @{ name = 'fs-a' }; server = @{ name = 'srv1' } },
			@{ export_name = 'dup-share'; policy_type = 'SMB'; member = @{ name = 'fs-b' }; server = @{ name = 'srv2' } }
		)
		@{ items = @($exports | Where-Object { $_.export_name -eq $m.Groups[1].Value }) }
	}
	$routes['POST ^https://fb/api/2\.17/file-system-snapshots\?source_names=(.+)$'] = {
		param($r, $m)
		$src = $m.Groups[1].Value
		if ($r.Body.suffix -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9]$') { return (New-MockResponse -Status 400 -Body @{ errors = @(@{ message = 'invalid suffix'; context = $r.Body.suffix }) }) }
		$name = '{0}.{1}' -f $src, $r.Body.suffix
		$State.FbSnapshots += , @{ name = $name; source = @{ name = $src }; destroyed = $false; created = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
		@{ items = @(@{ name = $name }) }
	}
	$routes["GET ^https://fb/api/2\.17/file-system-snapshots\?filter=source\.name='(.+)'$"] = {
		param($r, $m)
		$src = $m.Groups[1].Value
		# Model the lab defect: foreign items slip through, the client must re-check source.name,
		# including an item that does not name its source at all.
		$items = @($State.FbSnapshots | Where-Object { $_.source.name -eq $src })
		$items += , @{ name = 'other-fs.Veeam-Backup-20200101T000000Z'; source = @{ name = 'other-fs' }; destroyed = $false; created = 0 }
		$items += , @{ name = 'orphan.Veeam-Backup-20200101T000000Z'; destroyed = $false; created = 0 }
		@{ items = $items }
	}
	$routes['GET ^https://fb/api/2\.17/file-system-snapshots\?(?!filter=).*$'] = { @{ items = @($State.FbSnapshots) + @(1..5 | ForEach-Object { @{ name = "noise-$_"; source = @{ name = 'noise' }; destroyed = $false } }) } }
	$routes['PATCH ^https://fb/api/2\.17/file-system-snapshots\?names=(.+)$'] = {
		param($r, $m)
		$name = $m.Groups[1].Value
		foreach ($s in $State.FbSnapshots) { if ($s.name -eq $name) { $s.destroyed = $true } }
		@{ items = @(@{ name = $name; destroyed = $true }) }
	}

	# --- Veeam REST ----------------------------------------------------------------------
	$routes['POST ^https://vbr:9419/api/oauth2/token$'] = { param($r); if ($r.Body -like '*username=svc*') { @{ access_token = 'vbr-token'; expires_in = 900 } } else { New-MockResponse -Status 401 -Body @{ error = 'invalid_grant'; error_description = 'bad credentials' } } }
	$routes['GET ^https://vbr:9419/api/v1/serverInfo$'] = { @{ buildVersion = $(if ($State.VeeamBuild) { $State.VeeamBuild } else { '13.1.1.18' }); platform = 'Linux'; name = 'vsa01' } }
	$routes['GET ^https://vbr:9419/api/v1/inventory/unstructuredDataServers\?limit=500$'] = { @{ data = @($State.VeeamShares) } }
	$routes['GET ^https://vbr:9419/api/v1/inventory/unstructuredDataServers/([^/?]+)$'] = { param($r, $m); $id = $m.Groups[1].Value; ($State.VeeamShares | Where-Object { $_.id -eq $id } | Select-Object -First 1) }
	$routes['PUT ^https://vbr:9419/api/v1/inventory/unstructuredDataServers/([^/?]+)$'] = {
		param($r, $m)
		$id = $m.Groups[1].Value
		for ($i = 0; $i -lt $State.VeeamShares.Count; $i++) { if ($State.VeeamShares[$i].id -eq $id) { $State.VeeamShares[$i] = $r.Body } }
		@{ id = 'save-1'; state = 'Working'; sessionType = 'FileServerSave' }
	}
	$routes['GET ^https://vbr:9419/api/v1/sessions/save-1$'] = { @{ id = 'save-1'; state = 'Stopped'; result = @{ result = $(if ($State.VeeamSaveResult) { $State.VeeamSaveResult } else { 'Success' }); message = 'mock' } } }
	$routes['GET ^https://vbr:9419/api/v1/jobs/([^/?]+)$'] = {
		param($r, $m)
		$j = @($State.VeeamJobs | Where-Object { $_.id -eq $m.Groups[1].Value }) | Select-Object -First 1
		if ($j) { $j } else { New-MockResponse -Status 404 -Body @{ message = 'job not found' } }
	}
	$routes['GET ^https://vbr:9419/api/v1/sessions\?jobIdFilter=([^&]+)&limit=200$'] = { param($r, $m); @{ data = @($State.VeeamSessions | Where-Object { $_.jobId -eq $m.Groups[1].Value }) } }
	return $routes
}

function New-LabState {
	<# Fresh mutable state for New-LabRoutes. #>
	@{
		FaSnapshots          = @()
		FbSnapshots          = @()
		FaLoginStatus        = 200
		FbSnapshotDirEnabled = $true
		VeeamBuild           = '13.1.1.18'
		VeeamSaveResult      = 'Success'
		VeeamJobs            = @()
		VeeamSessions        = @()
		VeeamShares          = @(
			[pscustomobject]@{ id = 'smb-1'; type = 'SMBShare'; path = '\\192.0.2.10\finance-smb'; advancedSettings = [pscustomobject]@{ processingMode = 'Direct'; directBackupFailoverEnabled = $true; storageSnapshotPath = '' } },
			[pscustomobject]@{ id = 'nfs-1'; type = 'NFSShare'; path = '192.0.2.20:/projects-nfs'; advancedSettings = [pscustomobject]@{ processingMode = 'Direct'; directBackupFailoverEnabled = $true; storageSnapshotPath = '' } }
		)
	}
}

function Install-VeeamStubModule {
	<#
	.SYNOPSIS
		Writes a stub Veeam.Backup.PowerShell module under Root and returns the folder to prepend to PSModulePath.
	.DESCRIPTION
		The stub reads its inventory from the JSON file named by EVP_TEST_INVENTORY (array of
		{Type, Id, Path, ProcessingMode, DirectBackupFailoverEnabled, StorageSnapshotPath}),
		appends every Set-/Connect- call to EVP_TEST_CALLLOG, and makes Connect-VBRServer throw
		when EVP_TEST_CONNECT_FAIL is set.
	#>
	param([Parameter(Mandatory)] [string] $Root)
	$moduleDir = Join-Path $Root 'Veeam.Backup.PowerShell'
	New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
	$content = @'
if (-not ('Veeam.Backup.PowerShell.Infos.VBRNASSMBServer' -as [type])) {
	Add-Type -TypeDefinition @"
namespace Veeam.Backup.PowerShell.Infos {
	public class VBRNASSMBServer { public System.Guid Id { get; set; } public string Name { get; set; } public string Path { get; set; } public string ProcessingMode { get; set; } public bool DirectBackupFailoverEnabled { get; set; } public string StorageSnapshotPath { get; set; } }
	public class VBRNASNFSServer { public System.Guid Id { get; set; } public string Name { get; set; } public string Path { get; set; } public string ProcessingMode { get; set; } public bool DirectBackupFailoverEnabled { get; set; } public string StorageSnapshotPath { get; set; } }
	public class VBRS3CompatibleServer { public System.Guid Id { get; set; } public string Name { get; set; } public string Path { get; set; } }
}
"@
}
function Write-StubCall { param($Entry) if ($env:EVP_TEST_CALLLOG) { [System.IO.File]::AppendAllText($env:EVP_TEST_CALLLOG, (($Entry | ConvertTo-Json -Compress -Depth 6) + "`n")) } }
function Connect-VBRServer { param([string]$Server, $Credential, [switch]$ForceAcceptTlsCertificate, $ErrorAction)
	Write-StubCall ([ordered]@{ Cmdlet = 'Connect-VBRServer'; Server = $Server; User = $(if ($Credential) { $Credential.UserName } else { $null }); Force = $ForceAcceptTlsCertificate.IsPresent })
	if ($env:EVP_TEST_CONNECT_FAIL) { throw 'Failed to connect to Identity service' }
	$script:Connected = $true }
function Disconnect-VBRServer { param($ErrorAction) $script:Connected = $false }
function Get-VBRServerSession { param($ErrorAction) if ($script:Connected) { [pscustomobject]@{ Server = 'stub'; User = 'stub' } } else { $null } }
function Get-VBRUnstructuredServer { param([string[]]$Name, $ErrorAction)
	$items = @()
	if ($env:EVP_TEST_INVENTORY -and (Test-Path $env:EVP_TEST_INVENTORY)) { $items = @(Get-Content $env:EVP_TEST_INVENTORY -Raw | ConvertFrom-Json) }
	foreach ($i in $items) {
		$o = New-Object ("Veeam.Backup.PowerShell.Infos.$($i.Type)")
		$o.Id = [guid]$i.Id; $o.Path = $i.Path; $o.Name = ''
		if ($i.PSObject.Properties.Name -contains 'ProcessingMode') { $o.ProcessingMode = $i.ProcessingMode; $o.DirectBackupFailoverEnabled = [bool]$i.DirectBackupFailoverEnabled; $o.StorageSnapshotPath = [string]$i.StorageSnapshotPath }
		$o } }
function Set-VBRNASSMBServer { param($Server, [string]$StorageSnapshotPath, [switch]$EnableDirectBackupFailover, [string]$ProcessingMode, $ErrorAction)
	Write-StubCall ([ordered]@{ Cmdlet = 'Set-VBRNASSMBServer'; Path = $Server.Path; StorageSnapshotPath = $StorageSnapshotPath; Failover = $EnableDirectBackupFailover.IsPresent; Mode = $ProcessingMode }) }
function Set-VBRNASNFSServer { param($Server, [string]$StorageSnapshotPath, [switch]$EnableDirectBackupFailover, [string]$ProcessingMode, $ErrorAction)
	Write-StubCall ([ordered]@{ Cmdlet = 'Set-VBRNASNFSServer'; Path = $Server.Path; StorageSnapshotPath = $StorageSnapshotPath; Failover = $EnableDirectBackupFailover.IsPresent; Mode = $ProcessingMode }) }
# Jobs from EVP_TEST_JOBS (JSON array of {Id, Name, ShareRoots[]}), sessions from EVP_TEST_SESSIONS
# (JSON array of {Id, JobId, Name, State}); both model the lab cmdlets' shapes.
function Get-VBRUnstructuredBackupJob { param([string[]]$Name, [string[]]$Id, $ErrorAction, $WarningAction)
	$jobs = @(); if ($env:EVP_TEST_JOBS) { $jobs = @($env:EVP_TEST_JOBS | ConvertFrom-Json) }
	foreach ($j in $jobs) {
		if ($Id -and ([string]$Id[0]).ToLowerInvariant() -ne ([string]$j.Id).ToLowerInvariant()) { continue }
		if ($Name -and $Name[0] -ne $j.Name) { continue }
		[pscustomobject]@{ Id = [guid]$j.Id; Name = [string]$j.Name; BackupObject = @($j.ShareRoots | ForEach-Object { [pscustomobject]@{ Path = $_; Server = [pscustomobject]@{ Path = $_ } } }) }
	} }
function Get-VBRUnstructuredBackupSession { param([string[]]$Name, $ErrorAction)
	$sessions = @(); if ($env:EVP_TEST_SESSIONS) { $sessions = @($env:EVP_TEST_SESSIONS | ConvertFrom-Json) }
	foreach ($s in $sessions) {
		if ($Name -and $s.Name -notin $Name) { continue }
		[pscustomobject]@{ Id = [guid]$s.Id; JobId = [guid]$s.JobId; Name = [string]$s.Name; State = [string]$s.State; CreationTime = [datetime]'2026-01-01T00:00:00Z' }
	} }
Export-ModuleMember -Function Connect-VBRServer, Disconnect-VBRServer, Get-VBRServerSession, Get-VBRUnstructuredServer, Set-VBRNASSMBServer, Set-VBRNASNFSServer, Get-VBRUnstructuredBackupJob, Get-VBRUnstructuredBackupSession
'@
	[System.IO.File]::WriteAllText((Join-Path $moduleDir 'Veeam.Backup.PowerShell.psm1'), $content, [System.Text.UTF8Encoding]::new($false))
	return $Root
}

function New-LabInventoryFile {
	<# Inventory for the Veeam stub matching the Windows lab job, six shares. #>
	param([Parameter(Mandatory)] [string] $Path)
	$inv = @(
		@{ Type = 'VBRNASSMBServer'; Id = '11111111-1111-4111-8111-000000000001'; Path = '\\192.0.2.10\finance-smb'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRNASSMBServer'; Id = '11111111-1111-4111-8111-000000000002'; Path = '\\192.0.2.10\shared'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRNASNFSServer'; Id = '11111111-1111-4111-8111-000000000003'; Path = '192.0.2.10:/finance-nfs'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRNASNFSServer'; Id = '11111111-1111-4111-8111-000000000004'; Path = '192.0.2.10:/shared'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRNASSMBServer'; Id = '11111111-1111-4111-8111-000000000005'; Path = '\\192.0.2.20\projects-smb'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRNASNFSServer'; Id = '11111111-1111-4111-8111-000000000006'; Path = '192.0.2.20:/projects-nfs'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
		@{ Type = 'VBRS3CompatibleServer'; Id = '00000000-0000-0000-0000-000000000001'; Path = '' }
	)
	[System.IO.File]::WriteAllText($Path, ($inv | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
	return $Path
}

function New-LabConfigFile {
	<#
	.SYNOPSIS
		Writes a configuration plus plain-text token files for the mocked lab into Directory.
	.PARAMETER Backend
		Veeam.Backend value. 'Rest' adds the service user and password file.
	.PARAMETER Overrides
		Hashtable merged into the top-level sections (shallow) before writing.
	#>
	param([Parameter(Mandatory)] [string] $Directory, [string] $Backend = 'PowerShell', [hashtable] $Overrides = @{}, [string] $Name = 'lab-job')
	New-Item -ItemType Directory -Path (Join-Path $Directory 'secrets') -Force | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $Directory 'secrets/fa.token'), "fa-token`n")
	[System.IO.File]::WriteAllText((Join-Path $Directory 'secrets/fb.token'), "fb-token`n")
	[System.IO.File]::WriteAllText((Join-Path $Directory 'secrets/vbr.pwd'), "secret`n")
	$config = [ordered]@{
		Veeam     = [ordered]@{ Backend = $Backend; Server = $(if ($Backend -eq 'Rest') { 'vbr' } else { 'localhost' }); Port = 9419; Tls = 'skip' }
		Arrays    = @(
			[ordered]@{ Name = 'fa'; Endpoint = 'fa'; ApiTokenFile = 'secrets/fa.token' },
			[ordered]@{ Name = 'fb'; Endpoint = 'fb'; ApiTokenFile = 'secrets/fb.token' }
		)
		Shares    = @(
			[ordered]@{ VeeamPath = '\\192.0.2.10\finance-smb'; Array = 'fa' },
			[ordered]@{ VeeamPath = '\\192.0.2.10\shared'; Array = 'fa' },
			[ordered]@{ VeeamPath = '192.0.2.10:/shared'; Array = 'fa' },
			[ordered]@{ VeeamPath = '192.0.2.20:/projects-nfs'; Array = 'fb' }
		)
		Snapshot  = [ordered]@{ Tag = 'Veeam-Backup'; KeepFor = '1d' }
		Behaviour = [ordered]@{}
		Logging   = [ordered]@{ Directory = 'log'; RetentionDays = 1 }
	}
	if ($Backend -eq 'Rest') { $config.Veeam['User'] = 'svc'; $config.Veeam['PasswordFile'] = 'secrets/vbr.pwd' }
	foreach ($section in $Overrides.Keys) {
		if ($config[$section] -is [System.Collections.IDictionary] -and $Overrides[$section] -is [System.Collections.IDictionary]) {
			foreach ($k in $Overrides[$section].Keys) { $config[$section][$k] = $Overrides[$section][$k] }
		} else { $config[$section] = $Overrides[$section] }
	}
	$path = Join-Path $Directory "$Name.jsonc"
	[System.IO.File]::WriteAllText($path, ("// generated by tests`n" + ($config | ConvertTo-Json -Depth 6)), [System.Text.UTF8Encoding]::new($false))
	return $path
}
