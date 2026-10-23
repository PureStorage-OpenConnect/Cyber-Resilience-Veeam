# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Orchestration of the three phases. Each returns an exit code from the table below, which is
	identical on both platforms and documented in the README. Veeam itself treats any non-zero
	as a warning and runs the job anyway, which is why the pre phase applies the fail-safe path
	instead of relying on the exit code (R7 in docs/unified-nas-snapshot-plan.md).

	  0  success                        4  array authentication or connectivity
	  1  configuration or usage error   5  snapshot create or destroy
	  2  Veeam authentication/connect   6  partial success (see log)
	  3  share resolution or update    10  failure, fail-safe path applied
	                                   11  some shares not protected (fail-safe), the rest are
#>

$script:EvpExitCode = @{ Success = 0; Config = 1; Veeam = 2; Share = 3; Array = 4; Snapshot = 5; Partial = 6; FailSafe = 10; PartialFailSafe = 11 }

function Get-EvpExitCodeTable {
	<# Exit code table, for the README generator and the tests. #>
	[CmdletBinding()]
	param()
	return $script:EvpExitCode.Clone()
}

function Write-EvpPlan {
	<# Prints the resolved configuration at the start of every run. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform, [Parameter(Mandatory)] [string] $Phase, [switch] $DryRun)
	Write-Host "Script version     : $(Get-EvpVersion)"
	Write-Host "Configuration file : $($Config.ConfigPath)"
	if ($Config.ArraysFile) { Write-Host "Arrays file        : $($Config.ArraysFile)" }
	Write-Host "Phase              : $Phase"
	Write-Host "Platform           : $($Platform.Name), running as $($Platform.Identity)$(if ($Platform.InSandbox) { ' (appliance sandbox)' })"
	Write-Host "Veeam              : $($Config.Veeam.Server) backend $($Config.Veeam.Backend)$(if ($Config.Veeam.User) { " user $($Config.Veeam.User)" })"
	if ($Config.Veeam.JobId) { Write-Host "Bound job          : $($Config.Veeam.JobId) (job guard on, shares read from the job)" }
	foreach ($a in $Config.Arrays.Values) {
		if ($a.Type -eq 'Fleet') { Write-Host "Fleet              : $($a.Name) through $($a.Endpoint) (members found at run time, TLS $($a.Tls))" }
		else { Write-Host "Array              : $($a.Name) = $($a.Endpoint) ($($a.Platform), TLS $($a.Tls))" }
	}
	$label = if ($Config.Veeam.JobId) { 'Share override     ' } else { 'Share              ' }
	foreach ($s in $Config.Shares) { Write-Host "${label}: $($s.VeeamPath) [$($s.Protocol)] on $(if ($s.Array) { $s.Array } else { 'the array owning its address' }), source $($s.Source)" }
	Write-Host "Snapshot tag       : $($Config.Snapshot.Tag), keep for $(if ($Config.Snapshot.KeepForMs -gt 0) { $Config.Snapshot.KeepFor } else { 'the job run only' }), FlashArray expiry $([TimeSpan]::FromMilliseconds($Config.Snapshot.ArrayExpiryMs).ToString('d\d\ h\h\ m\m'))"
	Write-Host "Behaviour          : on failure $($Config.Behaviour.OnFailure) per $($Config.Behaviour.FailSafeScope.ToLowerInvariant()), enforce StorageSnapshot mode $($Config.Behaviour.EnsureProcessingMode)"
	if ($Config.Behaviour.OnFailure -eq 'LiveFallback') { Write-Host 'Live fallback      : ON. A share that cannot be backed up from a snapshot is backed up live; only Veeam warnings show it.' }
	if ($DryRun) { Write-Host 'Mode               : DRY RUN (-WhatIf), nothing will be changed' }
}

function Get-EvpPlanSources {
	<# The sources of a plan as state records. Private helper. #>
	param([Parameter(Mandatory)] $Plan)
	return @($Plan.Groups.Values | ForEach-Object { [pscustomobject]@{ Array = $_.Array; Platform = $_.Session.Platform; Source = $_.SourceName } })
}

