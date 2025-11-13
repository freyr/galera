#!/bin/bash
set -e

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

DATABASE="${1:-employees}"
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/backups/xtrabackup_${BACKUP_TIMESTAMP}"

echo -e "${GREEN}Creating XtraBackup of database: ${DATABASE}${NC}"

docker compose exec -T pxc-node1 bash -c "
    mkdir -p ${BACKUP_PATH} && \
    xtrabackup --backup \
        --target-dir=${BACKUP_PATH} \
        --datadir=/var/lib/mysql \
        --user=root \
        --password=rootpass \
        --databases='${DATABASE}' \
        2>&1 | tee ${BACKUP_PATH}/backup.log && \
    xtrabackup --prepare \
        --target-dir=${BACKUP_PATH} \
        2>&1 | tee -a ${BACKUP_PATH}/prepare.log
"

echo ""
echo -e "${GREEN}✓ Backup completed: ./backups/xtrabackup_${BACKUP_TIMESTAMP}${NC}"
