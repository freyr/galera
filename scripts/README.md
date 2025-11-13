# Scripts Directory

This directory contains shell scripts for managing Percona XtraDB Cluster operations.

## Available Scripts

### backup.sh
**Purpose:** Create logical backup of a database using mydumper

**Usage:**
```bash
./scripts/backup.sh [database_name] [options]
```

**Environment Variables:**
- `MYSQL_HOST` - MySQL host (default: 127.0.0.1)
- `MYSQL_PORT` - MySQL port (default: 3306)
- `MYSQL_USER` - MySQL user (default: root)
- `MYSQL_PASSWORD` - MySQL password (default: rootpass)
- `BACKUP_DIR` - Backup directory (default: ./backups)

**Options:**
- `--host=HOST` - Override MySQL host
- `--port=PORT` - Override MySQL port
- `--threads=N` - Number of parallel threads (default: 4)
- `--compress` - Enable compression
- `--chunk-size=N` - Chunk size in MB (default: 100)

**Example:**
```bash
export MYSQL_HOST=10.0.0.10
./scripts/backup.sh employees --threads=8 --compress
```

**Output:** Creates backup in `./backups/mydumper_<database>_YYYYMMDD_HHMMSS/`

**Features:**
- Portable logical backups (can restore to any cluster)
- Galera cluster health checks
- Multi-threaded for performance
- Automatic mydumper installation check

---

### restore.sh
**Purpose:** Restore logical backup using myloader with Galera awareness

**Usage:**
```bash
./scripts/restore.sh <backup_directory> [database_name] [options]
```

**Environment Variables:**
- `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`
- `GALERA_NODES` - Comma-separated list for verification (e.g., "node1:3306,node2:3306,node3:3306")

**Options:**
- `--threads=N` - Number of parallel threads (default: 4)
- `--overwrite` - Drop existing tables before restore
- `--no-verify` - Skip post-restore verification

**Example:**
```bash
export GALERA_NODES="10.0.0.10:3306,10.0.0.11:3306,10.0.0.12:3306"
./scripts/restore.sh mydumper_employees_20250113_120000 --overwrite
```

**Features:**
- Uses `--enable-binlog` for Galera replication
- Pre-restore cluster health checks
- Post-restore verification across all nodes
- Flow control monitoring

---

### backup-cluster.sh
**Purpose:** Create physical backup of entire cluster using XtraBackup

**Usage:**
```bash
./scripts/backup-cluster.sh [database_name]
```

**Note:** This is for full cluster recovery scenarios only. For single database backup, use `backup.sh`.

**Output:** Creates backup in `./backups/xtrabackup_YYYYMMDD_HHMMSS/`

---

### restore-cluster.sh
**Purpose:** Restore physical cluster backup (manual process)

**Usage:**
```bash
./scripts/restore-cluster.sh <backup_directory>
```

**IMPORTANT:** This provides instructions for manual cluster recovery. All nodes must be stopped before restore.

---

### status.sh
**Purpose:** Display detailed cluster status for all nodes

**Usage:**
```bash
./scripts/status.sh
```

**Output:** Shows Galera cluster metrics including:
- `wsrep_cluster_status` - Should be "Primary"
- `wsrep_cluster_size` - Should be "3"
- `wsrep_local_state_comment` - Should be "Synced"
- `wsrep_ready` - Should be "ON"
- Flow control metrics
- Replication queue statistics
- Certification dependency distance

**Features:**
- Checks all 3 nodes in sequence
- Color-coded output
- Shows expected values for quick comparison

---

### pmm-setup.sh
**Purpose:** Register all cluster nodes with PMM (Percona Monitoring and Management)

**Usage:**
```bash
./scripts/pmm-setup.sh
```

**Features:**
- Configures PMM agent on each node
- Registers MySQL service with PMM server
- Sets up Query Analytics

---

## Using Scripts via Makefile (Docker Environment)

**The recommended way to run these scripts in Docker environment:**

```bash
# Backup/Restore (uses backup-tools container)
make backup                          # Runs backup.sh in tools container
make backup DATABASE=mydb THREADS=8  # With options
make restore BACKUP=<backup_name>    # Runs restore.sh in tools container

# Cluster operations
make status                          # Runs status.sh
make backup-cluster                  # Physical cluster backup
```

See `make help` for all available commands.

## Direct Usage (Production Servers)

On production servers, run scripts directly:

```bash
# Backup
export MYSQL_HOST=prod-db-01
export MYSQL_PASSWORD=$(cat /secure/mysql.pwd)
./scripts/backup.sh production_db --threads=8

# Restore
export GALERA_NODES="node1:3306,node2:3306,node3:3306"
./scripts/restore.sh mydumper_production_db_20250113_120000 --overwrite

# Status
./scripts/status.sh
```

## Documentation

- **PRODUCTION_USAGE.md** - Complete guide for production usage
- **GALERA_BACKUP_RESTORE.md** - Docker environment usage
- **CLAUDE.md** - Full project documentation
