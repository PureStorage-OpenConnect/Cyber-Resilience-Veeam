# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Runs every test in this folder, plus a syntax parse and an optional PSScriptAnalyzer pass.

.DESCRIPTION
	Needs no FlashArray, no Veeam Backup & Replication server and no third-party modules. The
	FlashArray and Veeam cmdlets are stubbed, so this is safe to run anywhere, including on a
	workstation.

	Windows-only behaviour (the DPAPI token file, ACL hardening) is skipped with a SKIP line when
	the tests are not running on Windows.

.PARAMETER SkipAnalyzer
	Do not run PSScriptAnalyzer even if it is installed.

.EXAMPLE
	.\tests\Invoke-Tests.ps1
#>

[CmdletBinding()]
param(
	[switch] $SkipAnalyzer
)

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
	} else {
		Write-Host "PASS  $($_.Name)"
	}
}
if ($parseFailed -gt 0) { $failures++ }

foreach ($test in 'Test-PureVeeamFA.ps1', 'Test-FaFileScripts.ps1') {
	Write-Host ''
	Write-Host "=== $test ===" -ForegroundColor Cyan
	& (Join-Path $PSScriptRoot $test)
	if ($LASTEXITCODE -ne 0) { $failures++ }
}

if (-not $SkipAnalyzer) {
	Write-Host ''
	Write-Host '=== PSScriptAnalyzer ===' -ForegroundColor Cyan
	if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
		Import-Module PSScriptAnalyzer
		$settings = Join-Path $projectRoot 'PSScriptAnalyzerSettings.psd1'
		$findings = @()
		foreach ($file in 'fa-file-veeam-snapshot-pre-backup.ps1', 'fa-file-veeam-snapshot-post-backup.ps1', 'fa-veeam-credential-setup.ps1', 'PureVeeamFA.psm1') {
			$findings += Invoke-ScriptAnalyzer -Path (Join-Path $projectRoot $file) -Settings $settings -Severity Error, Warning
		}
		if ($findings.Count -eq 0) {
			Write-Host 'PASS  no Error or Warning findings'
		} else {
			$failures++
			$findings | ForEach-Object { Write-Host ("FAIL  {0}:{1} [{2}] {3}" -f $_.ScriptName, $_.Line, $_.Severity, $_.RuleName) -ForegroundColor Red }
		}
	} else {
		Write-Host 'SKIP  PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser)' -ForegroundColor Yellow
	}
}

Write-Host ''
Write-Host '======================================='
if ($failures -eq 0) {
	Write-Host 'All test suites passed.' -ForegroundColor Green
	exit 0
}
Write-Host "$failures test suite(s) reported failures." -ForegroundColor Red
exit 1
