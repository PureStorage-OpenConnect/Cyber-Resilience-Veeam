# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Logging: one transcript per run, named '<profile>-<timestamp>-<phase>.log', pruned by age.
	The same lines go to stdout, which Veeam stores in its job log on both platforms.
	Output is written with Write-Host on purpose: Start-Transcript records the information
	stream, and Write-Output would pollute function return values.
#>

function Get-EvpDefaultLogDirectory {
	<#
	.SYNOPSIS
		Picks the platform default for the log directory.
	.DESCRIPTION
		Windows: a 'log' folder under the install root. Appliance sandbox: the only persistent
		writable place is /var/lib/veeam/scripts/sandbox, so a folder in there. Anything else: a
		'log' folder beside the configuration file.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] $Platform,
		[Parameter(Mandatory)] [string] $InstallRoot,
		[Parameter(Mandatory)] [string] $ConfigDirectory
	)
	if ($Platform.IsWindows) { return (Join-Path $InstallRoot 'log') }
	# Linux paths are built with '/' explicitly: Join-Path would use the separator of the host
	# running the code, which differs when a Windows test simulates the appliance platform.
	if ($Platform.InSandbox) { return "$($Platform.SandboxRoot.TrimEnd('/'))/everpure-veeam-nas/log" }
	return "$($ConfigDirectory.TrimEnd('/'))/log"
}

function Start-EvpLog {
	<#
	.SYNOPSIS
		Starts the run transcript and prunes old ones for the same profile.
	.OUTPUTS
		The transcript path.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Starting a transcript is not a change a caller would confirm, and -WhatIf must not suppress the log of the dry run it describes.')]
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] [string] $LogDirectory,
		[Parameter(Mandatory)] [string] $ProfileName,
		[Parameter(Mandatory)] [ValidateSet('pre', 'post', 'verify')] [string] $Phase,
		[int] $RetentionDays = 30
	)

	# -WhatIf:$false throughout: on PowerShell 7.6 the caller's -WhatIf reaches these cmdlets
	# through the module boundary, and a dry run without a transcript is a dry run nobody can
	# read afterwards. Housekeeping is never part of what -WhatIf describes.
	if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
		New-Item -ItemType Directory -Path $LogDirectory -Force -WhatIf:$false | Out-Null
	}
	$logPath = Join-Path $LogDirectory ('{0}-{1}-{2}.log' -f $ProfileName, (Get-Date -Format 'yyyyMMddHHmmss'), $Phase)
	try { Stop-Transcript -WhatIf:$false | Out-Null } catch { Write-Verbose 'No transcript was running.' }
	Start-Transcript -Path $logPath -WhatIf:$false | Out-Null
	Write-Host "Transcript: $logPath"

	if ($RetentionDays -gt 0) {
		$cutoff = (Get-Date).AddDays(-$RetentionDays)
		$stale = @(Get-ChildItem -LiteralPath $LogDirectory -Filter "$ProfileName-*.log" -File -ErrorAction SilentlyContinue |
				Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -ne $logPath })
		foreach ($old in $stale) {
			try {
				Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop -WhatIf:$false
				Write-Host "Pruned transcript older than $RetentionDays days: $($old.Name)"
			} catch { Write-Warning "Could not prune '$($old.Name)': $($_.Exception.Message)" }
		}
	}
	return $logPath
}

function Stop-EvpLog {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Closes the transcript from a finally block.')]
	[CmdletBinding()]
	param()
	try { Stop-Transcript -WhatIf:$false | Out-Null } catch { Write-Verbose 'No transcript was running.' }
}

function Write-EvpSection {
	<# Visual separator in the transcript. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] [string] $Title)
	Write-Host ''
	Write-Host "--- $Title ---"
}
