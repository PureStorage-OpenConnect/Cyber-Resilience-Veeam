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
	Creates the per-job files: a configuration bound to the job and the pre/post wrapper scripts
	that go into the Veeam job's script settings. The first run also creates the arrays file.

.DESCRIPTION
	The configuration only names the job (Veeam.JobId): the shares are read from the job at run
	time and mapped to the arrays listed once in jobs/arrays.jsonc, which this script copies from
	arrays.sample.jsonc when it does not exist yet. File backup and file-to-tape jobs both work.

	Veeam's job dialog on the Software Appliance accepts a script file, not a command line, and
	the sandbox passes neither arguments nor environment variables. The main script therefore
	cannot be told which job it serves. A wrapper is a two-line .ps1 per job and phase that
	hard-codes the absolute paths, generated here for the platform it runs on. On a Windows
	backup server the wrappers work too, or the main script can be given its arguments directly
	in the job dialog; the generator prints both forms.

.PARAMETER Job
	Job name, used for the file names: jobs/<Job>.jsonc, jobs/<Job>-pre.ps1, jobs/<Job>-post.ps1.

.PARAMETER JobId
	ID of the Veeam job, written to Veeam.JobId in the configuration: the job the shares are read
	from, and the job guard (see the README). When omitted and the Veeam PowerShell module is
	available, the file backup or file-to-tape job is looked up by name on the local backup
	server.

.PARAMETER JobsDirectory
	Where the files go. Defaults to a 'jobs' folder beside this script.

.PARAMETER Force
	Overwrite the job's existing configuration. Without it an existing configuration is kept and
	only the wrappers are rewritten. The arrays file is never overwritten.

.EXAMPLE
	.\New-EverpureVeeamJobScripts.ps1 -Job lab-files
#>

#Requires -Version 7.0
#Requires -PSEdition Core

[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
	[Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')] [string] $Job,
	[ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')] [string] $JobId,
	[string] $JobsDirectory,
	[switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1') -Force -ErrorAction Stop
$platform = Get-EvpPlatform

if (-not $JobsDirectory) { $JobsDirectory = Join-Path $PSScriptRoot 'jobs' }
$JobsDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JobsDirectory)
if (-not (Test-Path -LiteralPath $JobsDirectory -PathType Container)) {
	if ($PSCmdlet.ShouldProcess($JobsDirectory, 'Create directory')) { New-Item -ItemType Directory -Path $JobsDirectory -Force | Out-Null }
}

$mainScript = Join-Path $PSScriptRoot 'Invoke-EverpureVeeamNasSnapshot.ps1'
$configPath = Join-Path $JobsDirectory "$Job.jsonc"
$arraysPath = Join-Path $JobsDirectory 'arrays.jsonc'
$written = [System.Collections.Generic.List[string]]::new()

# Job ID: given, or looked up by name where the Veeam module is at hand.
if (-not $JobId -and (Test-EvpVeeamModule)) {
	try {
		$found = @(Find-EvpVeeamJobByName -Name $Job)
		if ($found.Count -eq 1) { $JobId = $found[0].Id; Write-Host "Veeam $($found[0].Kind) job '$Job' found, ID $JobId." }
		elseif ($found.Count -eq 0) { Write-Warning "No file backup or file-to-tape job named '$Job' exists on this server. Pass -JobId, or fill in Veeam.JobId once the job exists." }
		else { Write-Warning "$($found.Count) jobs match '$Job' ($(($found | ForEach-Object { "$($_.Kind) $($_.Id)" }) -join ', ')); pass -JobId." }
	} catch { Write-Warning "Could not look up job '$Job': $($_.Exception.Message). Pass -JobId, or fill in Veeam.JobId later." }
} elseif (-not $JobId) {
	Write-Warning 'The Veeam PowerShell module is not available here, so Veeam.JobId stays empty. Pass -JobId.'
}
if (-not $JobId) { Write-Warning 'Without Veeam.JobId the configuration needs every share of the job listed in Shares, and has no job guard.' }

if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
	Write-Host "Keeping existing configuration '$configPath' (use -Force to overwrite)."
	if ($JobId) { Write-Host "  Make sure its Veeam.JobId is `"$JobId`"." }
} elseif ($PSCmdlet.ShouldProcess($configPath, 'Write job configuration')) {
	$sample = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.sample.jsonc') -Raw
	if ($JobId) { $sample = $sample.Replace('"JobId": ""', "`"JobId`": `"$JobId`"") }
	$header = "// Configuration for Veeam job '$Job'. Generated $(Get-Date -Format 'yyyy-MM-dd') from config.sample.jsonc. The shares come from the job and the arrays from arrays.jsonc; nothing needs editing here.`n"
	[System.IO.File]::WriteAllText($configPath, $header + $sample, [System.Text.UTF8Encoding]::new($false))
	$written.Add($configPath)
}

# One arrays file for all jobs in this folder; never overwritten, it holds the admin's list.
$arraysCreated = $false
if (-not (Test-Path -LiteralPath $arraysPath) -and $PSCmdlet.ShouldProcess($arraysPath, 'Write arrays file')) {
	Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'arrays.sample.jsonc') -Destination $arraysPath
	$written.Add($arraysPath)
	$arraysCreated = $true
}

