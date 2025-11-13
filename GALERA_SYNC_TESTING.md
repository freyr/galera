# Galera Cluster Data Sync Testing Scenarios

## Problem Statement

When refreshing the release cluster using a dump created from production cluster with mydumper/myloader tools (dumping only one database), some data is not syncing to other nodes in the Galera cluster.

**Environment:**
- Production: Percona XtraDB Cluster 5.7
- Release: Percona XtraDB Cluster 5.7 (3 nodes)
- Tools: mydumper/myloader for backup and restore
- Scope: Single database dump/restore

---

## Root Cause Analysis Framework

### Known Galera Replication Limitations

1. **Storage Engine Requirements**
   - Only InnoDB storage engine replicates in Galera
   - MyISAM, MEMORY, CSV, and other engines do NOT replicate
   - DDL on non-InnoDB tables completes locally but data changes don't sync

2. **Transaction Size Limits**
   - Default `wsrep_max_ws_size`: 2GB
   - Large LOAD DATA or bulk inserts may exceed limits
   - Parallel loading can create oversized transactions

3. **Binary Logging Requirements**
   - Galera requires binary logging to be enabled
   - Session-level `SET sql_log_bin=0` bypasses replication
   - Some restore tools may disable binlog for performance

4. **wsrep Session Variables**
   - `SET wsrep_on=OFF` disables replication for the session
   - Some tools may use this for performance during restore
   - Data loaded with wsrep_on=OFF won't replicate

5. **Primary Key Requirements**
   - Tables without primary keys have poor replication performance
   - DELETE operations unsupported on tables without PK
   - Can cause certification conflicts

6. **Auto-increment Handling**
   - `wsrep_auto_increment_control=ON` adjusts auto_increment settings
   - Parallel loads may cause conflicts if disabled
   - Can result in duplicate key errors or gaps

7. **Foreign Key Constraints**
   - Parallel loading can cause certification failures
   - Load order matters for FK-related tables
   - May require --single-transaction or ordered loading

---

## Test Scenarios

### Scenario 1: MyISAM Storage Engine Tables

**Hypothesis:** Non-InnoDB tables in the dump don't replicate to other nodes.

**Test Setup:**
1. Create database with mixed storage engines:
   ```sql
   CREATE TABLE innodb_table (id INT PRIMARY KEY, data VARCHAR(100)) ENGINE=InnoDB;
   CREATE TABLE myisam_table (id INT PRIMARY KEY, data VARCHAR(100)) ENGINE=MyISAM;
   CREATE TABLE memory_table (id INT PRIMARY KEY, data VARCHAR(100)) ENGINE=MEMORY;
   ```

2. Insert data into all tables
3. Dump using mydumper from node1
4. Restore using myloader to fresh cluster on node1

**Expected Behavior:**
- InnoDB data replicates to all nodes
- MyISAM data stays on node1 only
- MEMORY table data doesn't persist or replicate

**Validation:**
```bash
# On each node
SELECT ENGINE, COUNT(*)
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='test_db'
GROUP BY ENGINE;

# Check row counts per node
SELECT COUNT(*) FROM innodb_table;  # Should be same on all nodes
SELECT COUNT(*) FROM myisam_table;  # May differ across nodes
```

**Metrics to Monitor:**
- None - this is a known limitation, not a replication failure

---

### Scenario 2: wsrep_on Session Variable

**Hypothesis:** myloader might set `wsrep_on=OFF` during import, bypassing replication.

**Test Setup:**
1. Create test database with InnoDB tables
2. Manually disable wsrep during load:
   ```bash
   mysql -e "SET wsrep_on=OFF; USE testdb; LOAD DATA..."
   ```
3. Compare with normal load

**Expected Behavior:**
- Data loaded with `wsrep_on=OFF` stays on local node only
- Other nodes don't receive the changes

**Validation:**
```sql
-- Check if data exists on each node
SELECT COUNT(*) FROM testdb.test_table;

-- Check wsrep status
SHOW VARIABLES LIKE 'wsrep_on';
SHOW STATUS LIKE 'wsrep_replicated';  # Should not increase
```

**Metrics to Monitor:**
- `wsrep_replicated`: Should NOT increase during load if wsrep_on=OFF
- `wsrep_local_commits`: Should increase locally
- `Com_insert`: Increases locally but not cluster-wide

**How to Detect:**
1. Monitor general log or binary log during restore
2. Check myloader source code for session variables
3. Use `SET GLOBAL general_log=ON` before restore
4. Search logs for `SET wsrep_on`

---

### Scenario 3: Large Transaction Size Limits

