#!/bin/bash
set -e

# ============================================================================
# XtraBackup Physical Restore Script (Cluster Recovery)
# ============================================================================
# This script restores physical backups created by XtraBackup.
# Used for full cluster recovery scenarios.
#
# Usage: ./restore-cluster.sh <backup_directory>
#
# IMPORTANT:
# - This is for FULL CLUSTER RECOVERY only
# - All cluster nodes should be stopped before restore
# - For single database restore, use restore.sh instead
# ============================================================================

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [ -z "$1" ]; then
    echo -e "${RED}Error: Backup directory is required${NC}"
    echo ""
    echo "Usage: $0 <backup_directory>"
    echo ""
    echo "Example:"
    echo "  $0 xtrabackup_20250113_120000"
    echo ""
    echo -e "${CYAN}Available backups:${NC}"
    ls -1d /backups/xtrabackup_* 2>/dev/null | xargs -n1 basename || echo "No backups found"
    exit 1
fi

BACKUP_DIR="/backups/$1"

if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${RED}✗ Backup directory not found: ${BACKUP_DIR}${NC}"
    exit 1
fi

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  XtraBackup Cluster Restore${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${RED}⚠️  WARNING ⚠️${NC}"
echo -e "${YELLOW}This operation will REPLACE all data in the cluster!${NC}"
echo -e "${YELLOW}Make sure:${NC}"
echo -e "  1. All cluster nodes are STOPPED"
echo -e "  2. You have a backup of current data"
echo -e "  3. This is the correct backup to restore"
echo ""
echo -e "${CYAN}Backup to restore:${NC} $1"
echo ""
read -p "$(echo -e ${YELLOW}Type \'YES\' to continue: ${NC})" -r
echo

if [ "$REPLY" != "YES" ]; then
    echo -e "${RED}Restore cancelled${NC}"
    exit 1
fi

echo -e "${GREEN}Starting XtraBackup restore...${NC}"
echo ""

# Check if backup is prepared
if [ ! -f "${BACKUP_DIR}/xtrabackup_checkpoints" ]; then
    echo -e "${RED}✗ Invalid backup directory (missing xtrabackup_checkpoints)${NC}"
    exit 1
fi

# Check backup state
BACKUP_STATE=$(grep "backup_type" "${BACKUP_DIR}/xtrabackup_checkpoints" | awk '{print $3}')
echo -e "${CYAN}Backup state:${NC} ${YELLOW}${BACKUP_STATE}${NC}"

if [ "$BACKUP_STATE" != "full-prepared" ]; then
    echo -e "${YELLOW}Backup needs to be prepared first...${NC}"
    xtrabackup --prepare --target-dir="${BACKUP_DIR}"
fi

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Restore Instructions${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${YELLOW}Manual steps required:${NC}"
echo ""
echo -e "${GREEN}1. Stop all cluster nodes:${NC}"
echo -e "   docker compose stop pxc-node1 pxc-node2 pxc-node3"
echo ""
echo -e "${GREEN}2. Remove current data:${NC}"
echo -e "   docker compose down -v"
echo -e "   rm -rf ./data/*"
echo ""
echo -e "${GREEN}3. Copy backup to node1 data directory:${NC}"
echo -e "   xtrabackup --copy-back --target-dir=${BACKUP_DIR} --datadir=/var/lib/mysql"
echo ""
echo -e "${GREEN}4. Fix permissions:${NC}"
echo -e "   chown -R mysql:mysql /var/lib/mysql"
echo ""
echo -e "${GREEN}5. Bootstrap cluster from node1:${NC}"
echo -e "   docker compose up -d pxc-node1"
echo -e "   # Wait for node1 to be ready"
echo ""
echo -e "${GREEN}6. Start other nodes (they will sync via SST):${NC}"
echo -e "   docker compose up -d pxc-node2 pxc-node3"
echo ""
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${YELLOW}Note: XtraBackup cluster restore is a complex operation.${NC}"
echo -e "${YELLOW}For single database restore, use: make restore BACKUP=<backup_name>${NC}"
echo ""
