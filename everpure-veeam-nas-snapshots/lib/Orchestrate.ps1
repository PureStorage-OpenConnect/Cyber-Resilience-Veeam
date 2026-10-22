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
#>

$script:EvpExitCode = @{ Success = 0; Config = 1; Veeam = 2; Share = 3; Array = 4; Snapshot = 5; Partial = 6; FailSafe = 10 }

function Get-EvpExitCodeTable {
	<# Exit code table, for the README generator and the tests. #>
	[CmdletBinding()]
	param()
	return $script:EvpExitCode.Clone()
}

function Connect-EvpArraysForShares {
	<#
	.SYNOPSIS
		Logs in to every array the configured shares use and resolves each share's source.
	.OUTPUTS
		Ordered hashtable: Sessions (array name -> session) and Groups (key "array|source" ->
		{ Array, Session, SourceName, SourceInfo, Shares }).
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Shares)

	$sessions = [ordered]@{}
	$groups = [ordered]@{}
	foreach ($arrayName in @($Shares | ForEach-Object { $_.Array } | Sort-Object -Unique)) {
		$arrayConfig = $Config.Arrays[$arrayName]
		$token = Unprotect-EvpSecret -Path $arrayConfig.ApiTokenFile -Platform $Platform
		$sessions[$arrayName] = Connect-EvpArray -ArrayConfig $arrayConfig -ApiToken $token
	}
	foreach ($share in $Shares) {
		$session = $sessions[$share.Array]
		$info = Resolve-EvpArraySource -Session $session -Share $share
		Write-Host "Share '$($share.VeeamPath)' -> $($session.Platform) '$($session.ArrayName)' source '$($info.Name)'."
		$key = '{0}|{1}' -f $share.Array, $info.Name
		if (-not $groups.Contains($key)) {
			$groups[$key] = [pscustomobject]@{ Array = $share.Array; Session = $session; SourceName = $info.Name; SourceInfo = $info; Shares = [System.Collections.Generic.List[object]]::new() }
		}
		$groups[$key].Shares.Add($share)
	}
	return [ordered]@{ Sessions = $sessions; Groups = $groups }
}

function Write-EvpPlan {
	<# Prints the resolved configuration at the start of every run. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform, [Parameter(Mandatory)] [string] $Phase, [switch] $DryRun)
	Write-Host "Script version     : $(Get-EvpVersion)"
	Write-Host "Configuration file : $($Config.ConfigPath)"
	Write-Host "Phase              : $Phase"
	Write-Host "Platform           : $($Platform.Name), running as $($Platform.Identity)$(if ($Platform.InSandbox) { ' (appliance sandbox)' })"
	Write-Host "Veeam              : $($Config.Veeam.Server) backend $($Config.Veeam.Backend)$(if ($Config.Veeam.User) { " user $($Config.Veeam.User)" })"
	if ($Config.Veeam.JobId) { Write-Host "Bound job          : $($Config.Veeam.JobId) (job guard on)" }
	foreach ($a in $Config.Arrays.Values) { Write-Host "Array              : $($a.Name) = $($a.Endpoint) ($($a.Platform), TLS $($a.Tls))" }
	foreach ($s in $Config.Shares) { Write-Host "Share              : $($s.VeeamPath) [$($s.Protocol)] on $($s.Array), source $($s.Source)" }
	Write-Host "Snapshot tag       : $($Config.Snapshot.Tag), lifetime $($Config.Snapshot.Lifetime) (FlashArray only), sweep older than $($Config.Snapshot.SweepOlderThan)"
	Write-Host "Behaviour          : fail-safe path $($Config.Behaviour.FailSafePath), enforce StorageSnapshot mode $($Config.Behaviour.EnsureProcessingMode)"
	if ($DryRun) { Write-Host 'Mode               : DRY RUN (-WhatIf), nothing will be changed' }
}