function Invoke-EvpPrePhase {
	<#
	.SYNOPSIS
		Pre-job: snapshot every source once, point every share at its snapshot, sweep old ones.
	.DESCRIPTION
		Failures are contained to the smallest part they concern (Behaviour.FailSafeScope
		'Share', the default). A share that cannot be mapped to an array source, whose source
		cannot be snapshotted, or that cannot be repointed gets the fail-safe path on its own; the
		other shares still back up from their snapshots, and the run exits 11. Only what concerns
		every share (Veeam, the job guard, the job) stops the whole phase. With FailSafeScope
		'Job' any failure applies the fail-safe path to every share, as in 1.0.0.
	.OUTPUTS
		Exit code.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$stage = 'Veeam'
	$veeam = $null
	$resolved = [System.Collections.Generic.List[object]]::new()
	# Shares this run cannot protect: VeeamPath -> { Reason, Category, Repointable }.
	$failed = [ordered]@{}
	$perShare = ($Config.Behaviour.FailSafeScope -eq 'Share')
	$statePath = Get-EvpStatePath -Config $Config -Platform $Platform
	$state = Read-EvpState -Path $statePath -JobId $Config.Veeam.JobId
	function Add-Failure($Share, [string] $Category, [string] $Reason, [bool] $Repointable = $true) {
		if ($failed.Contains($Share.VeeamPath)) { return }
		# Scope Job: the first failure stops the phase and the catch below fail-safes every share.
		# A share missing from the inventory is only recorded; all of them are reported at once.
		if (-not $perShare -and $Repointable) { Set-Variable -Name stage -Scope 1 -Value $Category; throw "$($Share.VeeamPath): $Reason" }
		$failed[$Share.VeeamPath] = [pscustomobject]@{ Reason = $Reason; Category = $Category; Repointable = $Repointable }
		$outcome = if (-not $Repointable) { '' } else { switch ($Config.Behaviour.OnFailure) { 'FailSafe' { ' and gets the fail-safe path' } 'LiveFallback' { ' and falls back to a LIVE backup' } default { '' } } }
		Write-Warning "Share '$($Share.VeeamPath)' is not protected this run$($outcome): $Reason"
	}
	try {
		Write-EvpSection 'Veeam'
		$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
		# Job guard first: a clone of the job must not get past this point.
		$job = Assert-EvpVeeamJobSession -Session $veeam -Config $Config -Phase 'pre' -WarnOnly:$WhatIfPreference
		$inventory = Get-EvpVeeamShares -Session $veeam

		# Resolve every share in the inventory before touching anything. A share Veeam does not
		# know cannot be repointed at all, not even to the fail-safe path.
		$stage = 'Share'
		$shares = @(Get-EvpRunShares -Config $Config -Job $job)
		foreach ($share in $shares) {
			try { $entry = Find-EvpVeeamShare -Shares $inventory -VeeamPath $share.VeeamPath } catch { Add-Failure $share 'Share' $_.Exception.Message $false; continue }
			Write-Host "Share '$($share.VeeamPath)': $($entry.TypeName), mode $($entry.ProcessingMode), failover $($entry.FailoverEnabled), path '$($entry.StorageSnapshotPath)'"
			$resolved.Add([pscustomobject]@{ Config = $share; Inventory = $entry; Group = $null; Applied = $null })
		}
		if ($resolved.Count -eq 0) { throw "No share of this run is in the Veeam inventory: $(($failed.Values | ForEach-Object { $_.Reason }) -join ' ')" }
		if (-not $perShare -and $failed.Count) { throw (($failed.Values | ForEach-Object { $_.Reason }) -join ' ') }

		Write-EvpSection 'Arrays'
		$stage = 'Array'
		$plan = Connect-EvpArraysForShares -Config $Config -Platform $Platform -Shares @($resolved | ForEach-Object { $_.Config }) -State $state -Tolerant:$perShare
		foreach ($u in $plan.Unmapped) { Add-Failure $u.Share 'Array' $u.Reason }
		foreach ($r in $resolved) {
			$r.Group = $plan.Groups.Values | Where-Object { $_.Shares -contains $r.Config } | Select-Object -First 1
		}

		Write-EvpSection 'Snapshots'
		$stage = 'Snapshot'
		# Every precondition first, so a problem on the last source does not leave snapshots
		# behind on the first ones.
		$usable = [ordered]@{}
		foreach ($key in $plan.Groups.Keys) {
			$g = $plan.Groups[$key]
			if ($g.Session.Platform -eq 'FlashBlade' -and $g.SourceInfo.SnapshotDirectoryEnabled -eq $false) {
				foreach ($s in $g.Shares) { Add-Failure $s 'Snapshot' "FlashBlade file system '$($g.SourceName)' has its snapshot directory disabled; Veeam cannot read '.snapshot' on it. Enable it on the array." }
				continue
			}
			$usable[$key] = $g
		}
		$timestamp = Get-EvpTimestamp
		$created = @{}
		foreach ($key in $usable.Keys) {
			$g = $usable[$key]
			$keepFor = if ($g.Session.Platform -eq 'FlashArray') { $Config.Snapshot.ArrayExpiryMs } else { 0 }
			try {
				$created[$key] = New-EvpArraySnapshot -Session $g.Session -SourceName $g.SourceName -Tag $Config.Snapshot.Tag -Timestamp $timestamp -KeepForMs $keepFor -WhatIf:$WhatIfPreference
			} catch {
				$message = "snapshot of '$($g.SourceName)' on '$($g.Array)' failed: $($_.Exception.Message)"
				foreach ($s in $g.Shares) { Add-Failure $s 'Snapshot' $message }
			}
		}

		Write-EvpSection 'Repoint shares'
		$stage = 'Share'
		foreach ($r in $resolved) {
			if ($failed.Contains($r.Config.VeeamPath) -or -not $r.Group) { continue }
			$naming = $created['{0}|{1}' -f $r.Group.Array, $r.Group.SourceName]
			$path = Get-EvpStorageSnapshotPath -VeeamPath $r.Config.VeeamPath -SnapshotDirectoryName $naming.DirectoryName -SnapshotRootDirName $Config.Snapshot.SnapshotRootDirName
			try { $r.Applied = Set-EvpVeeamStorageSnapshotPath -Session $veeam -Share $r.Inventory -StorageSnapshotPath $path -EnsureProcessingMode $Config.Behaviour.EnsureProcessingMode -WhatIf:$WhatIfPreference }
			catch { Add-Failure $r.Config 'Share' "repointing failed: $($_.Exception.Message)" }
		}
		$failSafed = Set-EvpFailSafePaths -Config $Config -Session $veeam -Resolved @($resolved | Where-Object { $failed.Contains($_.Config.VeeamPath) -and $failed[$_.Config.VeeamPath].Repointable })

		# Sweep: tagged snapshots older than KeepFor (all of them when KeepFor is 'none'), except
		# the one just created. Catches whatever a missed post phase left behind, also on sources
		# the job no longer uses (from the state of the last run).
		Write-EvpSection "Sweep snapshots$(if ($Config.Snapshot.KeepForMs -gt 0) { " older than $($Config.Snapshot.KeepFor)" } else { ' of earlier runs' })"
		$stage = 'Snapshot'
		$cutoff = [datetime]::UtcNow.AddMilliseconds(-$Config.Snapshot.KeepForMs)
		$sweepFailed = 0
		foreach ($key in $plan.Groups.Keys) {
			$g = $plan.Groups[$key]
			try {
				$all = Get-EvpArraySnapshots -Session $g.Session -SourceName $g.SourceName
				$old = @($all | Where-Object {
						$ts = Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag
						$ts -and $ts -lt $cutoff -and (-not $created.ContainsKey($key) -or $_.Name -ne $created[$key].ArrayName) -and -not $_.Destroyed
					})
				Write-Host "$($g.Session.Platform) '$($g.SourceName)': $($all.Count) snapshot(s), $($old.Count) matching '$($Config.Snapshot.Tag)' and older than the cut-off."
				if ($old.Count -gt 0) {
					$summary = Remove-EvpArraySnapshots -Session $g.Session -Snapshots $old -WhatIf:$WhatIfPreference
					$sweepFailed += $summary.Failed
				}
			} catch {
				Write-Warning "Sweep on '$($g.SourceName)' failed: $($_.Exception.Message)"
				$sweepFailed++
			}
		}
		$orphans = @(Get-EvpOrphanSources -State $state -Config $Config -Plan $plan)
		$orphanResult = Invoke-EvpOrphanCleanup -Config $Config -Platform $Platform -Orphans $orphans -Plan $plan -Cutoff $cutoff -WhatIf:$WhatIfPreference
		$sweepFailed += $orphanResult.Failed + $orphanResult.Unreachable
		Save-EvpState -Path $statePath -Config $Config -Job $job -Shares $plan.Shares -Sources (@(Get-EvpPlanSources -Plan $plan) + @($orphanResult.Remaining)) -WhatIf:$WhatIfPreference

		Write-Host ''
		$protected = @($resolved | Where-Object { $_.Applied })
		if ($protected.Count) {
			Write-Host "Pre-backup phase completed$(if ($failed.Count) { ' for part of the job' }). Veeam will read:"
			foreach ($r in $protected) { Write-Host "  $($r.Config.VeeamPath)  <-  $($r.Applied)" }
		}
		if ($failed.Count) {
			$how = if ($Config.Behaviour.OnFailure -eq 'LiveFallback') { 'are backed up LIVE (live fallback)' } else { 'fail visibly on the fail-safe path' }
			Write-Host "Not protected this run ($($failed.Count) share(s))$(if ($failSafed) { "; $failSafed of them $how" }):"
			foreach ($k in $failed.Keys) { Write-Host "  $k  ($($failed[$k].Category): $($failed[$k].Reason))" }
			if ($protected.Count) { return $script:EvpExitCode.PartialFailSafe }
			if ($failSafed) { return $script:EvpExitCode.FailSafe }
			return $script:EvpExitCode[@($failed.Values)[0].Category]
		}
		if ($sweepFailed) { Write-Warning 'The sweep reported failures (see above); the backup itself is set up.'; return $script:EvpExitCode.Partial }
		return $script:EvpExitCode.Success
	} catch {
		Write-Host ''
		Write-Host "Pre-backup phase FAILED during stage '$stage': $($_.Exception.Message)"
		Write-Verbose $_.ScriptStackTrace
		$code = $script:EvpExitCode[$stage]
		if ($veeam -and (Set-EvpFailSafePaths -Config $Config -Session $veeam -Resolved @($resolved)) -gt 0) { $code = $script:EvpExitCode.FailSafe }
		return $code
	} finally {
		if ($veeam) { Disconnect-EvpVeeam -Session $veeam }
	}
}

