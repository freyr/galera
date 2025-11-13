# Scripts Directory

This directory contains shell scripts used by the Makefile to perform various cluster operations.

## Scripts

### backup.sh
**Purpose:** Create XtraBackup of a specified database

**Usage:**
```bash
./scripts/backup.sh [database_name]
```

**Default:** `employees` database if no argument provided

**Example:**
```bash
./scripts/backup.sh mysql
```

**Output:** Creates backup in `./backups/xtrabackup_YYYYMMDD_HHMMSS/`

**Features:**
- Full XtraBackup with prepare step
- Color-coded output
- Timestamped backup directories
- Logs backup and prepare operations

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

## Using Scripts via Makefile

**The recommended way to run these scripts is through the Makefile:**

```bash
make status              # Runs status.sh
make backup              # Runs backup.sh with default database
make backup DATABASE=foo # Runs backup.sh with specified database
```

See `make help` for all available commands.

## Direct Usage

While you can run scripts directly, using the Makefile is preferred:

```bash
# Direct usage (works but not recommended)
./scripts/status.sh
./scripts/backup.sh employees

# Preferred (via Makefile)
make status
make backup DATABASE=employees
```
