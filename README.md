# Modern-Data-Protection-Veeam

Veeam Backup & Replication automation and orchestration scripts for Everpure storage systems.

## Contents

| | Purpose |
| --- | --- |
| [flasharray-veeam-nas-snapshots/](flasharray-veeam-nas-snapshots/) | **FlashArray File backup from snapshot** for Veeam NAS backup jobs. Pre/post job scripts that point a Veeam file share at a Managed Directory snapshot, for SMB shares and NFS exports. Self-contained — copy the folder to the Veeam server. |
| [fb-file-veeam-snapshot-pre-backup-script-example.ps1](fb-file-veeam-snapshot-pre-backup-script-example.ps1) | FlashBlade//File equivalent of the above, as a single-file example. |
| [fb-file-veeam-snapshot-post-backup-script-example.ps1](fb-file-veeam-snapshot-post-backup-script-example.ps1) | Destroys the snapshots created by the FlashBlade//File pre-backup example. |
| [veeam-fb-multi-obj-account-setup.ps1](veeam-fb-multi-obj-account-setup.ps1) | Wires multiple FlashBlade//S3 buckets into Veeam as object storage repositories. |

The `fb-*` scripts and `veeam-fb-multi-obj-account-setup.ps1` take their settings and credentials
inline, so each copy serves one share. They have not been reworked; the shared module in
[flasharray-veeam-nas-snapshots/](flasharray-veeam-nas-snapshots/) was written to be reusable for
that.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Copyright 2026 Everpure, Inc.

## Disclaimer

These scripts are provided as-is, as examples, and are not supported by Everpure. See the
header of each script for the full text. This is in addition to, not instead of, the warranty
disclaimer in sections 7 and 8 of the license.