function Set-EvpFailSafePaths {
	<#
	.SYNOPSIS
		Applies Behaviour.OnFailure to shares this run cannot back up from a fresh snapshot.
	.DESCRIPTION
		FailSafe: a non-existent snapshot path with failover off, so the backup fails visibly
		instead of reading stale or live data. LiveFallback: the same path with Veeam's failover to
		direct backup on, so Veeam backs up the live share and only warns. None: nothing.
	.OUTPUTS
		The number of shares OnFailure was applied to.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
		Justification = 'Changes nothing itself; -WhatIf is forwarded to Set-EvpVeeamStorageSnapshotPath, which asks ShouldProcess per share.')]
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([int])]
	param(
		[Parameter(Mandatory)] $Config,
		[Parameter(Mandatory)] $Session,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Resolved
	)
	if ($Resolved.Count -eq 0 -or $Config.Behaviour.OnFailure -eq 'None') { return 0 }
	$live = ($Config.Behaviour.OnFailure -eq 'LiveFallback')
	$sentinel = Get-EvpSentinelDirectoryName
	$applied = 0
	foreach ($r in $Resolved) {
		try {
			$path = Get-EvpStorageSnapshotPath -VeeamPath $r.Config.VeeamPath -SnapshotDirectoryName $sentinel -SnapshotRootDirName $Config.Snapshot.SnapshotRootDirName
			$null = Set-EvpVeeamStorageSnapshotPath -Session $Session -Share $r.Inventory -StorageSnapshotPath $path -EnsureProcessingMode $true -Failover $live -WhatIf:$WhatIfPreference
			$r.Applied = $null
			$applied++
		} catch { Write-Warning "Could not apply OnFailure '$($Config.Behaviour.OnFailure)' to '$($r.Config.VeeamPath)': $($_.Exception.Message)" }
	}
	if ($applied -gt 0 -and $live) {
		Write-Warning "LIVE FALLBACK for $applied share(s): they point at a non-existent snapshot path with failover to direct backup ON, so Veeam backs up the LIVE share and only warns. That backup is not crash-consistent. A successful pre-backup run restores the snapshot path."
	} elseif ($applied -gt 0) {
		Write-Host "Fail-safe applied to $applied share(s): they now point at a non-existent snapshot path with failover off, so their backup fails visibly instead of backing up stale or live data. A successful pre-backup run restores them."
	}
	return $applied
}

