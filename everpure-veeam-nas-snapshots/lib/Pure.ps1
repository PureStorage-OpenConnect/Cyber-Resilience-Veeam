# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Purity REST client for FlashArray File and FlashBlade behind one interface. Both log in
	with an API token (header api-token -> x-auth-token) and report their kind in GET arrays
	(os = Purity//FA or Purity//FB). Differences are confined to the per-platform branches:

	  FlashArray  directory-snapshots with client_name, suffix and keep_for;
	              share -> managed directory through directory-exports (filtered by protocol,
	              because one export name can exist once per SMB and once per NFS policy).
	  FlashBlade  file-system-snapshots with suffix only (retention lives in policies);
	              share -> file system by name, then by smb.share_name / nfs.export_name.
	              FlashBlade ignores unknown query parameters silently (source_names returned
	              every snapshot on the array in the lab), so listing always uses filter= and
	              every item's source.name is re-checked before it is destroyed.
#>

#region Session

function Get-EvpArrayApiVersion {
	<# Highest 2.x REST version the array offers. Returns the version and the detected platform. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] [string] $Endpoint, [string] $Tls = 'skip')
	$r = Invoke-EvpHttp -Uri "https://$Endpoint/api/api_version" -Tls $Tls
	if (-not $r.Success) { throw "Array '$Endpoint' did not answer GET /api/api_version: $(Get-EvpHttpErrorText $r)" }
	$list = $null; $hint = $null
	if ($r.Body.PSObject.Properties.Name -contains 'versions') { $list = @($r.Body.versions); $hint = 'FlashBlade' }
	elseif ($r.Body.PSObject.Properties.Name -contains 'version') { $list = @($r.Body.version); $hint = 'FlashArray' }
	else { throw "Array '$Endpoint' returned an unexpected api_version document." }
	$v2 = @($list | Where-Object { "$_" -match '^2\.\d+$' } | Sort-Object { [version]$_ } -Descending)
	if ($v2.Count -eq 0) { throw "Array '$Endpoint' offers no REST 2.x version (found: $($list -join ', '))." }
	return [pscustomobject]@{ Version = [string]$v2[0]; PlatformHint = $hint }
}

function Connect-EvpArray {
	<#
	.SYNOPSIS
		Logs in to a FlashArray or FlashBlade with an API token and detects which it is.
	.OUTPUTS
		Session object: Name, Endpoint, Platform, ApiVersion, BaseUri, Headers, Tls, ArrayName,
		PurityVersion.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $ArrayConfig,
		[Parameter(Mandatory)] [System.Security.SecureString] $ApiToken
	)
	$endpoint = $ArrayConfig.Endpoint
	$tls = $ArrayConfig.Tls
	$api = Get-EvpArrayApiVersion -Endpoint $endpoint -Tls $tls
	$platform = if ($ArrayConfig.Platform -ne 'auto') { $ArrayConfig.Platform } else { $api.PlatformHint }
	if ($ArrayConfig.Platform -ne 'auto' -and $api.PlatformHint -and $api.PlatformHint -ne $ArrayConfig.Platform) {
		throw "Arrays['$($ArrayConfig.Name)'].Platform says $($ArrayConfig.Platform) but the API of '$endpoint' looks like $($api.PlatformHint). Fix the setting or use 'auto'."
	}

	$loginPath = if ($platform -eq 'FlashBlade') { '/api/login' } else { "/api/$($api.Version)/login" }
	Write-Host "Connecting to $platform '$endpoint' (REST $($api.Version)) with an API token..."
	$token = ConvertFrom-EvpSecureString $ApiToken
	try {
		$r = Invoke-EvpHttp -Method POST -Uri "https://$endpoint$loginPath" -Headers @{ 'api-token' = $token } -Tls $tls
	} finally { $token = $null }
	if (-not $r.Success) { throw "Login to '$endpoint' failed: $(Get-EvpHttpErrorText $r)" }
	$auth = $r.Headers['x-auth-token']
	if (-not $auth) { throw "Login to '$endpoint' returned no x-auth-token header." }

	$session = [pscustomobject]@{
		Name          = $ArrayConfig.Name
		Endpoint      = $endpoint
		Platform      = $platform
		ApiVersion    = $api.Version
		BaseUri       = "https://$endpoint/api/$($api.Version)"
		Headers       = @{ 'x-auth-token' = $auth }
		Tls           = $tls
		ArrayName     = $null
		PurityVersion = $null
	}
	$arrays = @(Invoke-EvpArrayApi -Session $session -Path 'arrays')
	if ($arrays.Count -gt 0) {
		$session.ArrayName = [string]$arrays[0].name
		$session.PurityVersion = [string]$arrays[0].version
		$os = [string]$arrays[0].os
		$detected = if ($os -like '*FB*') { 'FlashBlade' } elseif ($os -like '*FA*') { 'FlashArray' } else { $null }
		if ($detected -and $detected -ne $platform) {
			if ($ArrayConfig.Platform -ne 'auto') { throw "Arrays['$($ArrayConfig.Name)'].Platform says $platform but '$endpoint' reports os '$os'." }
			$session.Platform = $detected
		}
	}
	Write-Host "Connected to $($session.Platform) '$($session.ArrayName)' ($endpoint), Purity $($session.PurityVersion)."
	return $session
}

