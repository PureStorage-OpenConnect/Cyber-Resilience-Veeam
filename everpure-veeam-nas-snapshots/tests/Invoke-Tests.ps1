# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Runs every test suite in this folder, plus a syntax parse and PSScriptAnalyzer when installed.

.DESCRIPTION
	Needs no array, no Veeam server and no third-party module: HTTP is replaced by a scripted
	responder and the Veeam cmdlets by a stub module, so this runs on a workstation, a backup
	server or the appliance. Exit code 0 when everything passes, 1 otherwise.

.PARAMETER SkipAnalyzer
	Do not run PSScriptAnalyzer even if it is installed.
#>

[CmdletBinding()]
param([switch] $SkipAnalyzer)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = 0

Write-Host ''
Write-Host '=== Syntax check ===' -ForegroundColor Cyan
$parseFailed = 0
Get-ChildItem -Path $projectRoot -Include '*.ps1', '*.psm1', '*.psd1' -Recurse | Sort-Object FullName | ForEach-Object {
	$errors = $null
	[System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
	if ($errors -and $errors.Count -gt 0) {
		$parseFailed++
		Write-Host "FAIL  $($_.Name)" -ForegroundColor Red
		$errors | ForEach-Object { Write-Host ("        line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
	} else { Write-Host "PASS  $($_.Name)" }
}
if ($parseFailed -gt 0) { $failures++ }

foreach ($test in 'Test-EvpCommon.ps1', 'Test-EvpHttp.ps1', 'Test-EvpIntegration.ps1') {
	Write-Host ''
	Write-Host "=== $test ===" -ForegroundColor Cyan
	& ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -File (Join-Path $PSScriptRoot $test)
	if ($LASTEXITCODE -ne 0) { $failures++ }
}

if (-not $SkipAnalyzer) {
	Write-Host ''
	Write-Host '=== PSScriptAnalyzer ===' -ForegroundColor Cyan
	if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
		Import-Module PSScriptAnalyzer
		# Product files only: the test doubles deliberately break production rules (stub cmdlets
		# with unused parameters, plain-text secrets, state-changing helpers without ShouldProcess).
		$productFiles = @(Get-ChildItem -Path $projectRoot -File -Include '*.ps1', '*.psm1' -Depth 0) + @(Get-ChildItem -Path (Join-Path $projectRoot 'lib') -File -Filter '*.ps1')
		$findings = @($productFiles | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings (Join-Path $projectRoot 'PSScriptAnalyzerSettings.psd1') -Severity Error, Warning })
		if ($findings.Count -eq 0) { Write-Host 'PASS  no Error or Warning findings' }
		else {
			$failures++
			$findings | ForEach-Object { Write-Host ("FAIL  {0}:{1} [{2}] {3}" -f $_.ScriptName, $_.Line, $_.Severity, $_.RuleName) -ForegroundColor Red }
		}
	} else { Write-Host 'SKIP  PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser)' -ForegroundColor Yellow }
}

Write-Host ''
if ($failures -eq 0) { Write-Host 'All test suites passed.' -ForegroundColor Green; exit 0 }
Write-Host "$failures test suite(s) reported failures." -ForegroundColor Red
exit 1
