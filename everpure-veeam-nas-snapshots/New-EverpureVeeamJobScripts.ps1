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
	from, and the job guard (see the README). When omitted, the file backup or file-to-tape job
	is looked up by name on the local backup server, and nothing is written unless exactly one
	job matches. When given on a host with the Veeam PowerShell module, it must name an existing
	job; elsewhere (a workstation, the appliance) it is taken as is and the verify phase checks it.

.PARAMETER NoJobId
	Write a configuration without a job binding, as in 1.0.0: no job guard, and every share of
	the job must then be listed in Shares by hand. For special cases only.

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
	[switch] $NoJobId,
	[switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'EverpureVeeamNas.psd1') -Force -ErrorAction Stop
$platform = Get-EvpPlatform

if (-not $JobsDirectory) { $JobsDirectory = Join-Path $PSScriptRoot 'jobs' }
$JobsDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JobsDirectory)

$mainScript = Join-Path $PSScriptRoot 'Invoke-EverpureVeeamNasSnapshot.ps1'
$configPath = Join-Path $JobsDirectory "$Job.jsonc"
$arraysPath = Join-Path $JobsDirectory 'arrays.jsonc'
$written = [System.Collections.Generic.List[string]]::new()

# Job ID: looked up by name, or given and checked where the Veeam module is at hand. Nothing is
# written without one (unless -NoJobId): the configuration would not load, and a wrong ID would
# only surface at the first job run.
if ($NoJobId -and $JobId) { throw 'Use either -JobId or -NoJobId, not both.' }
$haveModule = (-not $NoJobId) -and (Test-EvpVeeamModule)
if ($NoJobId) {
	Write-Warning 'No job binding (-NoJobId): no job guard, and every share of the job must be listed in Shares in the configuration before it loads.'
} elseif (-not $JobId) {
	if (-not $haveModule) { throw "The Veeam PowerShell module is not available here, so job '$Job' cannot be looked up. Pass -JobId <job ID>. Nothing was written." }
	try { $found = @(Find-EvpVeeamJobByName -Name $Job) }
	catch { throw "Could not look up job '$Job': $($_.Exception.Message). Pass -JobId <job ID>. Nothing was written." }
	if ($found.Count -eq 0) {
		throw "No file backup or file-to-tape job named '$Job' exists on this server. The name must match the job exactly, or pass -JobId <job ID> (Get-VBRUnstructuredBackupJob | Select-Object Name, Id). Nothing was written."
	}
	if ($found.Count -gt 1) {
		throw "$($found.Count) jobs are named '$Job' ($(($found | ForEach-Object { "$($_.Kind) $($_.Id)" }) -join ', ')). Pass -JobId with the one you mean. Nothing was written."
	}
	$JobId = $found[0].Id
	Write-Host "Veeam $($found[0].Kind) job '$Job' found, ID $JobId."
} elseif ($haveModule) {
	try { $bound = Get-EvpVeeamJob -Session ([pscustomobject]@{ Backend = 'PowerShell' }) -JobId $JobId }
	catch { throw "$($_.Exception.Message) Check -JobId. Nothing was written." }
	$JobId = $bound.Id
	Write-Host "Veeam $($bound.Kind) job '$($bound.Name)' found for ID $JobId$(if ($bound.Name -ne $Job) { " (the files are still named after '$Job')" })."
} else {
	$JobId = $JobId.ToLowerInvariant()
	Write-Warning "The Veeam PowerShell module is not available here, so job ID $JobId is not checked now. The verify phase checks it."
}

if (-not (Test-Path -LiteralPath $JobsDirectory -PathType Container)) {
	if ($PSCmdlet.ShouldProcess($JobsDirectory, 'Create directory')) { New-Item -ItemType Directory -Path $JobsDirectory -Force | Out-Null }
}

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
	Write-Host "  1. Add every FlashArray and FlashBlade once, with its token (elevated PowerShell):"
} else {
	Write-Host "  1. Make sure $arraysPath lists the arrays this job's shares live on. To add one (elevated PowerShell):"
}
Write-Host '       .\Protect-EverpureVeeamSecret.ps1 -Array <name> -Endpoint <management address>'
Write-Host "     It adds the array to $arraysPath, prompts for the API token, stores it and tests it."
Write-Host '     Which array serves which share is worked out from the arrays'' file interfaces.'
Write-Host '  2. Optional: pin each array''s certificate (the helper prints its hash) in its "Tls" in arrays.jsonc.'
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