**Hypothesis:** Bulk loads exceed `wsrep_max_ws_size`, causing transaction rejection.

**Test Setup:**
1. Set relatively small wsrep_max_ws_size:
   ```sql
   SET GLOBAL wsrep_max_ws_size = 104857600;  -- 100MB
   ```

2. Create table with large rows:
   ```sql
   CREATE TABLE large_data (
       id INT PRIMARY KEY AUTO_INCREMENT,
       data LONGTEXT
   ) ENGINE=InnoDB;
   ```

3. Load large dataset that exceeds limit

**Expected Behavior:**
- Transaction fails with error: `wsrep_max_ws_size limit exceeded`
- Partial data may exist on local node
- Other nodes don't receive the data
- Error in logs: "transaction size limit"

**Validation:**
```sql
-- Check transaction size limit
SHOW VARIABLES LIKE 'wsrep_max_ws_size';

-- Check for violations in logs
-- Error log will show: "transaction size limit (2147483647) exceeded: 2147483648"

-- Check certification failures
SHOW STATUS LIKE 'wsrep_local_cert_failures';
```

**Metrics to Monitor:**
- `wsrep_local_cert_failures`: Increases on oversized transactions
- `wsrep_local_bf_aborts`: May increase
- Error log entries

---

### Scenario 4: Binary Logging Disabled

**Hypothesis:** Binary logging disabled during restore prevents replication.

**Test Setup:**
1. Check binary log status:
   ```sql
   SHOW VARIABLES LIKE 'log_bin';
   SHOW VARIABLES LIKE 'sql_log_bin';
   ```

2. Attempt load with binary logging disabled:
   ```sql
   SET sql_log_bin=0;
   LOAD DATA INFILE...
   ```

**Expected Behavior:**
- Changes made with `sql_log_bin=0` don't replicate
- Local node has data, other nodes don't
- No replication errors (changes intentionally not replicated)

**Validation:**
```sql
-- Check binary log configuration
SHOW VARIABLES LIKE 'log_bin%';
SHOW VARIABLES LIKE 'sql_log_bin';

-- Check if binary log is actually being written
SHOW BINARY LOGS;
SHOW MASTER STATUS;
```

**Metrics to Monitor:**
- `wsrep_replicated`: Won't increase for sql_log_bin=0 sessions
- Binary log position: Won't advance during disabled sessions

---

### Scenario 5: Tables Without Primary Keys

**Hypothesis:** Tables without PKs cause replication issues or poor performance.

**Test Setup:**
1. Create tables without primary keys:
   ```sql
   CREATE TABLE no_pk_table (
       id INT,
       data VARCHAR(100),
       timestamp DATETIME
   ) ENGINE=InnoDB;
   ```

2. Load large dataset
3. Monitor replication performance

**Expected Behavior:**
- Slower replication (full table scans for row identification)
- Possible certification conflicts
- DELETE operations may fail/timeout
- Higher `wsrep_cert_deps_distance`

**Validation:**
```sql
-- Find tables without primary keys
SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.ENGINE
FROM information_schema.TABLES t
LEFT JOIN information_schema.TABLE_CONSTRAINTS tc
    ON t.TABLE_SCHEMA = tc.TABLE_SCHEMA
    AND t.TABLE_NAME = tc.TABLE_NAME
    AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
WHERE t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema')
    AND tc.CONSTRAINT_NAME IS NULL
    AND t.TABLE_TYPE = 'BASE TABLE';
```

**Metrics to Monitor:**
- `wsrep_cert_deps_distance`: Higher values indicate conflicts
- `wsrep_local_cert_failures`: Certification failures
- `wsrep_flow_control_paused`: Flow control due to slow replication
- Replication lag between nodes

---

### Scenario 6: Parallel Loading with Foreign Keys

**Hypothesis:** Parallel loading violates FK constraints, causing certification failures.

**Test Setup:**
1. Create tables with FK relationships:
   ```sql
   CREATE TABLE parent (
       id INT PRIMARY KEY,
       data VARCHAR(100)
   ) ENGINE=InnoDB;

   CREATE TABLE child (
       id INT PRIMARY KEY,
       parent_id INT,
       data VARCHAR(100),
       FOREIGN KEY (parent_id) REFERENCES parent(id)
   ) ENGINE=InnoDB;
   ```

2. Use myloader with multiple threads (--threads=4)
3. Load parent and child data simultaneously

**Expected Behavior:**
- FK constraint violations during parallel load
- Certification failures: child rows loaded before parent
- Transaction rollbacks
- Partial data on node1, inconsistent on other nodes