function Invoke-EvpPostPhase {
	<#
	.SYNOPSIS
		Post-job: disarm the shares, then destroy this tag's snapshots that are older than
		Snapshot.KeepFor on every source of the job.
	.DESCRIPTION
		Disarming points every share at a non-existent path with failover off. Should the next pre
		phase fail before it reaches its own fail-safe (Veeam unreachable, script killed by the
		timeout), the job then fails visibly instead of reading the last snapshot, which a KeepFor
		retention keeps on purpose. Without the job guard a failed Veeam connection does not stop
		the cleanup, which then covers the Shares list or, failing that, the shares of the last
		run; with the guard it needs Veeam, so it does. An array that cannot be reached only
		leaves its own sources for the next run.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$stage = 'Veeam'
	$veeam = $null
	$job = $null
	$disarmFailed = 0
	$statePath = Get-EvpStatePath -Config $Config -Platform $Platform
	$state = Read-EvpState -Path $statePath -JobId $Config.Veeam.JobId
	try {
		Write-EvpSection 'Veeam'
		try {
			$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
		} catch {
			if ($Config.Veeam.JobGuard) { throw }
			Write-Warning "Could not connect to Veeam, so the shares stay pointed at this run's snapshot path: $($_.Exception.Message)"
			$disarmFailed++
		}
		if ($veeam) {
			$job = Assert-EvpVeeamJobSession -Session $veeam -Config $Config -Phase 'post' -WarnOnly:$WhatIfPreference
			$stage = 'Share'
			$shares = @(Get-EvpRunShares -Config $Config -Job $job)

			Write-EvpSection 'Disarm shares'
			$inventory = Get-EvpVeeamShares -Session $veeam
			$sentinel = Get-EvpSentinelDirectoryName -Reason Disarmed
			foreach ($share in $shares) {
				try {
					$entry = Find-EvpVeeamShare -Shares $inventory -VeeamPath $share.VeeamPath
					$path = Get-EvpStorageSnapshotPath -VeeamPath $share.VeeamPath -SnapshotDirectoryName $sentinel -SnapshotRootDirName $Config.Snapshot.SnapshotRootDirName
					$null = Set-EvpVeeamStorageSnapshotPath -Session $veeam -Share $entry -StorageSnapshotPath $path -EnsureProcessingMode $true -Failover ($Config.Behaviour.OnFailure -eq 'LiveFallback') -WhatIf:$WhatIfPreference
				} catch {
					Write-Warning "Could not disarm '$($share.VeeamPath)': $($_.Exception.Message)"
					$disarmFailed++
				}
			}
		} elseif ($Config.Shares.Count -gt 0) {
			$shares = @(Get-EvpRunShares -Config $Config -Job $null)
		} elseif ($state -and @($state.Shares).Count -gt 0) {
			Write-Warning "Cleaning up the shares of the last run ($($state.Written)), because the job cannot be read without Veeam."
			$shares = @($state.Shares | ForEach-Object { New-EvpShareRecord -VeeamPath $_.VeeamPath -Array $_.Array -Source $_.Source -InventoryId $_.InventoryId -Origin 'cache' })
		} else {
			throw 'Without Veeam the job cannot be read for its shares, Shares lists none, and there is no state of an earlier run.'
		}

		Write-EvpSection 'Arrays'
		$stage = 'Array'
		$plan = Connect-EvpArraysForShares -Config $Config -Platform $Platform -Shares $shares -State $state -Tolerant
		foreach ($u in $plan.Unmapped) { Write-Warning "Share '$($u.Share.VeeamPath)' is left for the next run: $($u.Reason)" }

		Write-EvpSection 'Destroy snapshots'
		$stage = 'Snapshot'
		$keepCutoff = [datetime]::UtcNow.AddMilliseconds(-$Config.Snapshot.KeepForMs)
		$tagged = 0; $matched = 0; $destroyed = 0; $failed = 0
		foreach ($key in $plan.Groups.Keys) {
			$g = $plan.Groups[$key]
			try {
				$all = Get-EvpArraySnapshots -Session $g.Session -SourceName $g.SourceName
				$withTag = @($all | Where-Object { -not $_.Destroyed -and (Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag) })
				$mine = @($withTag | Where-Object { (Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag) -lt $keepCutoff })
				Write-Host "$($g.Session.Platform) '$($g.SourceName)': $($mine.Count) snapshot(s) match '$($Config.Snapshot.Tag)'$(if ($Config.Snapshot.KeepForMs -gt 0) { " and are older than $($Config.Snapshot.KeepFor)" })."
				$tagged += $withTag.Count
				$matched += $mine.Count
				if ($mine.Count -gt 0) {
					$summary = Remove-EvpArraySnapshots -Session $g.Session -Snapshots $mine -WhatIf:$WhatIfPreference
					$destroyed += $summary.Destroyed; $failed += $summary.Failed
				}
			} catch {
				Write-Warning "Cleanup on '$($g.SourceName)' failed: $($_.Exception.Message)"
				$failed++
			}
		}
		# Sources of the last run this run did not cover: shares that left the job, or whose array
		# is unreachable right now. Kept in the state until nothing tagged is left on them.
		$orphans = @(Get-EvpOrphanSources -State $state -Config $Config -Plan $plan)
		$orphanResult = Invoke-EvpOrphanCleanup -Config $Config -Platform $Platform -Orphans $orphans -Plan $plan -Cutoff $keepCutoff -WhatIf:$WhatIfPreference
		$destroyed += $orphanResult.Destroyed; $matched += $orphanResult.Destroyed; $failed += $orphanResult.Failed; $arrayProblems = @($plan.Unmapped).Count + $orphanResult.Unreachable
		$keptShares = @($plan.Shares) + @($state.Shares | Where-Object { $_ -and $_.VeeamPath -in @($plan.Unmapped | ForEach-Object { $_.Share.VeeamPath }) })
		Save-EvpState -Path $statePath -Config $Config -Job $job -Shares $keptShares -Sources (@(Get-EvpPlanSources -Plan $plan) + @($orphanResult.Remaining)) -WhatIf:$WhatIfPreference

		Write-Host ''
		if ($matched -gt 0) {
			Write-Host "Destroyed $destroyed snapshot(s); $failed failure(s). Destroyed snapshots stay recoverable until the array's eradication delay expires."
		} elseif ($tagged -gt 0) {
			Write-Host "$tagged snapshot(s) carry tag '$($Config.Snapshot.Tag)', none older than $($Config.Snapshot.KeepFor). Nothing to destroy yet."
		} elseif ($failed -eq 0 -and $arrayProblems -eq 0) {
			$message = "No snapshots matching tag '$($Config.Snapshot.Tag)' were found on any source. Nothing to clean up."
			if ($Config.Behaviour.FailIfNoSnapshots) { throw $message }
			Write-Warning $message
		}
		if ($disarmFailed) { Write-Warning "$disarmFailed share(s) could not be disarmed (see above); they keep pointing at this run's snapshot path." }
		Write-Host 'Post-backup phase completed.'
		if ($failed -gt 0) { return $script:EvpExitCode.Snapshot }
		if ($arrayProblems -gt 0) { return $script:EvpExitCode.Array }
		if ($disarmFailed -gt 0) { return $script:EvpExitCode.Partial }
		return $script:EvpExitCode.Success
	} catch {
		Write-Host ''
		Write-Host "Post-backup phase FAILED during stage '$stage': $($_.Exception.Message)"
		Write-Verbose $_.ScriptStackTrace
		return $script:EvpExitCode[$stage]
	} finally {
		if ($veeam) { Disconnect-EvpVeeam -Session $veeam }
	}
}

