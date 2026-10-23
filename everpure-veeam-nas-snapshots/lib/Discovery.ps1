# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Discovery: which shares a run covers, which array serves each of them, and the state the last
	run left behind.

	  Shares   the bound job's SMB/NFS objects, with Shares entries as per-share overrides; the
	           Shares list itself when the job cannot tell (no Veeam.JobId, REST backend).
	  Arrays   a share without an Array override belongs to the array that owns one of its host
	           addresses as a file interface (FlashArray service 'file', FlashBlade 'data'). The
	           array the cache recorded is asked first; every array only when that fails. An
	           unreachable array is a warning as long as every share still maps somewhere.
	  State    <profile>.state.json: the shares, their arrays and sources of the last run. Used to
	           ask the right array first and to keep cleaning up sources whose share has left the
	           job. Never overrides what the job and the arrays say in the current run.
#>

#region Share list

function Get-EvpRunShares {
	<#
	.SYNOPSIS
		The shares this run covers, as fresh records the run may annotate.
	.PARAMETER Job
		Job record from Get-EvpVeeamJob, or $null. Its Shares are the share list unless they are
		$null (the backend cannot list job objects).
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param([Parameter(Mandatory)] $Config, $Job)

	$overrides = [ordered]@{}
	foreach ($s in $Config.Shares) { $overrides[(Get-EvpNormalizedSharePath -VeeamPath $s.VeeamPath)] = $s }

	if ($Job -and $null -ne $Job.Shares) {
		foreach ($p in $Job.Skipped) { Write-Warning "Job object '$p' is not an SMB share or NFS export; the job reads it as is, not from a snapshot." }
		$list = [System.Collections.Generic.List[object]]::new()
		$used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($js in $Job.Shares) {
			$key = Get-EvpNormalizedSharePath -VeeamPath $js.Path
			$o = $overrides[$key]
			if ($o) { $null = $used.Add($key) }
			$list.Add((New-EvpShareRecord -VeeamPath $js.Path -Array $(if ($o) { $o.Array }) -Source $(if ($o) { $o.Source } else { 'auto' }) -InventoryId $js.InventoryId -Origin 'job'))
		}
		foreach ($key in $overrides.Keys) {
			if (-not $used.Contains($key)) { Write-Warning "Shares lists '$($overrides[$key].VeeamPath)', which is not part of job '$($Job.Name)'; the entry is ignored." }
		}
		if ($list.Count -eq 0) { throw "Job '$($Job.Name)' contains no SMB share or NFS export, so there is nothing to back up from a snapshot." }
		Write-Host "Shares of job '$($Job.Name)': $($list.Count)$(if ($used.Count) { ", $($used.Count) with an override from Shares" })."
		return $list.ToArray()
	}
	if ($Config.Shares.Count -eq 0) {
		throw 'The shares cannot be read from the job (the REST backend does not list job objects), and Shares lists none. List the shares in Shares.'
	}
	# Copies, so one run's mapping never leaks into the loaded configuration.
	return @($Config.Shares | ForEach-Object { New-EvpShareRecord -VeeamPath $_.VeeamPath -Array $_.Array -Source $_.Source -Origin 'config' })
}

#endregion

#region Mapping shares to arrays

