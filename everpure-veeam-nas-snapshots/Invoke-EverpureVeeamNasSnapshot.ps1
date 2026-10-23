# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#  Disclaimer
	The sample script and documentation are provided AS IS and are not supported by
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
.SYNOPSIS
	Veeam pre/post job script: backs up Everpure FlashArray File and FlashBlade shares from
	storage snapshots. One script, three phases, one configuration file per Veeam job.

.DESCRIPTION
	pre     Creates one snapshot per array source used by the job's shares, points every share
	        (SMB or NFS) at its snapshot path with direct-backup failover off, and sweeps
	        snapshots older than Snapshot.KeepFor. If anything fails after the shares
	        were resolved, every share is pointed at a non-existent sentinel path so the job
	        fails visibly instead of backing up stale or live data (Veeam only warns when a
	        pre-job script fails).
	post    Points every share at a non-existent path (disarm), then destroys the snapshots
	        carrying this configuration's tag that are older than Snapshot.KeepFor on every
	        source. Optional but highly recommended: without it a next run whose pre phase fails
	        before its fail-safe (Veeam unreachable, script killed) backs up the last snapshot
	        again and reports success, and snapshots stay until the next pre phase sweeps them.
	verify  Checks secrets, Veeam access, share resolution, array access and source mapping
	        without changing anything. Run it after installation and after every config change.

	Runs unchanged on a Windows backup server (Veeam PowerShell cmdlets) and on the Veeam
	Software Appliance (REST API, once Veeam ships the fix for case #08278019). All behaviour
	comes from the configuration file; the script itself is never edited.

.PARAMETER Phase
	pre, post or verify.

.PARAMETER ConfigFile
	Path to the configuration file (JSON with comments). See config.sample.jsonc. On the
	appliance, jobs run generated wrapper scripts that hard-code this path, because the
	sandbox passes neither arguments nor environment variables.

.PARAMETER WhatIf
	Dry run: logs every snapshot it would create or destroy and every share it would repoint,
	and changes nothing.

.PARAMETER NoJobGuard
	Skip the job guard (Veeam.JobId) for this run. Needed when a phase is run by hand outside a
	job session, for example the post phase after a cancelled job. Never put it in a job's
	script command line.

.EXAMPLE
	pwsh -NoProfile -File .\Invoke-EverpureVeeamNasSnapshot.ps1 -Phase verify -ConfigFile .\jobs\lab-files.jsonc

.EXAMPLE
	pwsh -NoProfile -ExecutionPolicy Bypass -File C:\01_SCRIPTS\everpure-veeam-nas\Invoke-EverpureVeeamNasSnapshot.ps1 -Phase pre -ConfigFile C:\01_SCRIPTS\everpure-veeam-nas\jobs\lab-files.jsonc

	Pre-job script command line on a Windows backup server.

.NOTES
	Exit codes: 0 success, 1 configuration, 2 Veeam connection, 3 share resolution or update,
	4 array connection, 5 snapshot create or destroy, 6 partial success (sweep or disarm
	failures, see the log), 10 failure with the
	fail-safe path applied. Veeam treats any non-zero code as a warning and runs the job.

	Version: ModuleVersion in EverpureVeeamNas.psd1 (semantic versioning), printed at the start
	of every run and listed in CHANGELOG.md.
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[Parameter(Mandatory)] [ValidateSet('pre', 'post', 'verify')] [string] $Phase,
	[Parameter(Mandatory)] [string] $ConfigFile,
	[switch] $NoJobGuard
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module -Name (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1') -Force -ErrorAction Stop

$platform = Get-EvpPlatform
$exitCode = 1
$logStarted = $false
try {
	# Configuration first: it supplies the log location. A broken config therefore reports on
	# stdout only, which Veeam still captures in the job log.
	$config = Get-EvpConfig -Path $ConfigFile

	$logDirectory = $config.Logging.Directory
	if (-not $logDirectory) { $logDirectory = Get-EvpDefaultLogDirectory -Platform $platform -InstallRoot (Get-EvpModuleRoot) -ConfigDirectory $config.ConfigDirectory }
	$null = Start-EvpLog -LogDirectory $logDirectory -ProfileName $config.ProfileName -Phase $Phase -RetentionDays $config.Logging.RetentionDays
	$logStarted = $true
	Initialize-EvpEnvironment -Platform $platform -WritableDirectory $logDirectory

	Write-Host ''
	Write-EvpPlan -Config $config -Platform $platform -Phase $Phase -DryRun:$WhatIfPreference
	if ($NoJobGuard -and $config.Veeam.JobId) {
		Write-Host 'Job guard          : DISABLED for this run (-NoJobGuard); the job is still read for its shares'
		$config.Veeam.JobGuard = $false
	}

	switch ($Phase) {
		'pre' { $exitCode = Invoke-EvpPrePhase -Config $config -Platform $platform -WhatIf:$WhatIfPreference }
		'post' { $exitCode = Invoke-EvpPostPhase -Config $config -Platform $platform -WhatIf:$WhatIfPreference }
		'verify' { $exitCode = Invoke-EvpVerifyPhase -Config $config -Platform $platform }
	}
} catch {
	Write-Host ''
	Write-Host "FAILED before the $Phase phase could start: $($_.Exception.Message)"
	Write-Verbose $_.ScriptStackTrace
	$exitCode = 1
} finally {
	Write-Host ''
	Write-Host "Exit code: $exitCode"
	if ($logStarted) { Stop-EvpLog }
}

exit $exitCode
