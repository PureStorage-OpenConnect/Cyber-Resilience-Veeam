# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Veeam adapter. One interface, two backends:

	  PowerShell  Veeam.Backup.PowerShell cmdlets. Used on a Windows backup server, where the
	              module is available to job scripts. Sets the real "backup from a storage
	              snapshot at this path" mode (internal ThirdParty).
	  Rest        Veeam REST API v1 on port 9419. The only interface available to job scripts on
	              the Veeam Software Appliance. Refuses the defective builds 13.0/13.1 (see the
	              README) unless Veeam.AcknowledgeRestDefect is set. Kept so the appliance works
	              the day Veeam ships the fix.

	The three operations the orchestration needs: list shares, point a share at a snapshot
	path (failover off, mode enforced), and the same call with a sentinel path as the fail-safe.
#>

#region Session

function Connect-EvpVeeam {
	<#
	.SYNOPSIS
		Opens a Veeam session with the configured or auto-detected backend.
	.DESCRIPTION
		Backend 'auto' picks PowerShell when Veeam.Backup.PowerShell imports and REST otherwise.
	.OUTPUTS
		Session object with Backend, Server and backend-specific fields.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] $Platform
	)

	$backend = $Config.Veeam.Backend
	if ($backend -eq 'auto') {
		$backend = if (Test-EvpVeeamModule) { 'PowerShell' } else { 'Rest' }
		Write-Host "Veeam backend: $backend (auto-detected)"
	} else {
		Write-Host "Veeam backend: $backend (configured)"
	}

	if ($backend -eq 'PowerShell') { return (Connect-EvpVeeamPowerShell -Config $Config -Platform $Platform) }
	return (Connect-EvpVeeamRest -Config $Config -Platform $Platform)
}

function Disconnect-EvpVeeam {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Closes a session; nothing to confirm.')]
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Session)
	if ($Session.Backend -eq 'PowerShell' -and (Get-Command -Name 'Disconnect-VBRServer' -ErrorAction SilentlyContinue)) {
		$p = @{ ErrorAction = 'Stop' }
		if ((Get-Command Disconnect-VBRServer).Parameters.ContainsKey('WhatIf')) { $p['WhatIf'] = $false }
		try { Disconnect-VBRServer @p } catch { Write-Verbose 'Disconnect-VBRServer failed or no session.' }
	}
}

function Test-EvpVeeamModule {
	<# True when the Veeam PowerShell module can be imported and offers Connect-VBRServer. #>
	[CmdletBinding()]
	[OutputType([bool])]
	param()
	if (-not (Get-Module -Name 'Veeam.Backup.PowerShell')) {
		try { Import-Module -Name 'Veeam.Backup.PowerShell' -ErrorAction Stop -WarningAction SilentlyContinue } catch {
			Write-Verbose "Veeam.Backup.PowerShell not importable: $($_.Exception.Message)"
			return $false
		}
	}
	return [bool](Get-Command -Name 'Connect-VBRServer' -ErrorAction SilentlyContinue)
}

function Get-EvpVeeamCredential {
	<# Builds the PSCredential for Veeam from Veeam.User and Veeam.PasswordFile, or $null. #>
	[CmdletBinding()]
	[OutputType([System.Management.Automation.PSCredential])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)
	if (-not $Config.Veeam.User) { return $null }
	Write-Host "Reading the Veeam password for '$($Config.Veeam.User)' from '$($Config.Veeam.PasswordFile)'."
	$password = Unprotect-EvpSecret -Path $Config.Veeam.PasswordFile -Platform $Platform
	return [System.Management.Automation.PSCredential]::new($Config.Veeam.User, $password)
}

#endregion

#region PowerShell backend

