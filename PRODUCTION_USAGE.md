# Galera Backup & Restore - Production Usage

This guide explains how to use the backup and restore scripts in production environments (servers, VMs, bare metal).

## Overview

The scripts work on any server with:
- MySQL client installed
- mydumper/myloader installed
- Network access to the Galera cluster

## Installation

### Install mydumper/myloader

**CentOS/RHEL 8:**
```bash
sudo yum install -y https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper-0.16.3-3.el8.x86_64.rpm
```

**Ubuntu/Debian:**
```bash
wget https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper_0.16.3-3.focal_amd64.deb
sudo dpkg -i mydumper_*.deb
```

Verify installation:
```bash
mydumper --version
myloader --version
```

## Environment Variables

The scripts use environment variables for configuration:

| Variable | Default | Description |
|----------|---------|-------------|
| `MYSQL_HOST` | 127.0.0.1 | MySQL host |
| `MYSQL_PORT` | 3306 | MySQL port |
| `MYSQL_USER` | root | MySQL username |
| `MYSQL_PASSWORD` | rootpass | MySQL password |
| `BACKUP_DIR` | ./backups | Backup directory path |
| `GALERA_NODES` | *(empty)* | Comma-separated list for verification |

## Creating Backups

### Basic Backup

```bash
cd /path/to/galera
./scripts/backup.sh employees
```

### With Environment Variables

```bash
export MYSQL_HOST=10.0.0.10
export MYSQL_PORT=3306
export MYSQL_USER=backup_user
export MYSQL_PASSWORD=secure_password
export BACKUP_DIR=/backups

./scripts/backup.sh mydb
```

### With Command Line Options

```bash
./scripts/backup.sh mydb \
    --host=10.0.0.10 \
    --port=3306 \
    --user=backup_user \
    --password=secure_password \
    --threads=8 \
    --compress
```

### Backup to Custom Directory

```bash
BACKUP_DIR=/mnt/backups ./scripts/backup.sh employees --threads=8
```

## Restoring Backups

### Basic Restore

```bash
./scripts/restore.sh mydumper_employees_20251113_120000
```

### Restore to Different Database

```bash
./scripts/restore.sh mydumper_employees_20251113_120000 new_database_name
```

### With Galera Node Verification

```bash
export MYSQL_HOST=10.0.0.10
export MYSQL_PORT=3306
export GALERA_NODES="10.0.0.10:3306,10.0.0.11:3306,10.0.0.12:3306"

./scripts/restore.sh mydumper_employees_20251113_120000 \
    --overwrite \
    --threads=8
```

### Restore Without Verification

```bash
./scripts/restore.sh mydumper_employees_20251113_120000 \
    --no-verify
```

## Production Setup Examples

### Example 1: Backup from Production to Backup Server

**On backup server:**
```bash
#!/bin/bash
# /opt/backups/daily-backup.sh

export MYSQL_HOST=prod-galera-node1.example.com
export MYSQL_PORT=3306
export MYSQL_USER=backup_user
export MYSQL_PASSWORD=$(cat /secure/mysql-backup-password)
export BACKUP_DIR=/mnt/backup/mysql

cd /opt/galera-scripts

# Backup all databases
for DB in customers orders inventory; do
    ./scripts/backup.sh $DB --threads=8 --compress
done

# Clean old backups (keep 7 days)
find /mnt/backup/mysql -name "mydumper_*" -mtime +7 -exec rm -rf {} \;
```

### Example 2: Restore from Backup Server to Dev Cluster

**On dev cluster node:**
```bash
#!/bin/bash
# restore-to-dev.sh

BACKUP_NAME=$1

if [ -z "$BACKUP_NAME" ]; then
    echo "Usage: $0 <backup_name>"
    exit 1
fi

# Copy backup from backup server
rsync -avz backup-server:/mnt/backup/mysql/$BACKUP_NAME /tmp/

export MYSQL_HOST=localhost
export MYSQL_PORT=3306
export MYSQL_USER=root
export MYSQL_PASSWORD=devpass
export BACKUP_DIR=/tmp
export GALERA_NODES="dev-node1:3306,dev-node2:3306,dev-node3:3306"

cd /opt/galera-scripts

./scripts/restore.sh $BACKUP_NAME \
    --overwrite \
    --threads=8

# Cleanup
rm -rf /tmp/$BACKUP_NAME
```

### Example 3: Cron-based Scheduled Backups

```bash
# Add to crontab: crontab -e
0 2 * * * /opt/scripts/galera-backup.sh >> /var/log/galera-backup.log 2>&1
```

**Script `/opt/scripts/galera-backup.sh`:**
```bash
#!/bin/bash
set -e

export MYSQL_HOST=localhost
export MYSQL_USER=backup_user
export MYSQL_PASSWORD=$(cat /etc/mysql-backup.pwd)
export BACKUP_DIR=/backups/mysql

cd /opt/galera-scripts

# Backup
./scripts/backup.sh production_db \
    --threads=8 \
    --compress

# Upload to S3 (optional)
LATEST_BACKUP=$(ls -td /backups/mysql/mydumper_production_db_* | head -1)
aws s3 sync "$LATEST_BACKUP" "s3://my-backups/mysql/$(basename $LATEST_BACKUP)/" \
    --storage-class STANDARD_IA
```

