# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Percona XtraDB Cluster (PXC) 5.7 development/testing environment using Docker Compose. It sets up a 3-node Galera cluster for high-availability MySQL testing and development that mirrors the production environment.

## Architecture

The cluster consists of:
- **pxc-node1** (bootstrap node): Port 3306
- **pxc-node2**: Port 3307
- **pxc-node3**: Port 3308

All nodes communicate using Docker Compose's internal DNS (hostname-based networking).

All nodes use:
- Percona XtraDB Cluster 5.7 (matching production)
- Galera 3 replication with `xtrabackup-v2` for State Snapshot Transfer (SST)
- Shared configuration in `config/pxc.cnf`
- Persistent volumes for data
- Shared backup directory at `./backups`

### Key Galera Configuration
- Cluster name: `pxc-cluster`
- SST method: `xtrabackup-v2`
- Strict mode: `PERMISSIVE` (PXC 5.7 default for compatibility)
- Binary log format: `ROW` (required for Galera)
- InnoDB auto-increment lock mode: `2` (required for Galera)
- Gcache size: 512M
- Query cache: Disabled (improves Galera performance)
- Galera library: `/usr/lib64/galera3/libgalera_smm.so` (auto-detected)

## Common Commands

**All cluster operations are managed through the Makefile.** Run `make help` to see all available commands.

### Cluster Management

Initialize and start the cluster (recommended for first run):
```bash
make start
```

This automatically:
- Creates necessary directories (config, backups, data)
- Verifies configuration file exists
- Starts all three nodes
- Waits for cluster initialization
- Shows connection information

**Note:** The cluster uses the existing `config/pxc.cnf` file. Make sure it exists before starting.

Stop the cluster:
```bash
make stop
```

Restart the cluster:
```bash
make restart
```

Remove containers (keeps data):
```bash
make clean
```

Destroy cluster and all data (WARNING: destructive):
```bash
make destroy
```

### Database Connections

Open MySQL shell on specific nodes:
```bash
make shell-node1  # Node 1 on port 3306
make shell-node2  # Node 2 on port 3307
make shell-node3  # Node 3 on port 3308
```

Connect from host machine:
```bash
# Node 1 (primary)
mysql -h127.0.0.1 -P3306 -uroot -prootpass

# Node 2
mysql -h127.0.0.1 -P3307 -uroot -prootpass

# Node 3
mysql -h127.0.0.1 -P3308 -uroot -prootpass
```

Execute bash in a container:
```bash
make exec-node1  # or exec-node2, exec-node3
```

### Cluster Status Monitoring

Check cluster health (shows status for all 3 nodes):
```bash
make status
# or
make check-cluster
```

View logs:
```bash
make logs          # All nodes
make logs-node1    # Specific node
make logs-node2
make logs-node3
```

Show running containers:
```bash
make ps
```

Key metrics to monitor:
- `wsrep_cluster_status`: Should be "Primary"
- `wsrep_cluster_size`: Should be "3"
- `wsrep_local_state_comment`: Should be "Synced"
- `wsrep_ready`: Should be "ON"

### Backups

Create an XtraBackup of a database:
```bash
make backup                    # Backs up 'employees' database by default
make backup DATABASE=mydb      # Backup specific database
```

Backups are stored in `./backups/xtrabackup_YYYYMMDD_HHMMSS/` with both backup and prepare logs included.

### Test Data

Load the test employees database:
```bash
make load-test-db
```

This automatically:
- Downloads the MySQL test_db (employees) dataset if not present
- Imports it into node 1 (automatically replicates to all nodes)
- The dataset contains ~300k records across 6 tables

## Makefile Targets

Run `make help` to see all available commands. Key targets:

| Target | Description |
|--------|-------------|
| `make help` | Show all available commands |
| `make setup` | Initialize directories and configuration |
| `make start` | Start the cluster (includes setup) |
| `make stop` | Stop the cluster |
| `make status` | Show detailed cluster status |
| `make backup` | Create XtraBackup (use `DATABASE=name`) |
| `make load-test-db` | Load test employees database |
| `make shell-node1` | Open MySQL shell on node 1 |
| `make logs` | Show logs from all nodes |
| `make clean` | Remove containers (keeps data) |
| `make destroy` | Remove everything including data |

## Version-Specific Notes

### PXC 5.7 Considerations
- Uses Galera 3 (vs Galera 4 in PXC 8.0)
- `pxc_strict_mode=PERMISSIVE` allows more flexibility for legacy applications
- Query cache is disabled (`query_cache_size=0`, `query_cache_type=0`) for better performance
- SST method `xtrabackup-v2` is the recommended backup method for 5.7
- Compatible with MySQL 5.7 applications and clients

## Important Notes

### Cluster Bootstrap
- Node 1 is the bootstrap node (`--wsrep_cluster_address=gcomm://`)
- Nodes 2 and 3 join the cluster via node 1
- Healthchecks use `mysql -e "SELECT 1"` to verify node readiness
- Sequential startup: node2 waits for node1, node3 waits for node2
- Initial cluster formation takes ~60 seconds

### Split-Brain Prevention
- The 3-node configuration provides quorum (requires majority for writes)
- If a node becomes isolated, it will not accept writes
- Always check `wsrep_cluster_status` is "Primary" before trusting a node

### State Snapshot Transfer (SST)
- Uses `xtrabackup-v2` for full backups during node joining
- Requires `XTRABACKUP_PASSWORD` to be set
- SST is triggered automatically when a node joins the cluster

### Data Persistence
- Each node has its own volume: `pxc-node1-data`, `pxc-node2-data`, `pxc-node3-data`
- Backups are mounted at `/backups` in containers
- Configuration is in `config/pxc.cnf` and mounted read-only

## Credentials

- MySQL root password: `rootpass`
- XtraBackup password: `xtrabackuppass`
- These are for development/testing only

## Network Configuration

- Uses Docker Compose bridge network with automatic DNS
- Nodes communicate via hostnames (pxc-node1, pxc-node2, pxc-node3)
- No static IPs required - Docker DNS handles name resolution
- Galera ports:
  - 3306: MySQL client connections
  - 4567: Galera cluster replication
  - 4568: Incremental State Transfer (IST)