function Invoke-EvpPrePhase {
	<#
	.SYNOPSIS
		Pre-job: snapshot every source once, point every share at its snapshot, sweep old ones.
	.OUTPUTS
		Exit code.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$stage = 'Veeam'
	$veeam = $null
	$resolved = [System.Collections.Generic.List[object]]::new()
	try {
		Write-EvpSection 'Veeam'
		$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
		# Job guard first: a clone of the job must not get past this point.
		$null = Assert-EvpVeeamJobSession -Session $veeam -Config $Config -Phase 'pre' -WarnOnly:$WhatIfPreference
		$inventory = Get-EvpVeeamShares -Session $veeam

		# Resolve every share before touching anything: a typo must not leave an orphan snapshot.
		$stage = 'Share'
		foreach ($share in $Config.Shares) {
			$entry = Find-EvpVeeamShare -Shares $inventory -VeeamPath $share.VeeamPath
			Write-Host "Share '$($share.VeeamPath)': $($entry.TypeName), mode $($entry.ProcessingMode), failover $($entry.FailoverEnabled), path '$($entry.StorageSnapshotPath)'"
			$resolved.Add([pscustomobject]@{ Config = $share; Inventory = $entry; Group = $null; Applied = $null })
		}

		Write-EvpSection 'Arrays'
		$stage = 'Array'
		$plan = Connect-EvpArraysForShares -Config $Config -Platform $Platform -Shares $Config.Shares
		foreach ($r in $resolved) {
			$r.Group = $plan.Groups.Values | Where-Object { $_.Shares -contains $r.Config } | Select-Object -First 1
		}

		Write-EvpSection 'Snapshots'
		$stage = 'Snapshot'
		# Every precondition first, so a problem on the last source does not leave snapshots
		# behind on the first ones.
		foreach ($g in $plan.Groups.Values) {
			if ($g.Session.Platform -eq 'FlashBlade' -and $g.SourceInfo.SnapshotDirectoryEnabled -eq $false) {
				throw "FlashBlade file system '$($g.SourceName)' has its snapshot directory disabled; Veeam cannot read '.snapshot' on it. Enable it on the array."
			}
		}
		$timestamp = Get-EvpTimestamp
		$created = @{}
		foreach ($key in $plan.Groups.Keys) {
			$g = $plan.Groups[$key]
			$keepFor = if ($g.Session.Platform -eq 'FlashArray') { $Config.Snapshot.LifetimeMs } else { 0 }
			$created[$key] = New-EvpArraySnapshot -Session $g.Session -SourceName $g.SourceName -Tag $Config.Snapshot.Tag -Timestamp $timestamp -KeepForMs $keepFor -WhatIf:$WhatIfPreference
		}

		Write-EvpSection 'Repoint shares'
		$stage = 'Share'
		foreach ($r in $resolved) {
			$key = '{0}|{1}' -f $r.Group.Array, $r.Group.SourceName
			$naming = $created[$key]
			$path = Get-EvpStorageSnapshotPath -VeeamPath $r.Config.VeeamPath -SnapshotDirectoryName $naming.DirectoryName -SnapshotRootDirName $Config.Snapshot.SnapshotRootDirName
			$r.Applied = Set-EvpVeeamStorageSnapshotPath -Session $veeam -Share $r.Inventory -StorageSnapshotPath $path -EnsureProcessingMode $Config.Behaviour.EnsureProcessingMode -WhatIf:$WhatIfPreference
		}

		if ($Config.Snapshot.SweepOlderThanMs -gt 0) {
			Write-EvpSection "Sweep snapshots older than $($Config.Snapshot.SweepOlderThan)"
			$stage = 'Snapshot'
			$cutoff = [datetime]::UtcNow.AddMilliseconds(-$Config.Snapshot.SweepOlderThanMs)
			$sweepFailed = 0
			foreach ($key in $plan.Groups.Keys) {
				$g = $plan.Groups[$key]
				try {
					$all = Get-EvpArraySnapshots -Session $g.Session -SourceName $g.SourceName
					$old = @($all | Where-Object {
							$ts = Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag
							$ts -and $ts -lt $cutoff -and $_.Name -ne $created[$key].ArrayName -and -not $_.Destroyed
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
		}

		Write-Host ''
		Write-Host 'Pre-backup phase completed. Veeam will read:'
		foreach ($r in $resolved) { Write-Host "  $($r.Config.VeeamPath)  <-  $($r.Applied)" }
		if ($sweepFailed) { Write-Warning 'The sweep reported failures (see above); the backup itself is set up.'; return $script:EvpExitCode.Partial }
		return $script:EvpExitCode.Success
	} catch {
		Write-Host ''
		Write-Host "Pre-backup phase FAILED during stage '$stage': $($_.Exception.Message)"
		Write-Verbose $_.ScriptStackTrace
		$code = $script:EvpExitCode[$stage]
		if ($resolved.Count -gt 0 -and $Config.Behaviour.FailSafePath -and $veeam) {
			$sentinel = Get-EvpSentinelDirectoryName
			$applied = 0
			foreach ($r in $resolved) {
				try {
					$path = Get-EvpStorageSnapshotPath -VeeamPath $r.Config.VeeamPath -SnapshotDirectoryName $sentinel -SnapshotRootDirName $Config.Snapshot.SnapshotRootDirName
					$null = Set-EvpVeeamStorageSnapshotPath -Session $veeam -Share $r.Inventory -StorageSnapshotPath $path -EnsureProcessingMode $true -WhatIf:$WhatIfPreference
					$applied++
				} catch { Write-Warning "Could not apply the fail-safe path to '$($r.Config.VeeamPath)': $($_.Exception.Message)" }
			}
			if ($applied -gt 0) {
				Write-Host "Fail-safe applied to $applied share(s): they now point at a non-existent snapshot path with failover off, so the job fails visibly instead of backing up stale or live data. A successful pre-backup run restores them."
				$code = $script:EvpExitCode.FailSafe
			}
		}
		return $code
	} finally {
		if ($veeam) { Disconnect-EvpVeeam -Session $veeam }
	}
}

function Invoke-EvpPostPhase {
	<#
	.SYNOPSIS
		Post-job: destroy the snapshots this tag created on every source of the job.
	.DESCRIPTION
		Destroys every snapshot matching the tag pattern, except those younger than
		Behaviour.PostKeepYoungerThan (for two jobs sharing one source). Veeam is contacted only
		for the job guard (Veeam.JobId); the shares keep pointing at the destroyed path until the
		next pre-backup run.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([int])]
	param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Platform)

	$stage = 'Snapshot'
	try {
		if ($Config.Veeam.JobId) {
			Write-EvpSection 'Veeam'
			$stage = 'Veeam'
			$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
			try { $null = Assert-EvpVeeamJobSession -Session $veeam -Config $Config -Phase 'post' -WarnOnly:$WhatIfPreference }
			finally { Disconnect-EvpVeeam -Session $veeam }
			$stage = 'Snapshot'
		}
		Write-EvpSection 'Arrays'
		$plan = Connect-EvpArraysForShares -Config $Config -Platform $Platform -Shares $Config.Shares
		Write-EvpSection 'Destroy snapshots'
		$keepCutoff = if ($Config.Behaviour.PostKeepYoungerThanMs -gt 0) { [datetime]::UtcNow.AddMilliseconds(-$Config.Behaviour.PostKeepYoungerThanMs) } else { $null }
		$matched = 0; $destroyed = 0; $failed = 0
		foreach ($key in $plan.Groups.Keys) {
			$g = $plan.Groups[$key]
			$all = Get-EvpArraySnapshots -Session $g.Session -SourceName $g.SourceName
			$mine = @($all | Where-Object {
					$ts = Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag
					-not $_.Destroyed -and $ts -and (-not $keepCutoff -or $ts -lt $keepCutoff)
				})
			Write-Host "$($g.Session.Platform) '$($g.SourceName)': $($mine.Count) snapshot(s) match '$($Config.Snapshot.Tag)'$(if ($keepCutoff) { " and are older than $($Config.Behaviour.PostKeepYoungerThan)" })."
			$matched += $mine.Count
			if ($mine.Count -gt 0) {
				$summary = Remove-EvpArraySnapshots -Session $g.Session -Snapshots $mine -WhatIf:$WhatIfPreference
				$destroyed += $summary.Destroyed; $failed += $summary.Failed
			}
		}
		Write-Host ''
		if ($matched -eq 0) {
			$message = "No snapshots matching tag '$($Config.Snapshot.Tag)' were found on any source. Nothing to clean up."
			if ($Config.Behaviour.FailIfNoSnapshots) { throw $message }
			Write-Warning $message
		} else {
			Write-Host "Destroyed $destroyed snapshot(s); $failed failure(s). Destroyed snapshots stay recoverable until the array's eradication delay expires."
		}
		Write-Host 'Post-backup phase completed.'
		return $(if ($failed -gt 0) { $script:EvpExitCode.Snapshot } else { $script:EvpExitCode.Success })
	} catch {
		Write-Host ''
		Write-Host "Post-backup phase FAILED during stage '$stage': $($_.Exception.Message)"
		Write-Verbose $_.ScriptStackTrace
		return $script:EvpExitCode[$stage]
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

	Write-EvpSection 'Veeam'
	$veeam = $null
	try {
		$veeam = Connect-EvpVeeam -Config $Config -Platform $Platform
		if ($Config.Veeam.JobId) {
			try {
				$job = Get-EvpVeeamJob -Session $veeam -JobId $Config.Veeam.JobId
				$active = @(Get-EvpVeeamActiveJobSessions -Session $veeam -Job $job)
				Write-Host "OK   bound to job '$($job.Name)' ($($job.Type)); $($active.Count) active session(s) right now. The pre and post phases run only inside a session of this job."
				if ($null -eq $job.ShareRoots) {
					Write-Host '     the REST backend does not list the job objects, so Shares is not compared with the job'
				} else {
					$configured = @($Config.Shares | ForEach-Object { Get-EvpNormalizedSharePath -VeeamPath $_.VeeamPath })
					$inJob = @($job.ShareRoots | ForEach-Object { Get-EvpNormalizedSharePath -VeeamPath $_ })
					foreach ($root in $job.ShareRoots) {
						if ((Get-EvpNormalizedSharePath -VeeamPath $root) -notin $configured) {
							Write-Host "FAIL job share '$root' is not in Shares; the job would back it up live"
							Add-Problem 'Config' "job share '$root' is missing from Shares"
						}
					}
					foreach ($share in $Config.Shares) {
						if ((Get-EvpNormalizedSharePath -VeeamPath $share.VeeamPath) -notin $inJob) { Write-Warning "$($share.VeeamPath) is configured but not part of job '$($job.Name)'" }
					}
				}
			} catch { Write-Host "FAIL job: $($_.Exception.Message)"; Add-Problem 'Veeam' $_.Exception.Message }
		}
		$inventory = Get-EvpVeeamShares -Session $veeam
		foreach ($share in $Config.Shares) {
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

	Write-EvpSection 'Arrays and sources'
	foreach ($arrayName in $Config.Arrays.Keys) {
		$arrayConfig = $Config.Arrays[$arrayName]
		$session = $null
		try {
			$token = Unprotect-EvpSecret -Path $arrayConfig.ApiTokenFile -Platform $Platform
			$session = Connect-EvpArray -ArrayConfig $arrayConfig -ApiToken $token
		} catch { Write-Host "FAIL $($arrayName): $($_.Exception.Message)"; Add-Problem 'Array' $_.Exception.Message; continue }
		foreach ($share in @($Config.Shares | Where-Object { $_.Array -eq $arrayName })) {
			try {
				$info = Resolve-EvpArraySource -Session $session -Share $share
				Write-Host "OK   $($share.VeeamPath) -> $($session.Platform) source '$($info.Name)'"
				if ($info.SnapshotDirectoryEnabled -eq $false) {
					Write-Host "FAIL $($share.VeeamPath): snapshot directory disabled on file system '$($info.Name)'"
					Add-Problem 'Snapshot' "FlashBlade file system '$($info.Name)' has its snapshot directory disabled"
				}
				$existing = @(Get-EvpArraySnapshots -Session $session -SourceName $info.Name | Where-Object { Get-EvpSnapshotTimestamp -Name $_.Name -Tag $Config.Snapshot.Tag })
				Write-Host "     $($existing.Count) existing snapshot(s) carry tag '$($Config.Snapshot.Tag)'"
			} catch { Write-Host "FAIL $($share.VeeamPath): $($_.Exception.Message)"; Add-Problem 'Array' $_.Exception.Message }
		}
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