**Validation:**
```sql
-- Check FK constraints
SELECT
    TABLE_NAME,
    CONSTRAINT_NAME,
    REFERENCED_TABLE_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_SCHEMA = 'your_database'
    AND REFERENCED_TABLE_NAME IS NOT NULL;

-- Check for orphaned records (FK violations)
SELECT c.*
FROM child c
LEFT JOIN parent p ON c.parent_id = p.id
WHERE p.id IS NULL;

-- Compare counts across nodes
SELECT 'parent' as tbl, COUNT(*) FROM parent
UNION ALL
SELECT 'child', COUNT(*) FROM child;
```

**Metrics to Monitor:**
- `wsrep_local_cert_failures`: Increases during FK violations
- `wsrep_local_bf_aborts`: Transactions aborted due to conflicts
- Error log: "Foreign key constraint fails"

---

### Scenario 7: Auto-increment Conflicts

**Hypothesis:** Parallel loading with AUTO_INCREMENT causes duplicate key errors.

**Test Setup:**
1. Create table with auto-increment:
   ```sql
   CREATE TABLE auto_inc_test (
       id INT PRIMARY KEY AUTO_INCREMENT,
       data VARCHAR(100)
   ) ENGINE=InnoDB;
   ```

2. Check wsrep auto-increment settings:
   ```sql
   SHOW VARIABLES LIKE 'wsrep_auto_increment_control';
   SHOW VARIABLES LIKE 'auto_increment_increment';
   SHOW VARIABLES LIKE 'auto_increment_offset';
   ```

3. Load data with myloader using multiple threads

**Expected Behavior (if wsrep_auto_increment_control=OFF):**
- Duplicate key errors across nodes
- Some inserts succeed locally, fail on other nodes
- Certification failures

**Expected Behavior (if wsrep_auto_increment_control=ON):**
- Should work correctly (auto_increment_increment set to cluster size)
- No conflicts

**Validation:**
```sql
-- Check configuration
SHOW VARIABLES LIKE 'wsrep_auto_increment_control';
SHOW VARIABLES LIKE 'auto_increment_%';

-- Look for gaps or duplicates in ID sequence
SELECT id, COUNT(*)
FROM auto_inc_test
GROUP BY id
HAVING COUNT(*) > 1;

-- Check for missing IDs
SELECT id + 1 as missing_id
FROM auto_inc_test t1
WHERE NOT EXISTS (
    SELECT 1 FROM auto_inc_test t2
    WHERE t2.id = t1.id + 1
) AND id < (SELECT MAX(id) FROM auto_inc_test);
```

**Metrics to Monitor:**
- `wsrep_local_cert_failures`: Duplicate key errors
- `Innodb_rows_inserted`: Compare across nodes
- Error log: "Duplicate entry"

---

### Scenario 8: max_allowed_packet Mismatch

**Hypothesis:** Packet size limits differ between dump and restore environments.

**Test Setup:**
1. Create dump on production with large max_allowed_packet:
   ```sql
   -- Production setting
   SET GLOBAL max_allowed_packet = 1073741824;  -- 1GB
   ```

2. Attempt restore on release with smaller setting:
   ```sql
   -- Release setting
   SET GLOBAL max_allowed_packet = 67108864;  -- 64MB
   ```

**Expected Behavior:**
- Large INSERT statements fail
- Error: "Got a packet bigger than 'max_allowed_packet' bytes"
- Incomplete data load
- Transaction rollback

**Validation:**
```sql
-- Check current setting
SHOW VARIABLES LIKE 'max_allowed_packet';

-- Check for large rows/BLOBs
SELECT
    TABLE_NAME,
    ROUND(DATA_LENGTH / 1024 / 1024, 2) as data_mb,
    ROUND(AVG_ROW_LENGTH / 1024, 2) as avg_row_kb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'your_database'
ORDER BY DATA_LENGTH DESC;
```

**Metrics to Monitor:**
- Error log: "packet bigger than max_allowed_packet"
- `Aborted_clients`: May increase
- Connection errors

---

## Testing Procedure

### Prerequisites

1. **Install mydumper/myloader:**
   ```bash
   # On host machine or in container
   apt-get update
   apt-get install -y mydumper
   # Or download from: https://github.com/mydumper/mydumper
   ```

2. **Prepare monitoring:**
   ```bash
   # Enable general log temporarily for debugging
   docker compose exec pxc-node1 mysql -uroot -prootpass -e "
   SET GLOBAL general_log = ON;
   SET GLOBAL general_log_file = '/var/lib/mysql/general.log';
   "
   ```