function Test-EvpTcpPort {
	[CmdletBinding()]
	[OutputType([bool])]
	param([Parameter(Mandatory)] [string] $ComputerName, [int] $Port = 443, [int] $TimeoutMilliseconds = 5000)
	$client = $null
	try {
		$client = [System.Net.Sockets.TcpClient]::new()
		$connect = $client.BeginConnect($ComputerName, $Port, $null, $null)
		if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
		$client.EndConnect($connect)
		return $true
	} catch { return $false } finally { if ($client) { $client.Dispose() } }
}

function Connect-EvpVeeamPowerShell {
	<#
	.SYNOPSIS
		Opens a Veeam PowerShell session, failing fast instead of hanging.
	.DESCRIPTION
		Veeam runs job scripts as the Backup Service account (LOCAL SYSTEM). On 13.1 the implicit
		connection from that identity usually works, but has been seen failing with "Failed to
		connect to Identity service"; an explicit local user (Veeam.User / Veeam.PasswordFile)
		is the fallback. With no session, a failed connect is fatal: the next cmdlet would
		otherwise block until Veeam's 15-minute script timeout.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	if (-not (Test-EvpVeeamModule)) {
		throw 'The Veeam.Backup.PowerShell module is not available on this host. On the Veeam Software Appliance job scripts cannot use it; set Veeam.Backend to Rest there.'
	}
	$server = $Config.Veeam.Server
	$credential = Get-EvpVeeamCredential -Config $Config -Platform $Platform

	$session = $null
	try { $session = Get-VBRServerSession -ErrorAction Stop } catch { $session = $null }
	if ($session) {
		Write-Host 'Reusing the existing Veeam Backup & Replication session.'
		return [pscustomobject]@{ Backend = 'PowerShell'; Server = $server }
	}

	$portReachable = Test-EvpTcpPort -ComputerName $server -Port 443
	Write-Host 'Veeam connection preflight:'
	Write-Host "  Running as     : $($Platform.Identity)"
	Write-Host "  Target         : ${server}:443"
	Write-Host "  Port reachable : $portReachable"
	Write-Host "  Certificate    : $(if ($Config.Veeam.ForceAcceptTlsCertificate) { 'accepted without validation (ForceAcceptTlsCertificate)' } else { 'validated by Connect-VBRServer' })"
	Write-Host "  Authenticating : $(if ($credential) { "explicit credential '$($credential.UserName)'" } else { 'implicit (service identity)' })"
	if (-not $portReachable) {
		Write-Warning "Nothing is accepting connections on ${server}:443. Check the Veeam Backup Service and the identity service."
	}
	if (-not $Config.Veeam.ForceAcceptTlsCertificate -and -not $Platform.Interactive) {
		Write-Warning 'ForceAcceptTlsCertificate is off in a non-interactive session. An untrusted certificate makes Connect-VBRServer prompt, which nobody can answer, until Veeam kills the script.'
	}

	$connectParams = @{ Server = $server; ErrorAction = 'Stop' }
	# Connecting is not a change; a dry run must still connect, so never let -WhatIf reach it.
	if ((Get-Command Connect-VBRServer).Parameters.ContainsKey('WhatIf')) { $connectParams['WhatIf'] = $false }
	if ($credential) { $connectParams['Credential'] = $credential }
	if ($Config.Veeam.ForceAcceptTlsCertificate) { $connectParams['ForceAcceptTlsCertificate'] = $true }

	Write-Host "Connecting to Veeam Backup & Replication server '$server'..."
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	try {
		Connect-VBRServer @connectParams
	} catch {
		$hints = [System.Collections.Generic.List[string]]::new()
		if ($credential) { $hints.Add("check that '$($credential.UserName)' holds a Veeam role and that the stored password is current") }
		else { $hints.Add("the implicit connection as '$($Platform.Identity)' was refused; configure Veeam.User and Veeam.PasswordFile with a local or domain user holding the Backup Administrator role") }
		if (-not $portReachable) { $hints.Add("nothing is listening on ${server}:443") }
		throw "Could not open a Veeam session to '$server': $($_.Exception.Message). Next steps: $($hints -join '; ')."
	}
	Write-Host "Connected to Veeam Backup & Replication server '$server' in $([int]$sw.Elapsed.TotalSeconds) s."
	return [pscustomobject]@{ Backend = 'PowerShell'; Server = $server }
}