function Resolve-EvpShareHostAddress {
	<# Addresses of a share host: the literal for an IP address, all DNS records for a name. #>
	[CmdletBinding()]
	[OutputType([string[]])]
	param([Parameter(Mandatory)] [string] $HostName)
	$ip = $null
	if ([System.Net.IPAddress]::TryParse($HostName.Trim('[', ']'), [ref]$ip)) { return @($ip.ToString()) }
	try {
		return @([System.Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
	} catch {
		$reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
		Write-Warning "Share host '$HostName' does not resolve: $reason"
		return @()
	}
}

function New-EvpArrayPool {
	<#
	.SYNOPSIS
		The array logins of one run: sessions, failures and expanded fleets, shared by mapping,
		cleanup and verify so that every array is logged in to at most once.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Builds an empty record; changes nothing.')]
	[CmdletBinding()]
	[OutputType([psobject])]
	param()
	return [pscustomobject]@{
		Sessions    = [ordered]@{}   # array name -> session (fleet members included)
		Unreachable = [ordered]@{}   # array or fleet name -> reason
		Fleets      = [ordered]@{}   # fleet entry name -> { Fleet, Members, Skipped }
		Expanded    = $false
	}
}

function Expand-EvpFleets {
	<#
	.SYNOPSIS
		Logs in to every Type Fleet entry once and adds its members to the pool as arrays.
	.DESCRIPTION
		A member that also has an entry of its own (same name, any case) is left to that entry:
		a direct login wins over the fleet. Members of the other product are skipped (no
		cross-product calls), and so is a member that has not joined.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform, [Parameter(Mandatory)] $Pool)
	if ($Pool.Expanded) { return }
	$Pool.Expanded = $true
	$direct = @($Config.Arrays.Values | Where-Object { $_.Type -ne 'Fleet' } | ForEach-Object { $_.Name })
	foreach ($entry in @($Config.Arrays.Values | Where-Object { $_.Type -eq 'Fleet' })) {
		try {
			$token = Unprotect-EvpSecret -Path $entry.ApiTokenFile -Platform $Platform
			$login = Connect-EvpArray -ArrayConfig $entry -ApiToken $token
			$fleet = Get-EvpFleetMemberSessions -Session $login -EntryName $entry.Name
		} catch {
			$Pool.Unreachable[$entry.Name] = $_.Exception.Message
			Write-Warning "Fleet '$($entry.Name)' ($($entry.Endpoint)) is not usable: $($_.Exception.Message)"
			continue
		}
		foreach ($name in @($fleet.Members.Keys)) {
			$own = $direct | Where-Object { $_ -ieq $name } | Select-Object -First 1
			if ($own) { $fleet.Skipped[$name] = "has its own entry '$own'"; $fleet.Members.Remove($name); continue }
			if ($Pool.Sessions.Contains($name)) { $fleet.Skipped[$name] = 'already reached through another fleet entry'; $fleet.Members.Remove($name); continue }
			$Pool.Sessions[$name] = $fleet.Members[$name]
		}
		$Pool.Fleets[$entry.Name] = $fleet
		Write-Host "Fleet '$($fleet.Fleet)' through '$($entry.Endpoint)': members $(if ($fleet.Members.Count) { ($fleet.Members.Keys -join ', ') } else { 'none usable' })$(if ($fleet.Skipped.Count) { '; skipped ' + (($fleet.Skipped.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ', ') })."
	}
}

function Get-EvpArrayNames {
	<#
	.SYNOPSIS
		Every array a run can use: the plain entries plus the members of the fleet entries.
	#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform, [Parameter(Mandatory)] $Pool)
	$names = @($Config.Arrays.Values | Where-Object { $_.Type -ne 'Fleet' } | ForEach-Object { $_.Name })
	if (@($Config.Arrays.Values | Where-Object { $_.Type -eq 'Fleet' }).Count) {
		Expand-EvpFleets -Config $Config -Platform $Platform -Pool $Pool
		$names += @($Pool.Fleets.Values | ForEach-Object { $_.Members.Keys })
	}
	return @($names)
}

function Open-EvpArraySession {
	<#
	.SYNOPSIS
		Logs in to one array once per run, recording a failure instead of throwing.
	.DESCRIPTION
		A plain entry logs in directly. Any other name is looked up among the fleet members, which
		expands the fleet entries the first time it is needed.
	.OUTPUTS
		The session, or $null when the array is unreachable (the reason is in Pool.Unreachable).
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] $Platform,
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] $Pool
	)
	if ($Pool.Sessions.Contains($Name)) { return $Pool.Sessions[$Name] }
	if ($Pool.Unreachable.Contains($Name)) { return $null }
	$arrayConfig = $Config.Arrays[$Name]
	if ($arrayConfig -and $arrayConfig.Type -ne 'Fleet') {
		try {
			$token = Unprotect-EvpSecret -Path $arrayConfig.ApiTokenFile -Platform $Platform
			$Pool.Sessions[$Name] = Connect-EvpArray -ArrayConfig $arrayConfig -ApiToken $token
			return $Pool.Sessions[$Name]
		} catch {
			$Pool.Unreachable[$Name] = $_.Exception.Message
			Write-Warning "Array '$Name' ($($arrayConfig.Endpoint)) is not usable: $($_.Exception.Message)"
			return $null
		}
	}
	Expand-EvpFleets -Config $Config -Platform $Platform -Pool $Pool
	if ($Pool.Sessions.Contains($Name)) { return $Pool.Sessions[$Name] }
	if (-not $Pool.Unreachable.Contains($Name)) {
		$skipped = @($Pool.Fleets.Values | Where-Object { $_.Skipped.Contains($Name) } | Select-Object -First 1)
		$Pool.Unreachable[$Name] = if ($arrayConfig) { "'$Name' is a fleet entry, not an array" }
		elseif ($skipped) { "fleet member '$Name' of '$($skipped[0].Fleet)' is not usable: $($skipped[0].Skipped[$Name])" }
		else { "no array or fleet member named '$Name' is configured" }
	}
	return $null
}