## Galera-Specific Considerations

### Backup from Any Node

You can backup from any node in the Galera cluster. The script will verify the node is:
- In "Primary" cluster state
- In "Synced" state

```bash
./scripts/backup.sh mydb --host=galera-node2
```

### Restore to Single Node

**IMPORTANT:** Always restore to a **single node** only. Galera will automatically replicate the data to other nodes.

```bash
# ✅ Correct: Restore to one node
export MYSQL_HOST=galera-node1
./scripts/restore.sh mydumper_mydb_20251113_120000

# ❌ Wrong: Do NOT restore to multiple nodes simultaneously
```

### The --enable-binlog Flag

The restore script automatically uses `--enable-binlog` to ensure Galera replication works correctly. This is **critical** for Percona XtraDB Cluster/Galera.

Without this flag, data would only load on the target node and not replicate.

### Monitoring Flow Control

During large restores, Galera may trigger flow control to prevent nodes from falling behind:

```bash
# Check flow control on all nodes
for host in node1 node2 node3; do
    echo "$host:"
    mysql -h$host -uroot -p -e "SHOW STATUS LIKE 'wsrep_flow_control_paused';"
done
```

Flow control paused values:
- **0.0-0.1** (0-10%): Excellent
- **0.1-0.3** (10-30%): Acceptable during restore
- **>0.5** (>50%): May indicate resource constraints

## Script Options Reference

### backup.sh

```
Usage: ./backup.sh [database] [options]

Options:
  --host=HOST      MySQL host
  --port=PORT      MySQL port
  --user=USER      MySQL username
  --password=PASS  MySQL password
  --threads=N      Parallel threads (default: 4)
  --compress       Enable gzip compression
  --chunk-size=N   Chunk size in MB (default: 100)

Environment Variables:
  MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, BACKUP_DIR
```

### restore.sh

```
Usage: ./restore.sh <backup_dir> [database] [options]

Arguments:
  backup_dir       Backup directory name (required)
  database         Target database name (optional)

Options:
  --host=HOST      MySQL host
  --port=PORT      MySQL port
  --user=USER      MySQL username
  --password=PASS  MySQL password
  --threads=N      Parallel threads (default: 4)
  --overwrite      Drop existing tables
  --no-verify      Skip post-restore verification

Environment Variables:
  MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, BACKUP_DIR, GALERA_NODES
```

## Troubleshooting

### Connection Issues

```bash
# Test MySQL connection
mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER} -p${MYSQL_PASSWORD} -e "SELECT 1;"

# Check Galera status
mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER} -p${MYSQL_PASSWORD} \
    -e "SHOW STATUS LIKE 'wsrep%';"
```

### Backup Fails with "Cluster not ready"

The cluster must be in "Primary" state and "Synced":

```sql
SHOW STATUS LIKE 'wsrep_cluster_status';  -- Must be "Primary"
SHOW STATUS LIKE 'wsrep_local_state_comment';  -- Must be "Synced"
```

### Restore Takes Too Long

```bash
# Increase threads
./scripts/restore.sh backup_name --threads=16

# Or skip verification for very large datasets
./scripts/restore.sh backup_name --no-verify
```

### Replication Not Working After Restore

Verify `--enable-binlog` is being used (it should be automatic):

```bash
# Check myloader command in script
grep "enable-binlog" scripts/restore.sh
```

## Security Best Practices

### Use Dedicated Backup User

```sql
CREATE USER 'backup_user'@'backup-server' IDENTIFIED BY 'secure_password';
GRANT SELECT, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup_user'@'backup-server';
FLUSH PRIVILEGES;
```

### Store Passwords Securely

```bash
# Use password file
echo "my_secure_password" > /secure/mysql-backup.pwd
chmod 600 /secure/mysql-backup.pwd
chown backup:backup /secure/mysql-backup.pwd

# Read in script
export MYSQL_PASSWORD=$(cat /secure/mysql-backup.pwd)
```

### Encrypt Backups

```bash
# Backup with compression
./scripts/backup.sh mydb --compress

# Encrypt backup directory
tar czf - /backups/mydumper_mydb_20251113_120000 | \
    openssl enc -aes-256-cbc -pbkdf2 -out backup.tar.gz.enc

# Decrypt for restore
openssl enc -aes-256-cbc -d -pbkdf2 -in backup.tar.gz.enc | \
    tar xz -C /backups/
```

## Performance Tips

1. **Use more threads** for large databases: `--threads=16`
2. **Enable compression** for network transfers: `--compress`
3. **Adjust chunk size** for huge tables: `--chunk-size=200`
4. **Backup during off-peak** hours to minimize impact
5. **Use dedicated backup node** if possible (least loaded node)

## Backup Storage Recommendations

- **Local:** Fast but limited by disk space
- **NFS/SAN:** Centralized but network dependent
- **Object Storage (S3):** Unlimited, durable, requires upload time
- **Hybrid:** Local + S3 sync for best of both worlds

## Next Steps

- See [GALERA_BACKUP_RESTORE.md](./GALERA_BACKUP_RESTORE.md) for Docker usage
- See [CLAUDE.md](./CLAUDE.md) for full project documentation
