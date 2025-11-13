# Galera Cluster Backup & Restore Guide

## Overview

This document explains the two backup strategies available for the Percona XtraDB Cluster and when to use each.

## Backup Methods Comparison

| Feature | XtraBackup (Physical) | MyDumper (Logical) |
|---------|----------------------|-------------------|
| **Type** | Physical file copy | Logical SQL dump |
| **Speed** | Faster backup | Slower backup, faster restore |
| **Portability** | Same cluster/version only | Cross-cluster, cross-version |
| **Single DB** | Possible but limited | Excellent support |
| **Compression** | Good | Excellent |
| **Use Case** | Full cluster recovery | Single DB migration/restore |
| **Galera-Aware** | Yes (SST method) | Requires special handling |

## Recommended Approach: Logical Backups (MyDumper/MyLoader)

For **single database backup and restore to different clusters**, use the logical backup method with MyDumper/MyLoader.

### Why Logical Backups?

1. **Portability**: Can restore to any Galera cluster, even with different configurations
2. **Selective Restore**: Easy to restore specific databases or tables
3. **Version Independence**: Works across different MySQL/PXC versions
4. **Cluster-Agnostic**: Not tied to specific cluster GTID state or system tables

---

## Logical Backup & Restore Operations

### Creating a Logical Backup

**Basic Usage:**
```bash
make backup
```

This creates a backup of the default `employees` database.

**Backup a Specific Database:**
```bash
make backup DATABASE=mydb
```

**Advanced Options:**
```bash
# Use more threads for faster backup
make backup DATABASE=mydb THREADS=8

# With compression (via script flag)
./scripts/backup.sh mydb --compress

# Specify chunk size for large tables
./scripts/backup.sh mydb --chunk-size=200
```

**What Happens During Backup:**

1. ✅ Cluster health check (ensures cluster is in Primary state and Synced)
2. ✅ Verifies database exists
3. ✅ Auto-installs mydumper if not present
4. ✅ Creates timestamped backup directory: `/backups/mydumper_<database>_<timestamp>/`
5. ✅ Backs up:
   - All table data (split into chunks for large tables)
   - Triggers
   - Events
   - Stored procedures/functions
   - Table schemas
6. ✅ Generates metadata file with cluster state information

**Backup Location:**
```
./backups/mydumper_<database>_YYYYMMDD_HHMMSS/
├── metadata                  # MyDumper metadata
├── backup_metadata.txt       # Cluster state at backup time
├── backup.log               # Backup operation log
├── <database>-schema-create.sql
├── <table>-schema.sql       # Table schemas
├── <table>.00000.sql        # Table data (chunked)
└── ...
```

---

### Restoring a Logical Backup

**List Available Backups:**
```bash
make list-backups
```

**Basic Restore:**
```bash
make restore BACKUP=mydumper_employees_20250113_120000
```

**Restore to a Different Database Name:**
```bash
make restore BACKUP=mydumper_employees_20250113_120000 DATABASE=new_db_name
```

**Advanced Options:**
```bash
# Use more threads for faster restore
make restore BACKUP=mydumper_employees_20250113_120000 THREADS=8

# Overwrite existing tables
./scripts/restore.sh mydumper_employees_20250113_120000 --overwrite

# Restore to a different node
./scripts/restore.sh mydumper_employees_20250113_120000 --node=pxc-node2
```

---

## Galera-Specific Considerations for Restore

### How Restore Works with Galera

The restore process is **Galera-aware** and handles cluster replication automatically:

```
┌─────────────────────────────────────────────────────┐
│  Restore Process Flow                              │
├─────────────────────────────────────────────────────┤
│                                                     │
│  1. Pre-Restore Health Check                       │
│     ✓ Verify all nodes are in "Primary" state     │
│     ✓ Verify all nodes are "Synced"               │
│     ✓ Check cluster size (should be 3)            │
│                                                     │
│  2. Restore to Single Node (pxc-node1)             │
│     → MyLoader runs with --enable-binlog flag      │
│     → Data loads into node1 only                   │
│     → Transactions written to binlog               │
│                                                     │
│  3. Galera Automatic Replication                   │
│     → Galera wsrep replicates changes to nodes 2&3│
│     → Certification and apply on all nodes         │
│     → Flow control manages replication speed       │
│                                                     │
│  4. Post-Restore Verification                      │
│     ✓ Verify database exists on all nodes         │
│     ✓ Compare table counts across nodes           │
│     ✓ Sample row counts to verify data sync       │
│     ✓ Check flow control status                   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Critical: The --enable-binlog Flag

**Why It's Essential:**

In Percona XtraDB Cluster, when `sql_log_bin = 0` (MyLoader's default), it also disables **wsrep replication**. This means:

❌ Without `--enable-binlog`: Data loads on one node only, no replication
✅ With `--enable-binlog`: Data replicates automatically to all cluster nodes

Our restore script **automatically uses `--enable-binlog`** to ensure proper replication.

### Performance Impact: Flow Control

During large data loads, you may observe **Galera Flow Control**:

- **What it is**: Galera's mechanism to prevent slow nodes from falling too far behind
- **Impact**: The entire cluster may slow down temporarily during restore
- **Monitoring**: Check `wsrep_flow_control_paused` status variable
- **Normal behavior**: Flow control should return to near-zero after restore completes

**Flow Control Example:**
```sql
-- On any node during restore:
SHOW STATUS LIKE 'wsrep_flow_control_paused';