function Connect-EvpArraysForShares {
	<#
	.SYNOPSIS
		Maps every share to its array, logs in to the arrays needed and resolves each share's source.
	.DESCRIPTION
		A share with Array set uses that array. Any other share is mapped through the arrays' file
		interfaces: first on the array the cache recorded for it, then, for whatever is still
		unmapped, on every configured array and fleet member. An array that cannot be reached or
		rejects its token is a warning as long as every share still maps somewhere.
		ActiveCluster: a realm VIP is listed on both arrays of the pair. When several arrays own
		an address and exactly one of them reports itself 'online' for it, that array serves the
		share; the cache is not trusted for an array that is only 'available' (standby) now.
	.PARAMETER State
		State of the last run (Read-EvpState), or $null.
	.PARAMETER FullScan
		Ignore the cache and ask every array (verify), so an address owned twice is noticed.
	.PARAMETER Tolerant
		Report shares that cannot be mapped or resolved in Unmapped instead of throwing.
	.PARAMETER Pool
		Logins to reuse (New-EvpArrayPool); a new pool when omitted.
	.OUTPUTS
		Ordered hashtable: Pool, Sessions and Unreachable (the pool's), Groups (key
		"array|source" -> { Array, Session, SourceName, SourceInfo, Shares }), Shares (the shares
		that resolved, with Array set) and Unmapped ({ Share, Reason }).
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] $Platform,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Shares,
		$State,
		[switch] $FullScan,
		[switch] $Tolerant,
		$Pool
	)

	if (-not $Pool) { $Pool = New-EvpArrayPool }
	$interfaces = [ordered]@{}
	$addresses = @{}
	$mapped = [System.Collections.Generic.List[object]]::new()
	$pending = [System.Collections.Generic.List[object]]::new()
	$unmapped = [System.Collections.Generic.List[object]]::new()

	function Get-InterfaceList([string] $Name) {
		if ($interfaces.Contains($Name)) { return $interfaces[$Name] }
		$interfaces[$Name] = @()
		$session = Open-EvpArraySession -Config $Config -Platform $Platform -Name $Name -Pool $Pool
		if (-not $session) { return @() }
		try { $interfaces[$Name] = @(Get-EvpArrayFileInterfaces -Session $session) }
		catch {
			$Pool.Unreachable[$Name] = "network-interfaces could not be read: $($_.Exception.Message)"
			Write-Warning "Array '$Name': $($Pool.Unreachable[$Name])"
		}
		return $interfaces[$Name]
	}
	function Add-Mapping($Share, [string] $Name, $Interface, [string] $How) {
		$Share.Array = $Name
		$Share.ServerHint = $Interface.Server
		$ac = if ($Interface.Availability) { ", ActiveCluster: $($Interface.Availability) here" } else { '' }
		Write-Host "Share '$($Share.VeeamPath)' -> array '$Name' (file interface $($Interface.Address)$(if ($Interface.Server) { " of server '$($Interface.Server)'" })$ac$How)."
		$mapped.Add($Share)
	}

	foreach ($share in $Shares) {
		if ($share.Array) {
			if (Open-EvpArraySession -Config $Config -Platform $Platform -Name $share.Array -Pool $Pool) { $mapped.Add($share) }
			else { $unmapped.Add([pscustomobject]@{ Share = $share; Reason = "array '$($share.Array)', set in Shares, is not usable: $($Pool.Unreachable[$share.Array])" }) }
			continue
		}
		$addresses[$share.VeeamPath] = @(Resolve-EvpShareHostAddress -HostName $share.Server)
		if ($addresses[$share.VeeamPath].Count -eq 0) { $unmapped.Add([pscustomobject]@{ Share = $share; Reason = "host '$($share.Server)' does not resolve" }); continue }
		$pending.Add($share)
	}

	# Pass 1: the array that served the share last time, unless it is only the standby now.
	if (-not $FullScan -and $State -and $pending.Count -gt 0) {
		foreach ($share in @($pending)) {
			$cached = Get-EvpCachedShareArray -State $State -VeeamPath $share.VeeamPath
			if (-not $cached) { continue }
			$hit = @(Get-InterfaceList $cached) | Where-Object { $_.Address -in $addresses[$share.VeeamPath] } | Select-Object -First 1
			if ($hit -and (-not $hit.Availability -or $hit.Availability -eq 'online')) { Add-Mapping $share $cached $hit ', as in the last run'; $null = $pending.Remove($share) }
		}
	}

	# Pass 2: every array, for whatever is still unmapped.
	if ($pending.Count -gt 0) {
		foreach ($name in (Get-EvpArrayNames -Config $Config -Platform $Platform -Pool $Pool)) { $null = Get-InterfaceList $name }
		foreach ($share in $pending) {
			$owners = @(foreach ($name in $interfaces.Keys) {
					$hit = @($interfaces[$name]) | Where-Object { $_.Address -in $addresses[$share.VeeamPath] } | Select-Object -First 1
					if ($hit) { [pscustomobject]@{ Array = $name; Interface = $hit } }
				})
			if ($owners.Count -gt 1) {
				$online = @($owners | Where-Object { $_.Interface.Availability -eq 'online' })
				if ($online.Count -eq 1) { Add-Mapping $share $online[0].Array $online[0].Interface " (also on $(($owners | Where-Object Array -ne $online[0].Array | ForEach-Object Array) -join ', '))"; continue }
			}
			if ($owners.Count -eq 1) { Add-Mapping $share $owners[0].Array $owners[0].Interface ''; continue }
			$reason = if ($owners.Count -gt 1) {
				"its address is a file interface of $($owners.Count) arrays ($(($owners | ForEach-Object { "$($_.Array)$(if ($_.Interface.Availability) { " $($_.Interface.Availability)" })" }) -join ', ')); set Shares[].Array for it"
			} else {
				$text = "no configured array has a file interface with address $($addresses[$share.VeeamPath] -join ' or ')"
				if ($Pool.Unreachable.Count) { $text += "; not reachable: $($Pool.Unreachable.Keys -join ', ')" }
				$text
			}
			$unmapped.Add([pscustomobject]@{ Share = $share; Reason = $reason })
		}
	}

	$groups = [ordered]@{}
	$resolved = [System.Collections.Generic.List[object]]::new()
	foreach ($share in $mapped) {
		$session = $Pool.Sessions[$share.Array]
		try { $info = Resolve-EvpArraySource -Session $session -Share $share }
		catch { $unmapped.Add([pscustomobject]@{ Share = $share; Reason = $_.Exception.Message }); continue }
		Write-Host "Share '$($share.VeeamPath)' -> $($session.Platform) '$($session.ArrayName)'$(if ($session.Fleet) { " (fleet '$($session.Fleet)')" }) source '$($info.Name)'."
		$share.Source = $info.Name
		$key = '{0}|{1}' -f $share.Array, $info.Name
		if (-not $groups.Contains($key)) {
			$groups[$key] = [pscustomobject]@{ Array = $share.Array; Session = $session; SourceName = $info.Name; SourceInfo = $info; Shares = [System.Collections.Generic.List[object]]::new() }
		}
		$groups[$key].Shares.Add($share)
		$resolved.Add($share)
	}

	if ($unmapped.Count -gt 0 -and -not $Tolerant) {
		throw ("$($unmapped.Count) share(s) could not be mapped to an array source:`n  - " + (($unmapped | ForEach-Object { "$($_.Share.VeeamPath): $($_.Reason)" }) -join "`n  - "))
	}
	return [ordered]@{ Pool = $Pool; Sessions = $Pool.Sessions; Groups = $groups; Shares = $resolved.ToArray(); Unmapped = $unmapped.ToArray(); Unreachable = $Pool.Unreachable }
}