function ConvertTo-EvpShareRecord {
	<# Normalises a share from either backend into the shape the orchestration uses. #>
	param($Id, $Path, $Protocol, $TypeName, $ProcessingMode, $FailoverEnabled, $StorageSnapshotPath, $Raw)
	[pscustomobject]@{
		Id                  = $Id
		Path                = $Path
		Protocol            = $Protocol
		TypeName            = $TypeName
		ProcessingMode      = [string]$ProcessingMode
		FailoverEnabled     = $FailoverEnabled
		StorageSnapshotPath = [string]$StorageSnapshotPath
		Raw                 = $Raw
	}
}

function Get-EvpVeeamSharesPowerShell {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Session',
		Justification = 'Same signature as the REST backend; the PowerShell session is process-global.')]
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Session)
	if (-not (Get-Command -Name 'Get-VBRUnstructuredServer' -ErrorAction SilentlyContinue)) {
		throw 'Get-VBRUnstructuredServer is not available. These scripts need Veeam Backup & Replication 12.1 or later.'
	}
	$all = @(Get-VBRUnstructuredServer -ErrorAction Stop)
	$records = foreach ($s in $all) {
		$typeName = $s.GetType().Name
		$protocol = switch ($typeName) { 'VBRNASSMBServer' { 'SMB' } 'VBRNASNFSServer' { 'NFS' } default { $null } }
		if (-not $protocol) { continue }
		$path = @($s.Path, $s.Name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
		$failover = $null
		if ($s.PSObject.Properties.Name -contains 'DirectBackupFailoverEnabled') { $failover = [bool]$s.DirectBackupFailoverEnabled }
		ConvertTo-EvpShareRecord -Id $s.Id -Path $path -Protocol $protocol -TypeName $typeName -ProcessingMode $s.ProcessingMode -FailoverEnabled $failover -StorageSnapshotPath $s.StorageSnapshotPath -Raw $s
	}
	return @($records)
}

function Set-EvpVeeamSnapshotPathPowerShell {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Session',
		Justification = 'Same signature as the REST backend; the PowerShell session is process-global.')]
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] $Share,
		[Parameter(Mandatory)] [string] $StorageSnapshotPath,
		[bool] $EnsureProcessingMode = $true,
		[bool] $Failover = $false
	)
	$cmdletName = switch ($Share.TypeName) {
		'VBRNASSMBServer' { 'Set-VBRNASSMBServer' }
		'VBRNASNFSServer' { 'Set-VBRNASNFSServer' }
		default { throw "Share '$($Share.Path)' has type '$($Share.TypeName)', which is not supported. Only SMB shares and NFS exports can back up from a storage snapshot path." }
	}
	$command = Get-Command -Name $cmdletName -ErrorAction SilentlyContinue
	if (-not $command) { throw "The Veeam cmdlet '$cmdletName' is not available in this version of the Veeam PowerShell module." }

	$setParams = @{ Server = $Share.Raw; StorageSnapshotPath = $StorageSnapshotPath; ErrorAction = 'Stop' }
	if ($command.Parameters.ContainsKey('EnableDirectBackupFailover')) { $setParams['EnableDirectBackupFailover'] = $Failover }
	if ($EnsureProcessingMode -and $command.Parameters.ContainsKey('ProcessingMode')) { $setParams['ProcessingMode'] = 'StorageSnapshot' }

	Write-Host "Pointing $($Share.Protocol) share '$($Share.Path)' at '$StorageSnapshotPath' ($cmdletName, failover $(if ($Failover) { 'ON' } else { 'off' })$(if ($EnsureProcessingMode) { ', mode StorageSnapshot' }))..."
	if ($PSCmdlet.ShouldProcess($Share.Path, "$cmdletName -StorageSnapshotPath '$StorageSnapshotPath'")) {
		& $cmdletName @setParams | Out-Null
	}
	return $StorageSnapshotPath
}

