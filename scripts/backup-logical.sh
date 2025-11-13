#!/bin/bash
set -e

# ============================================================================
# Logical Database Backup using MyDumper
# ============================================================================
# This script creates logical backups of a single database using mydumper.
# Unlike XtraBackup (physical backup), logical backups can be easily restored
# to different clusters and are portable across MySQL versions.
#
# Usage: ./backup-logical.sh [database_name] [options]
#
# Options:
#   --threads=N    Number of threads for parallel backup (default: 4)
#   --compress     Compress backup files with gzip
#   --chunk-size=N Chunk tables into files of N MB (default: 100)
# ============================================================================

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
DATABASE="${1:-employees}"
THREADS=4
COMPRESS=""
CHUNK_SIZE=100
NODE="pxc-node1"

# Parse additional arguments
shift || true
for arg in "$@"; do
    case $arg in
        --threads=*)
            THREADS="${arg#*=}"
            ;;
        --compress)
            COMPRESS="--compress"
            ;;
        --chunk-size=*)
            CHUNK_SIZE="${arg#*=}"
            ;;
        --node=*)
            NODE="${arg#*=}"
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            exit 1
            ;;
    esac
done

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/backups/mydumper_${DATABASE}_${BACKUP_TIMESTAMP}"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  MyDumper Logical Backup${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo -e "  Database:     ${YELLOW}${DATABASE}${NC}"
echo -e "  Backup node:  ${YELLOW}${NODE}${NC}"
echo -e "  Threads:      ${YELLOW}${THREADS}${NC}"
echo -e "  Chunk size:   ${YELLOW}${CHUNK_SIZE} MB${NC}"
echo -e "  Compression:  ${YELLOW}$([ -n "$COMPRESS" ] && echo "Enabled" || echo "Disabled")${NC}"
echo -e "  Output:       ${YELLOW}./backups/mydumper_${DATABASE}_${BACKUP_TIMESTAMP}${NC}"
echo ""

# Check if cluster is healthy
echo -e "${CYAN}Checking cluster health...${NC}"
CLUSTER_STATUS=$(docker compose exec -T ${NODE} mysql -uroot -prootpass -Nse \
    "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size');" 2>/dev/null || echo "")

if [ -z "$CLUSTER_STATUS" ]; then
    echo -e "${RED}✗ Cannot connect to cluster${NC}"
    exit 1
fi

echo "$CLUSTER_STATUS" | while read -r line; do
    echo -e "  ${YELLOW}${line}${NC}"
done

# Verify cluster is in Primary state
PRIMARY_CHECK=$(docker compose exec -T ${NODE} mysql -uroot -prootpass -Nse \
    "SHOW STATUS WHERE Variable_name='wsrep_cluster_status' AND Value='Primary';" 2>/dev/null | wc -l | tr -d ' ')

if [ "$PRIMARY_CHECK" != "1" ]; then
    echo -e "${RED}✗ Cluster is not in a healthy state for backup${NC}"
    echo -e "${YELLOW}  Please ensure the cluster is in 'Primary' status and node is 'Synced'${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Cluster is healthy${NC}"
echo ""

# Check if database exists
echo -e "${CYAN}Verifying database exists...${NC}"
DB_EXISTS=$(docker compose exec -T ${NODE} mysql -uroot -prootpass -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DATABASE}';" 2>/dev/null)

if [ "$DB_EXISTS" != "1" ]; then
    echo -e "${RED}✗ Database '${DATABASE}' does not exist${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Database '${DATABASE}' found${NC}"
echo ""

# Check if mydumper is installed, if not, install it
echo -e "${CYAN}Checking mydumper installation...${NC}"
MYDUMPER_INSTALLED=$(docker compose exec -T ${NODE} bash -c "command -v mydumper >/dev/null 2>&1 && echo 'yes' || echo 'no'")

if [ "$MYDUMPER_INSTALLED" != "yes" ]; then
    echo -e "${YELLOW}Installing mydumper...${NC}"
    docker exec -u root galera-${NODE}-1 bash -c "
        cd /tmp && \
        curl -sL -o mydumper.rpm https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper-0.16.3-3.el8.x86_64.rpm && \
        rpm -i --force mydumper.rpm 2>&1 | tail -5
    " || {
        echo -e "${RED}✗ Failed to install mydumper${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ MyDumper installed${NC}"
else
    echo -e "${GREEN}✓ MyDumper is already installed${NC}"
fi
echo ""

# Create backup
echo -e "${GREEN}Creating backup of database '${DATABASE}'...${NC}"
echo -e "${YELLOW}This may take several minutes depending on database size...${NC}"
echo ""

docker compose exec -T ${NODE} bash -c "
    set -e

    # Run mydumper (it will create the directory)
    mydumper \
        --database=${DATABASE} \
        --outputdir=${BACKUP_PATH} \
        --threads=${THREADS} \
        --chunk-filesize=${CHUNK_SIZE} \
        --build-empty-files \
        --triggers \
        --events \
        --routines \
        --verbose=3 \
        --host=127.0.0.1 \
        --user=root \
        --password=rootpass \
        ${COMPRESS} 2>&1

    # Create metadata file
    cat > ${BACKUP_PATH}/backup_metadata.txt <<'METADATA_EOF'
Backup Information
==================
Database:        ${DATABASE}
Backup Date:     $(date)
Backup Method:   MyDumper (logical)
Source Node:     ${NODE}
Threads:         ${THREADS}
Chunk Size:      ${CHUNK_SIZE} MB

Cluster Status at Backup Time:
$(mysql -h127.0.0.1 -uroot -prootpass -Nse 'SHOW STATUS WHERE Variable_name LIKE \"wsrep_%\" AND Variable_name IN (\"wsrep_cluster_status\", \"wsrep_local_state_comment\", \"wsrep_cluster_size\", \"wsrep_cluster_state_uuid\");' 2>/dev/null)

MySQL Version:
$(mysql -V 2>/dev/null || echo 'Percona XtraDB Cluster 5.7')
METADATA_EOF

    # Show backup size
    du -sh ${BACKUP_PATH}
"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  ✓ Backup completed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "${CYAN}Backup location:${NC} ./backups/mydumper_${DATABASE}_${BACKUP_TIMESTAMP}"
echo ""
echo -e "${CYAN}Backup contents:${NC}"
docker compose exec -T ${NODE} ls -lh ${BACKUP_PATH} | tail -n +2 | head -10
TOTAL_FILES=$(docker compose exec -T ${NODE} find ${BACKUP_PATH} -type f | wc -l)
echo -e "${YELLOW}... and $(($TOTAL_FILES - 10)) more files${NC}"
echo ""
echo -e "${CYAN}To restore this backup, use:${NC}"
echo -e "  ${YELLOW}make restore-logical BACKUP=mydumper_${DATABASE}_${BACKUP_TIMESTAMP} DATABASE=${DATABASE}${NC}"
echo ""