#endregion

#region State cache

function Get-EvpDefaultStateDirectory {
	<#
	.SYNOPSIS
		Platform default for the state directory, beside the default log directory.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] $Platform,
		[Parameter(Mandatory)] [string] $InstallRoot,
		[Parameter(Mandatory)] [string] $ConfigDirectory
	)
	if ($Platform.IsWindows) { return (Join-Path $InstallRoot 'state') }
	if ($Platform.InSandbox) { return "$($Platform.SandboxRoot.TrimEnd('/'))/everpure-veeam-nas/state" }
	return "$($ConfigDirectory.TrimEnd('/'))/state"
}

function Get-EvpStatePath {
	<# The state file of a configuration: <state directory>/<profile>.state.json. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)
	$dir = $Config.State.Directory
	if (-not $dir) { $dir = Get-EvpDefaultStateDirectory -Platform $Platform -InstallRoot (Get-EvpModuleRoot) -ConfigDirectory $Config.ConfigDirectory }
	return (Join-Path $dir "$($Config.ProfileName).state.json")
}

function Read-EvpState {
	<#
	.SYNOPSIS
		Reads the state of the last run. A missing file is normal; an unreadable one is a warning.
	.OUTPUTS
		The state document, or $null.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)] [string] $Path, [string] $JobId)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
	try { $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 16 -ErrorAction Stop }
	catch { Write-Warning "State file '$Path' is unreadable and is ignored: $($_.Exception.Message)"; return $null }
	if ([int]$doc.Version -ne 1) { Write-Warning "State file '$Path' has version '$($doc.Version)', which this release does not know; it is ignored."; return $null }
	if ($JobId -and $doc.JobId -and [string]$doc.JobId -ne $JobId) {
		Write-Warning "State file '$Path' belongs to job $($doc.JobId), not $JobId; it is ignored."
		return $null
	}
	return $doc
}