#endregion

#region REST backend

function Get-EvpVeeamRestUri {
	param($Session, [string] $Path)
	return 'https://{0}:{1}{2}' -f $Session.Server, $Session.Port, $Path
}

function Invoke-EvpVeeamRest {
	<# Authenticated call to the Veeam REST API; throws with Veeam's message on failure. #>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Session,
		[string] $Method = 'GET',
		[Parameter(Mandatory)] [string] $Path,
		$Body
	)
	$headers = @{ 'x-api-version' = $Session.ApiVersion; 'Authorization' = "Bearer $($Session.Token)"; 'Accept' = 'application/json' }
	$r = Invoke-EvpHttp -Method $Method -Uri (Get-EvpVeeamRestUri $Session $Path) -Headers $headers -Body $Body -Tls $Session.Tls
	if (-not $r.Success) { throw "Veeam REST $Method $Path failed: $(Get-EvpHttpErrorText $r)" }
	return $r.Body
}

function Connect-EvpVeeamRest {
	<#
	.SYNOPSIS
		Obtains a Veeam REST token with the password grant and checks the server build.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$server = $Config.Veeam.Server
	if ($Platform.IsLinux -and $server -match '^(localhost|127\.|::1)') {
		throw "Veeam.Server is '$server'. On the Veeam Software Appliance the firewall rejects loopback traffic from job scripts; use the appliance FQDN or LAN address."
	}
	if (-not $Config.Veeam.User) {
		throw 'The REST backend needs Veeam.User and Veeam.PasswordFile (a local Veeam user flagged as service account, MFA off).'
	}
	$credential = Get-EvpVeeamCredential -Config $Config -Platform $Platform
	$session = [pscustomobject]@{
		Backend    = 'Rest'
		Server     = $server
		Port       = $Config.Veeam.Port
		ApiVersion = $Config.Veeam.ApiVersion
		Tls        = $Config.Veeam.Tls
		Token      = $null
		Build      = $null
	}

	Write-Host "Requesting a Veeam REST token from https://${server}:$($session.Port) as '$($credential.UserName)'..."
	$form = 'grant_type=password&username={0}&password={1}' -f [uri]::EscapeDataString($credential.UserName), [uri]::EscapeDataString((ConvertFrom-EvpSecureString $credential.Password))
	$r = Invoke-EvpHttp -Method POST -Uri (Get-EvpVeeamRestUri $session '/api/oauth2/token') -Headers @{ 'x-api-version' = $session.ApiVersion } -Body $form -ContentType 'application/x-www-form-urlencoded' -Tls $session.Tls
	$form = $null
	if (-not $r.Success) { throw "Veeam REST login failed: $(Get-EvpHttpErrorText $r)" }
	$session.Token = $r.Body.access_token

	$info = Invoke-EvpVeeamRest -Session $session -Path '/api/v1/serverInfo'
	$session.Build = [string]$info.buildVersion
	Write-Host "Connected to Veeam REST API on '$server' (build $($session.Build), platform $($info.platform))."

	# The fixed build is not known yet; widen or remove this gate once Veeam names it.
	if ($session.Build -match '^13\.(0|1)\.' -and -not $Config.Veeam.AcknowledgeRestDefect) {
		throw "Veeam build $($session.Build) maps the REST processingMode 'StorageSnapshot' to the wrong internal mode, so a share repointed through REST silently reads the live share. Use the PowerShell backend on a Windows server, or set Veeam.AcknowledgeRestDefect to true to proceed anyway at your own risk."
	}
	return $session
}

