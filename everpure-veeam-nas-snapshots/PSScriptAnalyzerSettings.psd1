@{
	# Write-Host is the deliberate output mechanism: Veeam runs these scripts non-interactively
	# and the transcript records the information stream. Write-Output would pollute the return
	# values of the phase functions, which are exit codes.
	ExcludeRules = @(
		'PSAvoidUsingWriteHost'
		# Functions returning collections (Get-EvpVeeamShares, Get-EvpArraySnapshots, ...) are
		# deliberately plural; the Veeam cmdlets they wrap follow the same convention.
		'PSUseSingularNouns'
	)
}