function Get-EvpCachedShareArray {
	<# The array the last run used for a share, or $null. #>
	[CmdletBinding()]
	[OutputType([string])]
	param($State, [Parameter(Mandatory)] [string] $VeeamPath)
	if (-not $State) { return $null }
	$wanted = Get-EvpNormalizedSharePath -VeeamPath $VeeamPath
	$hit = @($State.Shares) | Where-Object { $_.VeeamPath -and (Get-EvpNormalizedSharePath -VeeamPath $_.VeeamPath) -eq $wanted } | Select-Object -First 1
	if ($hit) { return [string]$hit.Array }
	return $null
}

function Get-EvpOrphanSources {
	<#
	.SYNOPSIS
		Sources the last run recorded that this run no longer uses, for example because their share
		left the job. Their tagged snapshots would otherwise stay forever.
	#>
	[CmdletBinding()]
	[OutputType([object[]])]
	param($State, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Plan)
	if (-not $State) { return @() }
	# A fleet member is no key of Config.Arrays; with a fleet configured, the cleanup finds out.
	$haveFleet = [bool]@($Config.Arrays.Values | Where-Object { $_.Type -eq 'Fleet' }).Count
	$orphans = foreach ($s in @($State.Sources)) {
		if (-not $s.Array -or -not $s.Source) { continue }
		if ($Plan.Groups.Contains(('{0}|{1}' -f $s.Array, $s.Source))) { continue }
		if (-not $Config.Arrays.Contains([string]$s.Array) -and -not $haveFleet) {
			Write-Warning "Source '$($s.Source)' of the last run was on array '$($s.Array)', which is no longer configured; it is dropped from the state and its tagged snapshots stay."
			continue
		}
		[pscustomobject]@{ Array = [string]$s.Array; Platform = [string]$s.Platform; Source = [string]$s.Source }
	}
	return @($orphans)
}