function Invoke-EvpArrayApi {
	<#
	.SYNOPSIS
		Calls the Purity REST API and returns the items (following continuation tokens on GET).
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Session,
		[string] $Method = 'GET',
		[Parameter(Mandatory)] [string] $Path,
		[hashtable] $Query = @{},
		$Body
	)
	$items = [System.Collections.Generic.List[object]]::new()
	$continuation = $null
	do {
		$q = @{} + $Query
		if ($continuation) { $q['continuation_token'] = $continuation }
		$qs = ($q.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f [uri]::EscapeDataString($_.Name), [uri]::EscapeDataString([string]$_.Value) }) -join '&'
		$uri = "$($Session.BaseUri)/$Path" + $(if ($qs) { "?$qs" } else { '' })
		$r = Invoke-EvpHttp -Method $Method -Uri $uri -Headers $Session.Headers -Body $Body -Tls $Session.Tls
		if (-not $r.Success) { throw "$($Session.Platform) '$($Session.Endpoint)' $Method $Path failed: $(Get-EvpHttpErrorText $r)" }
		$body = $r.Body
		if ($null -ne $body -and $body.PSObject.Properties.Name -contains 'items') { foreach ($i in @($body.items)) { if ($null -ne $i) { $items.Add($i) } } }
		elseif ($null -ne $body) { $items.Add($body) }
		$continuation = if ($Method -eq 'GET' -and $null -ne $body -and $body.PSObject.Properties.Name -contains 'continuation_token') { $body.continuation_token } else { $null }
	} while ($continuation)
	return $items.ToArray()
}

#endregion

#region Source resolution

function Resolve-EvpArraySource {
	<#
	.SYNOPSIS
		Maps a Veeam share to the array object that gets snapshotted.
	.DESCRIPTION
		An explicit Share.Source wins. Otherwise FlashArray resolves the export name through
		directory-exports (filtered by the share's protocol) to a managed directory, and
		FlashBlade resolves the share name to a file system. The result carries whether the
		snapshot directory is exposed, which the verify phase reports.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] $Share)

	if ($Share.Source -and $Share.Source -ne 'auto') {
		return (Get-EvpArraySourceInfo -Session $Session -SourceName $Share.Source)
	}
	$shareName = $Share.ShareName
	if ($Session.Platform -eq 'FlashArray') {
		$exports = @(Invoke-EvpArrayApi -Session $Session -Path 'directory-exports' -Query @{ export_names = $shareName })
		$proto = $Share.Protocol.ToLowerInvariant()
		$matching = @($exports | Where-Object { [string]$_.policy.resource_type -like "*$proto*" -or [string]$_.policy.resource_type -eq '' })
		if ($matching.Count -eq 0 -and $exports.Count -gt 0) { throw "FlashArray export '$shareName' exists but not for $($Share.Protocol) (policies: $(($exports | ForEach-Object { $_.policy.resource_type }) -join ', '))." }
		$dirs = @($matching | ForEach-Object { [string]$_.directory.name } | Sort-Object -Unique)
		if ($dirs.Count -eq 0) { throw "FlashArray '$($Session.Endpoint)' has no directory export named '$shareName'. Check the share name or set Shares[].Source to the managed directory explicitly." }
		if ($dirs.Count -gt 1) { throw "FlashArray export '$shareName' maps to $($dirs.Count) directories ($($dirs -join ', ')); set Shares[].Source explicitly." }
		return (Get-EvpArraySourceInfo -Session $Session -SourceName $dirs[0])
	}
	# FlashBlade: the file system name is the default share/export name; explicit names override.
	$fs = @(Invoke-EvpArrayApi -Session $Session -Path 'file-systems' -Query @{ names = $shareName } -ErrorAction SilentlyContinue)
	if ($fs.Count -eq 0) {
		$field = if ($Share.Protocol -eq 'SMB') { 'smb.share_name' } else { 'nfs.export_name' }
		$fs = @(Invoke-EvpArrayApi -Session $Session -Path 'file-systems' -Query @{ filter = "$field='$shareName'" })
	}
	if ($fs.Count -eq 0) { throw "FlashBlade '$($Session.Endpoint)' has no file system named or exported as '$shareName'." }
	if ($fs.Count -gt 1) { throw "FlashBlade share '$shareName' matches $($fs.Count) file systems; set Shares[].Source explicitly." }
	return (ConvertTo-EvpSourceInfo -Session $Session -Item $fs[0])
}

