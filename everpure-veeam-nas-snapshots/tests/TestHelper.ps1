# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Minimal assertion helpers shared by the test scripts in this folder. Dependency-free rather
	than Pester-based, so the suite runs on a backup server or the appliance with nothing beyond
	PowerShell 7.
#>

$script:TestPassed = 0
$script:TestFailed = 0
$script:TestSkipped = 0

function Initialize-TestCounters { $script:TestPassed = 0; $script:TestFailed = 0; $script:TestSkipped = 0 }

function Get-TestCounters {
	[pscustomobject]@{ Passed = $script:TestPassed; Failed = $script:TestFailed; Skipped = $script:TestSkipped }
}

function Write-TestSection {
	param([Parameter(Mandatory)] [string] $Name)
	Write-Host ''
	Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Assert-Equal {
	param([Parameter(Mandatory)] [string] $Name, $Actual, $Expected)
	if ("$Actual" -eq "$Expected") {
		Write-Host "PASS  $Name"
		$script:TestPassed++
	} else {
		Write-Host "FAIL  $Name" -ForegroundColor Red
		Write-Host "        expected: $Expected" -ForegroundColor Red
		Write-Host "        actual  : $Actual" -ForegroundColor Red
		$script:TestFailed++
	}
}

function Assert-True {
	param([Parameter(Mandatory)] [string] $Name, $Condition)
	Assert-Equal -Name $Name -Actual ([bool]$Condition) -Expected $true
}

function Assert-Throws {
	param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [scriptblock] $ScriptBlock, [string] $MessagePattern)
	try {
		& $ScriptBlock | Out-Null
		Write-Host "FAIL  $Name (no exception was thrown)" -ForegroundColor Red
		$script:TestFailed++
	} catch {
		if (-not $MessagePattern -or $_.Exception.Message -match $MessagePattern) {
			Write-Host "PASS  $Name"
			$script:TestPassed++
		} else {
			Write-Host "FAIL  $Name" -ForegroundColor Red
			Write-Host "        message did not match: $MessagePattern" -ForegroundColor Red
			Write-Host "        actual message       : $($_.Exception.Message)" -ForegroundColor Red
			$script:TestFailed++
		}
	}
}

function Write-TestSkipped {
	param([Parameter(Mandatory)] [string] $Name, [string] $Reason)
	Write-Host "SKIP  $Name$(if ($Reason) { " ($Reason)" })" -ForegroundColor Yellow
	$script:TestSkipped++
}

function Get-PowerShellHostPath { return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }

function Test-IsWindowsHost { return [bool]($IsWindows -or $env:OS -eq 'Windows_NT') }

function Get-TestDirectory {
	<# Fresh temporary directory for one test run. #>
	param([string] $Prefix = 'evp-test')
	$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}" -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 8))
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	return $dir
}

function Write-TestFile {
	param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
	$parent = Split-Path -Parent $Path
	if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
	[System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
	return $Path
}

function Complete-TestRun {
	<# Prints the summary and exits non-zero on failures. Call at the end of every suite. #>
	$c = Get-TestCounters
	Write-Host ''
	Write-Host ("{0} passed, {1} failed, {2} skipped" -f $c.Passed, $c.Failed, $c.Skipped) -ForegroundColor $(if ($c.Failed) { 'Red' } else { 'Green' })
	if ($c.Failed -gt 0) { exit 1 }
	exit 0
}
