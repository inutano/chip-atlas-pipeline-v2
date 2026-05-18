# NIG-specific scripts

Scripts in this directory hardcode paths and SLURM partition/account values
specific to the NIG kumamoto cluster:

- `kumamoto-c768` partition, `kumamoto-group` account
- `/lustre10/home/inutano-chiba/shared/chip-atlas-pipeline-v2/` for containers + references
- `/data1/tmp/` for node-local NVMe scratch
- `/home/okishinya/chipatlas-v2/` for final outputs (collaborator dir, group quota)
- `~/chip-atlas-v2/scripts/` as the on-host scripts dir

Scripts here:

| Script | Role |
|---|---|
| `submit-sacCer3.sh` | SLURM array submit for ChIP + BS sacCer3 (template for other small genomes) |
| `submit-separated.sh` | Submit separated download/process pair (for larger genomes) |
| `run-sample.sh` | Per-sample wrapper invoked by the array model: download → dispatch pipeline |
| `production-process.sh` | Long-running processor that polls a staging dir and dispatches the pipeline (separated model) |

## Deployment

The on-host layout is **flat** — all scripts (general + NIG) deploy into a
single `~/chip-atlas-v2/scripts/` directory. The `SCRIPTS=~/chip-atlas-v2/scripts`
references inside the NIG scripts assume sibling layout.

To deploy, copy both general and NIG scripts into the flat host dir:

```bash
scp scripts/*.sh nig:~/chip-atlas-v2/scripts/
scp scripts/nig/*.sh nig:~/chip-atlas-v2/scripts/
```

(or the equivalent via rsync / git pull on the host.)