function Get-EvpVeeamSharesRest {
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Session)
	$body = Invoke-EvpVeeamRest -Session $Session -Path '/api/v1/inventory/unstructuredDataServers?limit=500'
	$records = foreach ($s in @($body.data)) {
		$protocol = switch ($s.type) { 'SMBShare' { 'SMB' } 'NFSShare' { 'NFS' } default { $null } }
		if (-not $protocol) { continue }
		$adv = $s.advancedSettings
		ConvertTo-EvpShareRecord -Id $s.id -Path $s.path -Protocol $protocol -TypeName $s.type -ProcessingMode $adv.processingMode -FailoverEnabled $adv.directBackupFailoverEnabled -StorageSnapshotPath $adv.storageSnapshotPath -Raw $s
	}
	return @($records)
}

function Set-EvpVeeamSnapshotPathRest {
	<#
	.SYNOPSIS
		PUTs the share with new advancedSettings and waits for the FileServerSave session.
	.DESCRIPTION
		The PUT is asynchronous: it returns a session, not the updated model. Two PUTs on one
		share in flight at the same time raced in the lab and applied out of order, so this
		function always waits for completion before returning.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] $Share,
		[Parameter(Mandatory)] [string] $StorageSnapshotPath,
		[bool] $EnsureProcessingMode = $true,
		[bool] $Failover = $false,
		[int] $TimeoutSec = 120
	)
	$model = Invoke-EvpVeeamRest -Session $Session -Path "/api/v1/inventory/unstructuredDataServers/$($Share.Id)"
	$adv = $model.advancedSettings
	$adv.storageSnapshotPath = $StorageSnapshotPath
	$adv.directBackupFailoverEnabled = $Failover
	if ($EnsureProcessingMode) { $adv.processingMode = 'StorageSnapshot' }

	Write-Host "Pointing $($Share.Protocol) share '$($Share.Path)' at '$StorageSnapshotPath' (REST PUT, failover $(if ($Failover) { 'ON' } else { 'off' })$(if ($EnsureProcessingMode) { ', mode StorageSnapshot' }))..."
	if (-not $PSCmdlet.ShouldProcess($Share.Path, "PUT unstructuredDataServers storageSnapshotPath '$StorageSnapshotPath'")) { return $StorageSnapshotPath }

	$save = Invoke-EvpVeeamRest -Session $Session -Method PUT -Path "/api/v1/inventory/unstructuredDataServers/$($Share.Id)" -Body $model
	$sessionId = $save.id
	if (-not $sessionId) { return $StorageSnapshotPath }
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	do {
		Start-Sleep -Seconds 2
		$state = Invoke-EvpVeeamRest -Session $Session -Path "/api/v1/sessions/$sessionId"
	} while ($state.state -ne 'Stopped' -and (Get-Date) -lt $deadline)
	if ($state.state -ne 'Stopped') { throw "Veeam did not finish saving share '$($Share.Path)' within $TimeoutSec s (session $sessionId still $($state.state))." }
	if ($state.result.result -ne 'Success') { throw "Veeam failed to save share '$($Share.Path)': $($state.result.message)" }
	return $StorageSnapshotPath
}

#endregion

#region Interface

function Get-EvpVeeamShares {
	<# Lists SMB shares and NFS exports in the inventory as normalised records. #>
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Session)
	$shares = if ($Session.Backend -eq 'PowerShell') { Get-EvpVeeamSharesPowerShell -Session $Session } else { Get-EvpVeeamSharesRest -Session $Session }
	Write-Host "Veeam inventory: $(@($shares).Count) SMB/NFS share(s)."
	return @($shares)
}

function Find-EvpVeeamShare {
	<#
	.SYNOPSIS
		Returns exactly one inventory share for a configured VeeamPath, or throws.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Shares,
		[Parameter(Mandatory)] [string] $VeeamPath
	)
	$wanted = Get-EvpNormalizedSharePath -VeeamPath $VeeamPath
	$protocol = Get-EvpShareProtocol -VeeamPath $VeeamPath
	$found = @($Shares | Where-Object { $_.Path -and (Get-EvpNormalizedSharePath -VeeamPath $_.Path) -eq $wanted -and $_.Protocol -eq $protocol })
	if ($found.Count -eq 0) {
		$known = ($Shares | ForEach-Object { $_.Path } | Sort-Object) -join ', '
		throw "Share '$VeeamPath' is not in the Veeam inventory. Known SMB/NFS shares: $known"
	}
	if ($found.Count -gt 1) { throw "Share '$VeeamPath' matches $($found.Count) inventory entries; the path must identify exactly one." }
	return $found[0]
}

