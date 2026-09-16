# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Minimal assertion helpers shared by the test scripts in this folder.

	Deliberately dependency-free rather than Pester-based: these tests are meant to be runnable on
	a Veeam Backup & Replication server with nothing beyond the PowerShell 7 the Veeam module
	already requires.
#>

$script:TestPassed = 0
$script:TestFailed = 0
$script:TestSkipped = 0

function Reset-TestCounters {
	$script:TestPassed = 0
	$script:TestFailed = 0
	$script:TestSkipped = 0
}

function Get-TestCounters {
	[pscustomobject]@{
		Passed  = $script:TestPassed
		Failed  = $script:TestFailed
		Skipped = $script:TestSkipped
	}
}

function Write-TestSection {
	param([Parameter(Mandatory)] [string] $Name)
	Write-Host ''
	Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Assert-Equal {
	param(
		[Parameter(Mandatory)] [string] $Name,
		$Actual,
		$Expected
	)
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

function Assert-Throws {
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [scriptblock] $ScriptBlock,
		[string] $MessagePattern
	)
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

function Get-PowerShellHostPath {
	<# Path of the host running these tests, so child processes use the same edition. #>
	return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Test-IsWindowsHost {
	if ($env:OS -eq 'Windows_NT') { return $true }
	return ([System.Environment]::OSVersion.Platform -eq 'Win32NT')
}