-- Good: 0.0 to 0.1 (0-10% paused)
-- Warning: 0.1 to 0.5 (10-50% paused)
-- Issue: > 0.5 (>50% paused) - may indicate undersized cluster
```

### Verification Process

The restore script automatically verifies replication:

1. **Database Existence**: Checks all 3 nodes have the database
2. **Table Count**: Compares table count across nodes
3. **Row Count Sampling**: Samples 3 tables and compares row counts
4. **Cluster State**: Verifies all nodes remain "Synced"

---

## Best Practices

### For Backups

1. **Backup from a Healthy Cluster**: Always verify cluster is in "Primary" state
2. **Use Adequate Threads**: More threads = faster backup (try 4-8 threads)
3. **Enable Compression**: For large databases, use `--compress` flag
4. **Regular Backups**: Schedule backups during low-traffic periods
5. **Test Restores**: Periodically test restore process to ensure backups are valid

### For Restores

1. **Verify Cluster Health First**: Ensure all nodes are synced before restore
2. **Use Single Node**: Let Galera handle replication (don't load on multiple nodes)
3. **Monitor Flow Control**: Large restores will trigger flow control temporarily
4. **Plan for Downtime**: While cluster stays online, performance may degrade during large restores
5. **Verify After Restore**: Always run verification to ensure data replicated correctly

### For Production

1. **Test in Staging**: Test backup/restore process in non-production first
2. **Monitor Cluster**: Keep an eye on PMM dashboards during restore
3. **Consider wsrep_on=OFF for Massive Loads**: For very large databases (100GB+), consider:
   ```sql
   SET SESSION wsrep_on=OFF;  -- Disable replication during load
   -- Load data --
   -- Then trigger IST/SST to sync other nodes
   ```
   This is advanced and requires manual node synchronization.

---

## Troubleshooting

### Issue: Restore Completes but Data Not on Other Nodes

**Cause**: MyLoader ran without `--enable-binlog`

**Solution**: Our script includes this flag automatically. If running myloader manually:
```bash
myloader --directory=/backups/mybackup --enable-binlog ...
```

### Issue: High Flow Control During Restore

**Symptoms**:
- Cluster becomes slow
- `wsrep_flow_control_paused` > 0.3

**Solutions**:
1. Reduce `--threads` parameter (less parallel loading)
2. Load during off-peak hours
3. For very large datasets, consider loading with `wsrep_on=OFF` and manually syncing

### Issue: Tables Missing After Restore

**Check**:
1. Verify backup completed successfully (check backup.log)
2. Check myloader restore log: `./backups/<backup>/restore_logs/restore_*.log`
3. Look for errors in MySQL error logs: `make logs-node1`

### Issue: "Cluster not in Primary state"

**Cause**: Split-brain or node failure

**Solution**:
1. Check cluster status: `make status`
2. Ensure all 3 nodes are running: `docker compose ps`
3. Check for network issues between nodes
4. Review Galera status: `SHOW STATUS LIKE 'wsrep_%';`

---

## Migration Example: Database from Production to Dev Cluster

**Scenario**: Backup `orders` database from production, restore to development cluster

```bash
# On Production Cluster
make backup DATABASE=orders
# Creates: ./backups/mydumper_orders_20250113_143000/

# Copy backup to development cluster
scp -r ./backups/mydumper_orders_20250113_143000/ dev-server:/path/to/galera/backups/

# On Development Cluster
make list-backups  # Verify backup is present
make restore BACKUP=mydumper_orders_20250113_143000

# Verification
make shell-node1
mysql> USE orders;
mysql> SELECT COUNT(*) FROM orders;  -- Verify data
mysql> \q
```

---

## Comparison with XtraBackup

### When to Use XtraBackup

- Full cluster disaster recovery
- Provisioning new nodes (SST method)
- Need fastest possible backup
- Restoring to identical cluster configuration

### When to Use MyDumper/MyLoader

- ✅ Single database backup/restore (your use case)
- ✅ Cross-cluster migrations
- ✅ Selective table backup/restore
- ✅ Testing data in different environments
- ✅ MySQL version upgrades

---

## Quick Reference

### Commands

```bash
# Backup
make backup                         # Backup 'employees' db
make backup DATABASE=mydb           # Backup specific db
make backup DATABASE=mydb THREADS=8 # Faster backup

# List Backups
make list-backups

# Restore
make restore BACKUP=mydumper_mydb_20250113_120000
make restore BACKUP=mydumper_mydb_20250113_120000 DATABASE=newname
make restore BACKUP=mydumper_mydb_20250113_120000 THREADS=8

# Monitoring
make status                  # Cluster health
make pmm-open               # PMM dashboard
```

### Key MyLoader Flags (Automatic in Script)

- `--enable-binlog`: **CRITICAL** - Enables Galera replication
- `--threads`: Parallel loading threads
- `--overwrite-tables`: Drop existing tables before restore
- `--verbose`: Detailed output

### Key Galera Status Variables

```sql
-- Check cluster health
SHOW STATUS LIKE 'wsrep_cluster_status';      -- Should be "Primary"
SHOW STATUS LIKE 'wsrep_local_state_comment'; -- Should be "Synced"
SHOW STATUS LIKE 'wsrep_cluster_size';        -- Should be "3"

-- Monitor flow control during restore
SHOW STATUS LIKE 'wsrep_flow_control_paused'; -- Should be < 0.1
```

---

## Summary

The new **logical backup/restore system** using MyDumper/MyLoader provides:

✅ **Portability**: Restore single databases to any cluster
✅ **Galera-Aware**: Automatic replication with `--enable-binlog`
✅ **Verification**: Post-restore checks ensure data integrity
✅ **Flexibility**: Restore to different database names or clusters
✅ **Production-Ready**: Handles flow control and cluster health checks

This solves the limitation of XtraBackup for single-database cross-cluster restores while maintaining full Galera cluster compatibility.