function Invoke-EvpVerifyPhase {
	<#
	.SYNOPSIS
		Checks everything the pre phase depends on and changes nothing. Runs every check even
		after a failure, so one report shows every problem.
	#>
	[CmdletBinding()]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$problems = [System.Collections.Generic.List[string]]::new()
	$code = $script:EvpExitCode.Success
	function Add-Problem([string] $Category, [string] $Text) {
		$problems.Add("[$Category] $Text")
		if ($code -eq 0) { Set-Variable -Name code -Scope 1 -Value $script:EvpExitCode[$Category] }
	}

	Write-EvpSection 'Secret files'
	$secretFiles = @($Config.Arrays.Values | ForEach-Object { $_.ApiTokenFile })
	if ($Config.Veeam.PasswordFile) { $secretFiles += $Config.Veeam.PasswordFile }
	foreach ($f in $secretFiles) {
		$t = Test-EvpSecretFile -Path $f -Platform $Platform
		Write-Host "$($t.Path): $($t.Protection); $($t.Permissions)"
		foreach ($w in $t.Warnings) { Write-Warning "$($t.Path): $w" }
		if (-not $t.Exists) { Add-Problem 'Config' "secret file '$($t.Path)' is missing" }
	}

	Write-EvpSection 'State of the last run'
	$statePath = Get-EvpStatePath -Config $Config -Platform $Platform
	$state = Read-EvpState -Path $statePath -JobId $Config.Veeam.JobId
	if ($state) { Write-Host "$($statePath): written $($state.Written), $(@($state.Shares).Count) share(s), $(@($state.Sources).Count) source(s)" }
	else { Write-Host "$($statePath): none yet (the first pre phase writes it)" }

	Write-EvpSection 'Veeam'
	$veeam = $null
	$shares = $null
	try {
		$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
		if ($veeam.Backend -eq 'Rest' -and $Config.Veeam.Tls -eq 'skip') {
			Write-Warning "Veeam.Tls 'skip' accepts any certificate, so the Veeam password can be intercepted on the network. Pin the certificate with Veeam.Tls 'thumbprint:<SHA-256>'."
		}
		$job = $null
		if ($Config.Veeam.JobId) {
			try {
				$job = Get-EvpVeeamJob -Session $veeam -JobId $Config.Veeam.JobId
				$active = @(Get-EvpVeeamActiveJobSessions -Session $veeam -Job $job)
				Write-Host "OK   bound to $($job.Kind) job '$($job.Name)' ($($job.Type)); $($active.Count) active session(s) right now. The pre and post phases run only inside a session of this job."
				if ($null -eq $job.Shares) { Write-Host '     the REST backend does not list the job objects, so the shares come from Shares' }
			} catch { Write-Host "FAIL job: $($_.Exception.Message)"; Add-Problem 'Veeam' $_.Exception.Message }
		}
		try {
			$shares = @(Get-EvpRunShares -Config $Config -Job $job)
			foreach ($s in $shares) { Write-Host "     share $($s.VeeamPath) [$($s.Protocol)] from the $(if ($s.Origin -eq 'job') { 'job' } else { 'configuration' })" }
		} catch { Write-Host "FAIL shares: $($_.Exception.Message)"; Add-Problem 'Config' $_.Exception.Message }
		$inventory = Get-EvpVeeamShares -Session $veeam
		foreach ($share in @($shares)) {
			try {
				$entry = Find-EvpVeeamShare -Shares $inventory -VeeamPath $share.VeeamPath
				Write-Host "OK   $($share.VeeamPath): $($entry.TypeName), mode $($entry.ProcessingMode), failover $($entry.FailoverEnabled), path '$($entry.StorageSnapshotPath)'"
				if ($entry.ProcessingMode -ne 'StorageSnapshot' -and -not $Config.Behaviour.EnsureProcessingMode) {
					Write-Warning "$($share.VeeamPath) is in mode '$($entry.ProcessingMode)' and Behaviour.EnsureProcessingMode is off, so the snapshot path will be ignored by the job."
				}
			} catch { Write-Host "FAIL $($share.VeeamPath): $($_.Exception.Message)"; Add-Problem 'Share' $_.Exception.Message }
		}
	} catch { Write-Host "FAIL Veeam: $($_.Exception.Message)"; Add-Problem 'Veeam' $_.Exception.Message }
	finally { if ($veeam) { Disconnect-EvpVeeam -Session $veeam } }
	if ($null -eq $shares -and $Config.Shares.Count -gt 0) { $shares = @(Get-EvpRunShares -Config $Config -Job $null) }

	Write-EvpSection 'Arrays and sources'
	if ($null -eq $shares) {
		Write-Host 'The share list is unknown without the job, so the arrays are only logged in to.'
		$shares = @()
	}
	$plan = Connect-EvpArraysForShares -Config $Config -Platform $Platform -Shares $shares -FullScan -Tolerant
	# Arrays no share needed were not contacted by the mapping; check their tokens too.
	$pool = $plan.Pool
	foreach ($name in (Get-EvpArrayNames -Config $Config -Platform $Platform -Pool $pool)) { $null = Open-EvpArraySession -Config $Config -Platform $Platform -Name $name -Pool $pool }
	foreach ($entry in $Config.Arrays.Values) {
		$name = $entry.Name
		if ($entry.Type -eq 'Fleet') {
			if ($pool.Unreachable.Contains($name)) { Write-Host "WARN fleet $($name): $($pool.Unreachable[$name])" }
			elseif ($pool.Fleets.Contains($name)) {
				$f = $pool.Fleets[$name]
				Write-Host "OK   fleet $($name): '$($f.Fleet)' through $($entry.Endpoint)"
				foreach ($m in $f.Members.Values) { Write-Host "OK     member $($m.Name): $($m.Platform), Purity $($m.PurityVersion)" }
				foreach ($k in $f.Skipped.Keys) { Write-Host "       member $($k) skipped: $($f.Skipped[$k])" }
			}
		} elseif ($pool.Unreachable.Contains($name)) { Write-Host "WARN $($name): $($pool.Unreachable[$name])"; continue }
		else { Write-Host "OK   $($name): $($pool.Sessions[$name].Platform) '$($pool.Sessions[$name].ArrayName)', Purity $($pool.Sessions[$name].PurityVersion)" }
		if ($entry.Tls -eq 'skip') {
			Write-Warning "$($name): Tls 'skip' accepts any certificate, so the API token can be intercepted on the network. Pin the certificate with Tls 'thumbprint:<SHA-256>' in arrays.jsonc; Protect-EverpureVeeamSecret.ps1 -Array $name -VerifyOnly prints it."
		}
	}
	foreach ($u in $plan.Unmapped) { Write-Host "FAIL $($u.Share.VeeamPath): $($u.Reason)"; Add-Problem 'Array' "$($u.Share.VeeamPath): $($u.Reason)" }
	foreach ($g in $plan.Groups.Values) {
		foreach ($share in $g.Shares) { Write-Host "OK   $($share.VeeamPath) -> $($g.Session.Platform) '$($g.Array)' source '$($g.SourceName)'" }
		if ($g.SourceInfo.SnapshotDirectoryEnabled -eq $false) {
			Write-Host "FAIL snapshot directory disabled on file system '$($g.SourceName)'"
			Add-Problem 'Snapshot' "FlashBlade file system '$($g.SourceName)' has its snapshot directory disabled"
		}
		try {
			# Destroyed snapshots stay listed until the array eradicates them; the phases ignore them.
			$existing = @(Get-EvpArraySnapshots -Session $g.Session -SourceName $g.SourceName | Where-Object { Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag })
			$live = @($existing | Where-Object { -not $_.Destroyed })
			$gone = $existing.Count - $live.Count
			Write-Host "     $($live.Count) existing snapshot(s) of '$($g.SourceName)' carry tag '$($Config.Snapshot.Tag)'$(if ($gone) { "; $gone more destroyed, awaiting eradication" })"
		} catch { Write-Host "FAIL $($g.SourceName): $($_.Exception.Message)"; Add-Problem 'Array' $_.Exception.Message }
	}
	foreach ($o in @(Get-EvpOrphanSources -State $state -Config $Config -Plan $plan)) {
		Write-Host "     source '$($o.Source)' on '$($o.Array)' is no longer used; the next run cleans up its tagged snapshots"
	}
	if ($Config.Behaviour.OnFailure -eq 'LiveFallback') {
		Write-Warning "Behaviour.OnFailure is 'LiveFallback': a share that cannot be backed up from a snapshot is backed up live, which is not crash-consistent and shows only as a Veeam warning."
	} elseif ($Config.Behaviour.OnFailure -eq 'None') {
		Write-Warning "Behaviour.OnFailure is 'None': a share that cannot be backed up from a fresh snapshot keeps its last path; watch the job warnings."
	}

	Write-EvpSection 'Result'
	if ($problems.Count -eq 0) {
		Write-Host 'Verification passed. Nothing was changed.'
	} else {
		Write-Host "Verification found $($problems.Count) problem(s). Nothing was changed."
		foreach ($p in $problems) { Write-Host "  - $p" }
	}
	return $code
}
