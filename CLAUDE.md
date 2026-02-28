# Galera

Percona XtraDB Cluster 5.7 three-node development environment via Docker Compose, mirroring production.

## Critical Rules

- **GAL001**: All cluster operations go through `Makefile` — run `make help` for all commands.
- **GAL002**: Node 1 is the bootstrap node — always start with `make start`.
- **GAL003**: After any topology change, verify all nodes: `wsrep_cluster_status=Primary`, `wsrep_cluster_size=3`, `wsrep_local_state_comment=Synced`, `wsrep_ready=ON`.
- **GAL004**: Use logical backups (mydumper) for most use cases. XtraBackup is for full cluster recovery only.

## Quick Start

```bash
make start            # Initialize and start 3-node cluster
make stop             # Stop cluster
make status           # Check cluster health (all nodes)
make shell-node1      # MySQL shell on node 1 (port 3306)
make shell-node2      # MySQL shell on node 2 (port 3307)
make shell-node3      # MySQL shell on node 3 (port 3308)
make logs             # View all node logs
make ps               # Show running containers
```

Connect from host: `mysql -h127.0.0.1 -P3306 -uroot -prootpass` (ports 3306/3307/3308).

## Backups

```bash
make backup                              # Logical backup (mydumper) — recommended
make backup DATABASE=mydb THREADS=8      # Specific database, parallel
make restore BACKUP=mydumper_mydb_...    # Restore logical backup
make list-backups                        # List all backups
make backup-cluster                      # Physical backup (XtraBackup)
```

See [GALERA_BACKUP_RESTORE.md](./GALERA_BACKUP_RESTORE.md) for detailed backup/restore procedures.

## Monitoring

PMM at `https://localhost:8443` (admin/admin — change after first login).

```bash
make pmm-setup    # Register nodes (run after first start)
make pmm-status   # Health check
make pmm-open     # Open web UI
```

## Architecture

- PXC 5.7 with Galera 3, `xtrabackup-v2` SST
- All MySQL/Galera config centralized in `config/pxc.cnf` — compose.yaml only sets node-specific params
- Strict mode `ENFORCING`, GTID enabled, query cache disabled
- InnoDB buffer pool: 3GB (production: 12.5GB)
- Sequential startup: node2 waits for node1, node3 waits for node2 (~60s)

## Credentials (dev only)

| Service | User | Password |
|---------|------|----------|
| MySQL | root | rootpass |
| XtraBackup | — | xtrabackuppass |
| PMM | admin | admin |

## Boundaries

**NEVER:**
- Trust a node where `wsrep_cluster_status` is not "Primary"
- Modify `config/pxc.cnf` without understanding Galera replication implications

**ASK FIRST:**
- Changes to cluster topology (adding/removing nodes)
- Production configuration changes (buffer pool, gcache, strict mode)
- XtraBackup restore (requires stopping all nodes)
