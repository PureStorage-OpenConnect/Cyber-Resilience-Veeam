# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Module manifest for EverpureVeeamNas. ModuleVersion is the single source of the script
# version (semantic versioning, MAJOR.MINOR.PATCH): bump it here and add a CHANGELOG.md entry.
# Every run prints it, Get-EvpVersion returns it, and the test suite checks both against this
# file. The function list stays in Export-ModuleMember in the .psm1.

@{
	RootModule           = 'EverpureVeeamNas.psm1'
	ModuleVersion        = '1.0.0'
	GUID                 = 'beffbcbb-7247-4f5e-9d58-118514433ec2'
	Author               = 'Stefan Zimmermann'
	CompanyName          = 'Everpure, Inc.'
	Copyright            = 'Copyright 2026 Everpure, Inc. Licensed under the Apache License, Version 2.0.'
	Description          = 'Veeam Backup & Replication 13.1 pre/post job scripts that back up Everpure FlashArray File and FlashBlade shares (SMB and NFS) from storage snapshots. PowerShell 7 and REST only; runs on a Windows backup server and on the Veeam Software Appliance. Community example scripts, provided as is.'
	PowerShellVersion    = '7.0'
	CompatiblePSEditions = @('Core')
	FunctionsToExport    = '*'
	CmdletsToExport      = @()
	VariablesToExport    = @()
	AliasesToExport      = @()
	PrivateData          = @{
		PSData = @{
			Tags         = @('Veeam', 'Everpure', 'FlashArray', 'FlashBlade', 'NAS', 'Snapshot', 'Backup')
			LicenseUri   = 'https://www.apache.org/licenses/LICENSE-2.0'
			ProjectUri   = 'https://github.com/PureStorage-OpenConnect/Cyber-Resilience-Veeam'
			ReleaseNotes = 'See CHANGELOG.md next to this file.'
		}
	}
}