# Single-quoted literals in the wrappers: a quote in a path is doubled, the PowerShell escape.
$mainLiteral = $mainScript.Replace("'", "''")
$configLiteral = $configPath.Replace("'", "''")
foreach ($phase in 'pre', 'post') {
	$wrapperPath = Join-Path $JobsDirectory "$Job-$phase.ps1"
	$content = @"
# Generated by New-EverpureVeeamJobScripts.ps1 on $(Get-Date -Format 'yyyy-MM-dd') for Veeam job '$Job'. Do not edit; regenerate.
& '$mainLiteral' -Phase $phase -ConfigFile '$configLiteral'
exit `$LASTEXITCODE
"@
	if ($PSCmdlet.ShouldProcess($wrapperPath, 'Write wrapper')) {
		[System.IO.File]::WriteAllText($wrapperPath, $content, [System.Text.UTF8Encoding]::new($false))
		$written.Add($wrapperPath)
	}
}

Write-Host ''
Write-Host "Files for job '$Job':"
foreach ($f in $written) { Write-Host "  $f" }
Write-Host "Snapshot tag: $(Get-EvpDefaultSnapshotTag -ProfileName $Job -JobId $JobId) (default for this configuration; unique per job, so jobs on one array source never sweep each other's snapshots)"
Write-Host ''
Write-Host 'Next steps:'
if ($arraysCreated) {
	Write-Host "  1. List every FlashArray and FlashBlade once in $arraysPath (it starts empty, with examples)."
	Write-Host '     Which array serves which share is worked out from the arrays'' file interfaces.'
} else {
	Write-Host "  1. Check that $arraysPath lists the arrays this job's shares live on."
}
Write-Host "  2. Store each array's token once: .\Protect-EverpureVeeamSecret.ps1 -Path <token file from arrays.jsonc> -Endpoint <array> -Verify"
Write-Host "  3. Verify: pwsh -NoProfile -File '$mainScript' -Phase verify -ConfigFile '$configPath'"
Write-Host '     It lists the shares of the job and the array and source each one maps to.'
if ($platform.IsLinux) {
	Write-Host '  4. Appliance: upload this folder to /var/lib/veeam/scripts via the console Files node, then select'
	Write-Host "     $Job-pre.ps1 as the pre-job script and $Job-post.ps1 as the post-job script."
} else {
	Write-Host '  4. Windows: in the job''s Advanced > Scripts settings use either the wrappers:'
	Write-Host "       pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $JobsDirectory "$Job-pre.ps1")`""
	Write-Host '     or the main script directly:'
	Write-Host "       pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$mainScript`" -Phase pre -ConfigFile `"$configPath`""
}