function Invoke-EvpOrphanCleanup {
	<#
	.SYNOPSIS
		Destroys this tag's snapshots older than the cut-off on sources the job no longer uses.
	.OUTPUTS
		Record with Remaining (orphans still holding tagged snapshots, or not checkable right now),
		Destroyed and Failed.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
		Justification = 'Changes nothing itself; -WhatIf is forwarded to Remove-EvpArraySnapshots, which asks ShouldProcess per snapshot.')]
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] $Platform,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Orphans,
		[Parameter(Mandatory)] $Plan,
		[Parameter(Mandatory)] [datetime] $Cutoff
	)
	$result = [pscustomobject]@{ Remaining = [System.Collections.Generic.List[object]]::new(); Destroyed = 0; Failed = 0 }
	foreach ($o in $Orphans) {
		$session = Open-EvpArraySession -Config $Config -Platform $Platform -Name $o.Array -Pool $Plan.Pool
		if (-not $session) { $result.Remaining.Add($o); $result.Failed++; continue }
		try {
			$tagged = @(Get-EvpArraySnapshots -Session $session -SourceName $o.Source | Where-Object { -not $_.Destroyed -and (Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag) })
		} catch {
			# A source that no longer exists answers with an error, not an empty list.
			$exists = $true
			try { $null = Get-EvpArraySourceInfo -Session $session -SourceName $o.Source } catch { $exists = $false }
			if (-not $exists) { Write-Host "Source '$($o.Source)' of the last run no longer exists on '$($o.Array)'; dropped from the state."; continue }
			Write-Warning "Snapshots of '$($o.Source)' on '$($o.Array)' could not be listed: $($_.Exception.Message)"
			$result.Remaining.Add($o); $result.Failed++; continue
		}
		$old = @($tagged | Where-Object { (Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag) -lt $Cutoff })
		Write-Host "$($session.Platform) '$($o.Source)' is no longer used by the job: $($tagged.Count) snapshot(s) carry '$($Config.Snapshot.Tag)', $($old.Count) older than the cut-off."
		$destroyed = 0
		if ($old.Count -gt 0) {
			$summary = Remove-EvpArraySnapshots -Session $session -Snapshots $old -WhatIf:$WhatIfPreference
			$destroyed = $summary.Destroyed
			$result.Destroyed += $summary.Destroyed
			$result.Failed += $summary.Failed
		}
		if ($tagged.Count -gt $destroyed) { $result.Remaining.Add($o) }
	}
	return $result
}

function Save-EvpState {
	<#
	.SYNOPSIS
		Writes the state of this run. A failure is a warning: the cache only ever helps.
	.PARAMETER Shares
		The shares the run mapped (Array and Source set).
	.PARAMETER Sources
		Records with Array, Platform and Source: the sources of this run plus orphans that still
		hold tagged snapshots.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] $Config,
		$Job,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Shares,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Sources
	)
	$doc = [ordered]@{
		Version = 1
		Profile = $Config.ProfileName
		JobId   = $Config.Veeam.JobId
		JobName = if ($Job) { $Job.Name } else { $null }
		Written = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
		Shares  = @($Shares | ForEach-Object { [ordered]@{ VeeamPath = $_.VeeamPath; Protocol = $_.Protocol; InventoryId = $_.InventoryId; Array = $_.Array; Source = $_.Source } })
		Sources = @($Sources | ForEach-Object { [ordered]@{ Array = $_.Array; Platform = $_.Platform; Source = $_.Source } } | Sort-Object { '{0}|{1}' -f $_.Array, $_.Source } -Unique)
	}
	if (-not $PSCmdlet.ShouldProcess($Path, 'Write the state of this run')) { return }
	try {
		$dir = Split-Path -Parent $Path
		if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
		$temp = "$Path.tmp"
		[System.IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
		[System.IO.File]::Move($temp, $Path, $true)
		Write-Host "State of this run saved to '$Path'."
	} catch { Write-Warning "Could not save the state to '$Path': $($_.Exception.Message)" }
}

#endregion
