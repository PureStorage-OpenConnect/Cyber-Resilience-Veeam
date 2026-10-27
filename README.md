# Cyber-Resilience-Veeam

Veeam Backup & Replication automation and orchestration scripts for Everpure storage systems.

## Contents

| | Purpose |
| --- | --- |
| [everpure-veeam-nas-snapshots/](everpure-veeam-nas-snapshots/) | **Unified backup from snapshot for FlashArray File and FlashBlade**, SMB and NFS, Veeam Backup & Replication 13.1. One configuration file per job, PowerShell 7 and REST only, runs on a Windows backup server today and on the Veeam Software Appliance once Veeam fixes its REST API (see the folder README). Start here for new deployments. |
| [veeam-fb-multi-obj-account-setup.ps1](veeam-fb-multi-obj-account-setup.ps1) | Wires multiple FlashBlade//S3 buckets into Veeam as object storage repositories. |

`veeam-fb-multi-obj-account-setup.ps1` takes its settings and credentials inline; edit the
variables at the top before running it.

Versions are per script, not per repository. A versioned script keeps its CHANGELOG in its
folder, and its releases are tagged `<component>/v<version>`, for example `nas-snapshots/v1.1.0`
for [everpure-veeam-nas-snapshots/](everpure-veeam-nas-snapshots/). `main` holds the latest
release of every script; work in progress lives on `dev`.

[docs/](docs/) holds the design plan for the unified scripts. The Veeam REST API defect that
currently blocks the appliance is tracked in [this Veeam forum thread](https://forums.veeam.com/viewtopic.php?f=30&t=104809).

Older scripts that were replaced by the unified folder, the earlier FlashArray-only and
FlashBlade-only pre/post job scripts, have been removed and remain available in the git history.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Copyright 2026 Everpure, Inc.

## Disclaimer

These scripts are provided as-is, as examples, and are not supported by Everpure. See the
header of each script for the full text. This is in addition to, not instead of, the warranty
disclaimer in sections 7 and 8 of the license.