function Get-EvpArraySourceInfo {
	<# Fetches one source by name and returns its info record. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $SourceName)
	$path = if ($Session.Platform -eq 'FlashArray') { 'directories' } else { 'file-systems' }
	$items = @(Invoke-EvpArrayApi -Session $Session -Path $path -Query @{ names = $SourceName })
	if ($items.Count -eq 0) { throw "$($Session.Platform) '$($Session.Endpoint)' has no $(if ($Session.Platform -eq 'FlashArray') { 'managed directory' } else { 'file system' }) named '$SourceName'." }
	return (ConvertTo-EvpSourceInfo -Session $Session -Item $items[0])
}

function ConvertTo-EvpSourceInfo {
	param($Session, $Item)
	$snapDirEnabled = $null
	if ($Session.Platform -eq 'FlashBlade' -and $Item.PSObject.Properties.Name -contains 'snapshot_directory_enabled') { $snapDirEnabled = [bool]$Item.snapshot_directory_enabled }
	[pscustomobject]@{
		Name                     = [string]$Item.name
		Platform                 = $Session.Platform
		SnapshotDirectoryEnabled = $snapDirEnabled
	}
}

#endregion

#region Snapshots

function New-EvpArraySnapshot {
	<#
	.SYNOPSIS
		Creates one snapshot of a source with the unified naming scheme.
	.OUTPUTS
		The naming record from New-EvpSnapshotName with ArrayName set to what the array reports.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] [string] $SourceName,
		[Parameter(Mandatory)] [string] $Tag,
		[string] $Timestamp = (Get-EvpTimestamp),
		[long] $KeepForMs = 0
	)
	$naming = New-EvpSnapshotName -Tag $Tag -Platform $Session.Platform -SourceName $SourceName -Timestamp $Timestamp
	if ($Session.Platform -eq 'FlashArray') {
		$body = @{ client_name = $naming.ClientName; suffix = $naming.Suffix }
		if ($KeepForMs -gt 0) { $body['keep_for'] = $KeepForMs }
		$path = 'directory-snapshots'
	} else {
		$body = @{ suffix = $naming.Suffix }
		$path = 'file-system-snapshots'
	}
	Write-Host "Creating $($Session.Platform) snapshot '$($naming.ArrayName)' on '$($Session.Endpoint)'$(if ($KeepForMs -gt 0) { " (keep_for $KeepForMs ms)" })..."
	if ($PSCmdlet.ShouldProcess("$($Session.Endpoint)/$SourceName", "POST $path suffix '$($naming.Suffix)'")) {
		$created = @(Invoke-EvpArrayApi -Session $Session -Method POST -Path $path -Query @{ source_names = $SourceName } -Body $body)
		if ($created.Count -gt 0 -and $created[0].name) { $naming.ArrayName = [string]$created[0].name }
		Write-Host "Created snapshot '$($naming.ArrayName)'."
	}
	return $naming
}

function Get-EvpArraySnapshots {
	<#
	.SYNOPSIS
		Lists the snapshots of one source, verifying each item's source before returning it.
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $SourceName)
	if ($Session.Platform -eq 'FlashArray') {
		$items = @(Invoke-EvpArrayApi -Session $Session -Path 'directory-snapshots' -Query @{ source_names = $SourceName })
	} else {
		$items = @(Invoke-EvpArrayApi -Session $Session -Path 'file-system-snapshots' -Query @{ filter = "source.name='$SourceName'" })
	}
	$records = foreach ($i in $items) {
		$src = [string]$i.source.name
		if ($src -and $src -ne $SourceName) { Write-Verbose "Ignoring snapshot '$($i.name)' of other source '$src'."; continue }
		[pscustomobject]@{
			Name       = [string]$i.name
			SourceName = $src
			Destroyed  = [bool]$i.destroyed
			Created    = if ($i.created) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$i.created).UtcDateTime } else { $null }
		}
	}
	return @($records)
}

function Remove-EvpArraySnapshots {
	<#
	.SYNOPSIS
		Destroys the given snapshots (not eradicated; recoverable until the array's delay expires).
	.OUTPUTS
		Summary with Destroyed, AlreadyDestroyed and Failed counts.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Snapshots
	)
	$path = if ($Session.Platform -eq 'FlashArray') { 'directory-snapshots' } else { 'file-system-snapshots' }
	$summary = [pscustomobject]@{ Destroyed = 0; AlreadyDestroyed = 0; Failed = 0 }
	foreach ($s in $Snapshots) {
		if ($s.Destroyed) { Write-Host "Snapshot '$($s.Name)' was already destroyed."; $summary.AlreadyDestroyed++; continue }
		if ($PSCmdlet.ShouldProcess($s.Name, "PATCH $path destroyed=true")) {
			Write-Host "Destroying snapshot '$($s.Name)'..."
			try {
				Invoke-EvpArrayApi -Session $Session -Method PATCH -Path $path -Query @{ names = $s.Name } -Body @{ destroyed = $true } | Out-Null
				$summary.Destroyed++
			} catch {
				Write-Warning "Could not destroy '$($s.Name)': $($_.Exception.Message)"
				$summary.Failed++
			}
		}
	}
	return $summary
}

#endregion