3. **Baseline metrics:**
   ```bash
   ./scripts/status.sh > baseline_status.txt
   ```

### Step-by-Step Testing

**Phase 1: Create "Production" Database**
```bash
# Connect to node1
make shell-node1

# Run test scenario setup SQL
SOURCE /path/to/test_scenario_setup.sql
```

**Phase 2: Create Dump**
```bash
# Dump from node1 (simulating production)
docker compose exec pxc-node1 mydumper \
    --database=your_database \
    --outputdir=/backups/mydump_test \
    --rows=50000 \
    --compress \
    --build-empty-files \
    --threads=4 \
    --verbose=3
```

**Phase 3: Prepare "Release" Cluster**
```bash
# Drop database on all nodes (simulating fresh release environment)
for node in pxc-node1 pxc-node2 pxc-node3; do
    docker compose exec -T $node mysql -uroot -prootpass -e "
    DROP DATABASE IF EXISTS your_database;
    "
done

# Verify database is gone on all nodes
./scripts/status.sh
```

**Phase 4: Restore on Node1 Only**
```bash
# Start monitoring in separate terminal
watch -n 1 './scripts/status.sh'

# Restore using myloader on node1
docker compose exec pxc-node1 myloader \
    --directory=/backups/mydump_test \
    --database=your_database \
    --threads=4 \
    --verbose=3 \
    --overwrite-tables

# Monitor progress
docker compose exec pxc-node1 mysql -uroot -prootpass -e "
SHOW PROCESSLIST;
"
```

**Phase 5: Validation**
```bash
# Wait for replication to settle
sleep 30

# Check table counts on each node
for node in pxc-node1 pxc-node2 pxc-node3; do
    echo "=== $node ==="
    docker compose exec -T $node mysql -uroot -prootpass your_database -e "
    SELECT
        TABLE_NAME,
        TABLE_ROWS,
        ENGINE
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='your_database'
    ORDER BY TABLE_NAME;
    "
done

# Check for discrepancies
./scripts/validate_sync.sh
```

**Phase 6: Collect Diagnostics**
```bash
# Export wsrep status from all nodes
for node in pxc-node1 pxc-node2 pxc-node3; do
    docker compose exec -T $node mysql -uroot -prootpass -e "
    SHOW STATUS LIKE 'wsrep%';
    " > diagnostics_${node}.txt
done

# Check error logs
docker compose logs pxc-node1 > logs_node1.txt
docker compose logs pxc-node2 > logs_node2.txt
docker compose logs pxc-node3 > logs_node3.txt

# Check general log for session variables
docker compose exec pxc-node1 cat /var/lib/mysql/general.log | grep -E 'wsrep_on|sql_log_bin|SET' > general_log_analysis.txt
```

---

## Diagnostic Queries

### Check Storage Engines
```sql
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY TABLE_SCHEMA, ENGINE, TABLE_NAME;
```

### Check for Tables Without Primary Keys
```sql
SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.ENGINE,
    t.TABLE_ROWS
FROM information_schema.TABLES t
LEFT JOIN information_schema.TABLE_CONSTRAINTS tc
    ON t.TABLE_SCHEMA = tc.TABLE_SCHEMA
    AND t.TABLE_NAME = tc.TABLE_NAME
    AND tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
WHERE t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
    AND tc.CONSTRAINT_NAME IS NULL
    AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY t.TABLE_ROWS DESC;
```

### Check Foreign Key Relationships
```sql
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    CONSTRAINT_NAME,
    REFERENCED_TABLE_NAME,
    REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_SCHEMA = 'your_database'
    AND REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY TABLE_NAME;
```

### Check Galera Replication Status
```sql
-- Critical wsrep status variables
SHOW STATUS WHERE Variable_name IN (
    'wsrep_cluster_status',
    'wsrep_cluster_size',
    'wsrep_local_state_comment',
    'wsrep_ready',
    'wsrep_connected',
    'wsrep_local_commits',
    'wsrep_local_cert_failures',
    'wsrep_local_bf_aborts',
    'wsrep_replicated',
    'wsrep_received',
    'wsrep_flow_control_paused',
    'wsrep_cert_deps_distance'
);
```

### Check Configuration
```sql
-- Galera-related configuration
SHOW VARIABLES WHERE Variable_name IN (
    'wsrep_on',
    'wsrep_auto_increment_control',
    'wsrep_max_ws_size',
    'log_bin',
    'sql_log_bin',
    'max_allowed_packet',
    'binlog_format',
    'default_storage_engine'
);
```

