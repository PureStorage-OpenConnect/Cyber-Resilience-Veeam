@{
	# Write-Host is the deliberate output mechanism in these scripts. Veeam invokes them
	# non-interactively and progress is captured with Start-Transcript, which records the
	# information stream that Write-Host writes to. Write-Output would pollute the return value
	# of the pre-backup script, and Write-Verbose is off by default.
	ExcludeRules = @(
		'PSAvoidUsingWriteHost'
	)
}