function Set-EvpVeeamStorageSnapshotPath {
	<#
	.SYNOPSIS
		Points a share at a storage snapshot path with failover off (or on, for a live fallback), through the session's backend.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] $Share,
		[Parameter(Mandatory)] [string] $StorageSnapshotPath,
		[bool] $EnsureProcessingMode = $true,
		[bool] $Failover = $false
	)
	# -WhatIf is forwarded explicitly: $WhatIfPreference does not reliably cross function
	# boundaries on every PowerShell 7 release.
	if ($Session.Backend -eq 'PowerShell') {
		return (Set-EvpVeeamSnapshotPathPowerShell -Session $Session -Share $Share -StorageSnapshotPath $StorageSnapshotPath -EnsureProcessingMode $EnsureProcessingMode -Failover $Failover -WhatIf:$WhatIfPreference)
	}
	return (Set-EvpVeeamSnapshotPathRest -Session $Session -Share $Share -StorageSnapshotPath $StorageSnapshotPath -EnsureProcessingMode $EnsureProcessingMode -Failover $Failover -WhatIf:$WhatIfPreference)
}

#endregion

#region Job binding (Veeam.JobId)

function Get-EvpVeeamObjectLabel {
	<#
	.SYNOPSIS
		Names a job object that has no path, for the list of skipped objects.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] $Object)
	$kind = if ($Object.Server -and $Object.Server.Type) { [string]$Object.Server.Type } else { $Object.GetType().Name }
	$name = if ($Object.Server -and $Object.Server.Name) { [string]$Object.Server.Name } elseif ($Object.Name) { [string]$Object.Name } else { $null }
	if ($name) { return "$name ($kind)" }
	return "$kind object without a path"
}

