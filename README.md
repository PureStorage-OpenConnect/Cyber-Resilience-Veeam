# Cyber-Resilience-Veeam

Veeam Backup & Replication automation and orchestration scripts for Everpure storage systems.

## Contents

| | Purpose |
| --- | --- |
| [everpure-veeam-nas-snapshots/](everpure-veeam-nas-snapshots/) | **Unified backup from snapshot for FlashArray File and FlashBlade**, SMB and NFS, Veeam Backup & Replication 13.1. One configuration file per job, PowerShell 7 and REST only, runs on a Windows backup server today and on the Veeam Software Appliance once Veeam fixes its REST API (see the folder README). Start here for new deployments. |
| [flasharray-veeam-nas-snapshots/](flasharray-veeam-nas-snapshots/) | **FlashArray File backup from snapshot** for Veeam NAS backup jobs, the earlier generation. Pre/post job scripts that point a Veeam file share at a Managed Directory snapshot, for SMB shares and NFS exports. Kept for existing installations; new work goes into the unified folder. |
| [fb-file-veeam-snapshot-pre-backup-script-example.ps1](fb-file-veeam-snapshot-pre-backup-script-example.ps1) | FlashBlade//File equivalent of the above, as a single-file example. |
| [fb-file-veeam-snapshot-post-backup-script-example.ps1](fb-file-veeam-snapshot-post-backup-script-example.ps1) | Destroys the snapshots created by the FlashBlade//File pre-backup example. |
| [veeam-fb-multi-obj-account-setup.ps1](veeam-fb-multi-obj-account-setup.ps1) | Wires multiple FlashBlade//S3 buckets into Veeam as object storage repositories. |

The `fb-*` scripts and `veeam-fb-multi-obj-account-setup.ps1` take their settings and credentials
inline, so each copy serves one share. The FlashBlade file share case is covered by the unified
folder; the single-file examples stay for reference.

[docs/](docs/) holds the design plan for the unified scripts and the write-up of the Veeam REST
API defect that currently blocks the appliance.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Copyright 2026 Everpure, Inc.

## Disclaimer

These scripts are provided as-is, as examples, and are not supported by Everpure. See the
header of each script for the full text. This is in addition to, not instead of, the warranty
disclaimer in sections 7 and 8 of the license.