### Compare Data Across Nodes
```sql
-- Run on each node and compare results
SELECT
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS,
    MD5(GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION)) as schema_hash
FROM information_schema.TABLES t
JOIN information_schema.COLUMNS c USING (TABLE_SCHEMA, TABLE_NAME)
WHERE TABLE_SCHEMA = 'your_database'
GROUP BY TABLE_NAME, ENGINE, TABLE_ROWS
ORDER BY TABLE_NAME;
```

---

## Expected Findings & Solutions

### Finding: MyISAM Tables Don't Replicate

**Solution:**
```sql
-- Convert tables to InnoDB before dump
ALTER TABLE table_name ENGINE=InnoDB;

-- Or exclude MyISAM tables from dump
mydumper --database=mydb --ignore-engines=MyISAM
```

### Finding: wsrep_on=OFF During Restore

**Solution:**
```sql
-- Ensure wsrep_on is enabled
SET GLOBAL wsrep_on=ON;

-- Check myloader source for session variables
-- May need to patch or configure myloader
```

### Finding: Transaction Size Exceeded

**Solution:**
```sql
-- Increase wsrep_max_ws_size (requires restart)
SET GLOBAL wsrep_max_ws_size = 2147483647;  -- 2GB max

-- Or use smaller chunk sizes in myloader
myloader --rows=10000  # Smaller batches
```

### Finding: Binary Logging Disabled

**Solution:**
```bash
# Ensure log_bin is enabled in config
[mysqld]
log_bin = /var/lib/mysql/mysql-bin
binlog_format = ROW

# Restart required
docker compose restart pxc-node1
```

### Finding: No Primary Keys

**Solution:**
```sql
-- Add primary keys before dump
ALTER TABLE table_name ADD PRIMARY KEY (id);

-- Or add unique key
ALTER TABLE table_name ADD UNIQUE KEY (composite, columns);
```

### Finding: Parallel Load FK Violations

**Solution:**
```bash
# Use single-threaded restore for FK-related tables
myloader --threads=1

# Or use correct load order
# 1. Load parent tables first
# 2. Then child tables
```

### Finding: Auto-increment Conflicts

**Solution:**
```sql
-- Ensure wsrep_auto_increment_control is ON
SET GLOBAL wsrep_auto_increment_control = ON;

-- Verify settings are correct
SHOW VARIABLES LIKE 'auto_increment_%';
```

---

## Validation Script Template

Create `scripts/validate_sync.sh`:

```bash
#!/bin/bash
# Validate data sync across all nodes

DATABASE="your_database"

echo "Comparing table row counts across nodes..."
echo "=========================================="

for table in $(docker compose exec -T pxc-node1 mysql -uroot -prootpass -N -e "
    SELECT TABLE_NAME
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA='$DATABASE'
"); do
    echo "Table: $table"

    count1=$(docker compose exec -T pxc-node1 mysql -uroot -prootpass -N -e "SELECT COUNT(*) FROM $DATABASE.$table" 2>/dev/null)
    count2=$(docker compose exec -T pxc-node2 mysql -uroot -prootpass -N -e "SELECT COUNT(*) FROM $DATABASE.$table" 2>/dev/null)
    count3=$(docker compose exec -T pxc-node3 mysql -uroot -prootpass -N -e "SELECT COUNT(*) FROM $DATABASE.$table" 2>/dev/null)

    echo "  Node1: $count1"
    echo "  Node2: $count2"
    echo "  Node3: $count3"

    if [ "$count1" != "$count2" ] || [ "$count1" != "$count3" ]; then
        echo "  ⚠️  MISMATCH DETECTED!"
    else
        echo "  ✓ Synchronized"
    fi
    echo ""
done
```

---

## Next Steps

Once you provide your database schema, I will:

1. **Analyze the schema** for potential issues:
   - Check storage engines
   - Identify tables without PKs
   - Review FK relationships
   - Check for auto-increment columns
   - Identify large tables that may hit size limits

2. **Narrow down test scenarios** based on your actual schema

3. **Create specific test scripts** tailored to your database structure

4. **Provide targeted recommendations** for fixing any issues found

---

## References

- [Galera Cluster Known Limitations](https://galeracluster.com/library/documentation/limitations.html)
- [Percona XtraDB Cluster Limitations](https://www.percona.com/doc/percona-xtradb-cluster/5.7/limitation.html)
- [mydumper Documentation](https://github.com/mydumper/mydumper)
- [Galera wsrep System Variables](https://galeracluster.com/library/documentation/mysql-wsrep-options.html)