function Get-EvpVeeamJob {
	<#
	.SYNOPSIS
		Looks up the Veeam job a configuration is bound to (Veeam.JobId): a file backup job or a
		file-to-tape job.
	.DESCRIPTION
		The two kinds differ in every cmdlet involved, so this function hides them behind one
		record. File backup: Get-VBRUnstructuredBackupJob -Id, share behind
		BackupObject[].Server.Path. File-to-tape: Get-VBRTapeJob has no -Id, so all tape jobs are
		listed and filtered; the share is Object[].Server.Name (Object[].Path carries an
		'nfs41://' prefix for NFS). A sub-folder or single-file object resolves to its share.
		An object without a path, such as the bucket of an object-storage-to-tape job (Veeam
		types that job FileToTape too), is listed in Skipped by its server type.
	.OUTPUTS
		Record with Id, Name, Type, Kind ('FileBackup' or 'FileToTape'), Shares (Path, Protocol,
		InventoryId per share, deduplicated), ShareRoots (their paths), Skipped (objects that
		are not SMB or NFS shares) and Raw (the job object). Shares and ShareRoots are $null
		when the backend cannot list the job objects (REST).
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $JobId)

	$JobId = $JobId.ToLowerInvariant()
	if ($Session.Backend -eq 'PowerShell') {
		$job = $null
		$kind = 'FileBackup'
		try { $job = Get-VBRUnstructuredBackupJob -Id $JobId -ErrorAction Stop -WarningAction SilentlyContinue } catch { $job = $null }
		if (-not $job -and (Get-Command -Name 'Get-VBRTapeJob' -ErrorAction SilentlyContinue)) {
			$job = @(Get-VBRTapeJob -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { ([string]$_.Id).ToLowerInvariant() -eq $JobId }) | Select-Object -First 1
			if ($job -and [string]$job.Type -ne 'FileToTape') {
				throw "Job '$($job.Name)' ($JobId) is a $($job.Type) tape job. Only file backup and file-to-tape jobs read shares, so only those can be backed up from storage snapshots."
			}
			$kind = 'FileToTape'
		}
		if (-not $job) { throw "No file backup or file-to-tape job with ID '$JobId' exists on this backup server. Veeam.JobId is stale (job deleted and re-created?) or belongs to another server." }

		$objects = if ($kind -eq 'FileBackup') {
			@($job.BackupObject | ForEach-Object {
					$path = if ($_.Server -and $_.Server.Path) { [string]$_.Server.Path } else { [string]$_.Path }
					[pscustomobject]@{ Path = $path; InventoryId = if ($_.Server) { [string]$_.Server.Id } else { $null }; Label = (Get-EvpVeeamObjectLabel $_) }
				})
		} else {
			@($job.Object | ForEach-Object {
					$path = if ($_.Server -and $_.Server.Name) { [string]$_.Server.Name } else { [string]$_.Path -replace '^nfs\d*://', '' }
					[pscustomobject]@{ Path = $path; InventoryId = if ($_.Server) { [string]$_.Server.Id } else { $null }; Label = (Get-EvpVeeamObjectLabel $_) }
				})
		}
		$shares = [System.Collections.Generic.List[object]]::new()
		$skipped = [System.Collections.Generic.List[string]]::new()
		$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($o in $objects) {
			if (-not $o.Path) { $skipped.Add($o.Label); continue }
			$protocol = Get-EvpShareProtocol -VeeamPath $o.Path
			if (-not $protocol) { $skipped.Add($o.Path); continue }
			if (-not $seen.Add((Get-EvpNormalizedSharePath -VeeamPath $o.Path))) { continue }
			$id = if ($o.InventoryId) { $o.InventoryId.ToLowerInvariant() } else { $null }
			$shares.Add([pscustomobject]@{ Path = $o.Path; Protocol = $protocol; InventoryId = $id })
		}
		return [pscustomobject]@{
			Id         = ([string]$job.Id).ToLowerInvariant()
			Name       = [string]$job.Name
			Type       = $job.GetType().Name
			Kind       = $kind
			Shares     = $shares.ToArray()
			ShareRoots = @($shares | ForEach-Object { $_.Path })
			Skipped    = $skipped.ToArray()
			Raw        = $job
		}
	}
	# REST: /api/v1/jobs/{id}. Whether a build lists file backup jobs there is not guaranteed.
	try {
		$job = Invoke-EvpVeeamRest -Session $Session -Path "/api/v1/jobs/$JobId"
	} catch { throw "Job '$JobId' could not be read through the REST API: $($_.Exception.Message)" }
	if (-not $job -or -not $job.id) { throw "No job with ID '$JobId' exists on this backup server. Veeam.JobId is stale or belongs to another server." }
	return [pscustomobject]@{ Id = ([string]$job.id).ToLowerInvariant(); Name = [string]$job.name; Type = [string]$job.type; Kind = 'FileBackup'; Shares = $null; ShareRoots = $null; Skipped = @(); Raw = $job }
}

function Find-EvpVeeamJobByName {
	<#
	.SYNOPSIS
		Finds file backup and file-to-tape jobs by name (PowerShell backend). For the generator.
	.OUTPUTS
		Zero or more records with Id, Name and Kind.
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] [string] $Name)
	$found = [System.Collections.Generic.List[object]]::new()
	foreach ($j in @(Get-VBRUnstructuredBackupJob -Name $Name -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
		if ($j) { $found.Add([pscustomobject]@{ Id = ([string]$j.Id).ToLowerInvariant(); Name = [string]$j.Name; Kind = 'FileBackup' }) }
	}
	if (Get-Command -Name 'Get-VBRTapeJob' -ErrorAction SilentlyContinue) {
		foreach ($j in @(Get-VBRTapeJob -Name $Name -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { [string]$_.Type -eq 'FileToTape' })) {
			$found.Add([pscustomobject]@{ Id = ([string]$j.Id).ToLowerInvariant(); Name = [string]$j.Name; Kind = 'FileToTape' })
		}
	}
	return $found.ToArray()
}

function Get-EvpVeeamActiveJobSessions {
	<#
	.SYNOPSIS
		Lists the sessions of a job that are not stopped, i.e. the run a job script belongs to.
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] $Job)

	if ($Session.Backend -eq 'PowerShell') {
		# Filtered by job: Get-VBRBackupSession without a filter walks every session on the server,
		# and Get-VBRSession -Job warns that it does not support tape jobs.
		# A session is named after the job plus the kind of run: 'files (Full)' for an active full
		# on 13.1.1.18, so an exact -Name misses it. The name is a prefix match here, with the
		# job's own wildcard characters escaped, and the JobId filter below decides.
		$all = if ($Job.Kind -eq 'FileToTape') {
			@(Get-VBRTapeBackupSession -Job $Job.Raw -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
		} else {
			@(Get-VBRUnstructuredBackupSession -Name ('{0}*' -f [WildcardPattern]::Escape($Job.Name)) -ErrorAction SilentlyContinue)
		}
		return @($all | Where-Object { ([string]$_.JobId).ToLowerInvariant() -eq $Job.Id -and [string]$_.State -ne 'Stopped' } | ForEach-Object {
				[pscustomobject]@{ Id = [string]$_.Id; State = [string]$_.State; CreationTime = $_.CreationTime } })
	}
	$body = Invoke-EvpVeeamRest -Session $Session -Path "/api/v1/sessions?jobIdFilter=$($Job.Id)&limit=200"
	return @($body.data | Where-Object { [string]$_.state -ne 'Stopped' } | ForEach-Object {
			[pscustomobject]@{ Id = [string]$_.id; State = [string]$_.state; CreationTime = $_.creationTime } })
}

function Assert-EvpVeeamJobSession {
	<#
	.SYNOPSIS
		Job guard: proves that the configured job is the one running this script.
	.DESCRIPTION
		Veeam gives a pre/post-job script no hint which job started it. A cloned job inherits the
		script settings and would therefore repoint this job's shares and destroy its snapshots.
		Veeam runs job scripts inside the job session, so a session of Veeam.JobId must be active
		right now; otherwise the caller is a different job and the phase stops before changing
		anything. With -WarnOnly (dry runs) a missing session is only reported.
		With the guard turned off for the run (-NoJobGuard) the job is still read, for its shares.
	.OUTPUTS
		The job record, or $null when no Veeam.JobId is configured.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] [string] $Phase,
		[switch] $WarnOnly
	)

	if (-not $Config.Veeam.JobId) { return $null }
	$job = Get-EvpVeeamJob -Session $Session -JobId $Config.Veeam.JobId
	if (-not $Config.Veeam.JobGuard) {
		Write-Host "Job guard: disabled for this run; job '$($job.Name)' ($($job.Id), $($job.Kind)) read for its shares."
		return $job
	}
	$active = @(Get-EvpVeeamActiveJobSessions -Session $Session -Job $job)
	$detail = if ($active.Count) { ': ' + (($active | ForEach-Object { "$($_.State) since $($_.CreationTime)" }) -join ', ') } else { '' }
	Write-Host "Job guard: bound to '$($job.Name)' ($($job.Id), $($job.Kind)), $($active.Count) active session(s)$detail."
	if ($active.Count -eq 0) {
		$message = "Job guard: no session of job '$($job.Name)' ($($job.Id)) is running, so this $Phase script was not started by that job. Most likely a cloned job inherited the script settings; give the clone its own configuration file (New-EverpureVeeamJobScripts.ps1). For a manual run add -NoJobGuard."
		if ($WarnOnly) { Write-Warning "$message (dry run: continuing)"; return $job }
		throw "$message Nothing was changed."
	}
	return $job
}

#endregion
