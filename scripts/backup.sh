#!/bin/bash
set -e

# ============================================================================
# Logical Database Backup using MyDumper
# ============================================================================
# This script creates logical backups of a single database using mydumper.
# It works on any host with mydumper installed and MySQL/Galera access.
#
# Usage: ./backup.sh [database_name] [options]
#
# Environment Variables:
#   MYSQL_HOST       MySQL host (default: 127.0.0.1)
#   MYSQL_PORT       MySQL port (default: 3306)
#   MYSQL_USER       MySQL user (default: root)
#   MYSQL_PASSWORD   MySQL password (default: rootpass)
#   BACKUP_DIR       Backup directory (default: ./backups)
#
# Options:
#   --threads=N      Number of threads for parallel backup (default: 4)
#   --compress       Compress backup files with gzip
#   --chunk-size=N   Chunk tables into files of N MB (default: 100)
#   --host=HOST      Override MySQL host
#   --port=PORT      Override MySQL port
#   --user=USER      Override MySQL user
#   --password=PASS  Override MySQL password
# ============================================================================

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values from environment or hardcoded
DATABASE="${1:-employees}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-rootpass}"
BACKUP_BASE_DIR="${BACKUP_DIR:-./backups}"
THREADS=4
COMPRESS=""
CHUNK_SIZE=100

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
        --host=*)
            MYSQL_HOST="${arg#*=}"
            ;;
        --port=*)
            MYSQL_PORT="${arg#*=}"
            ;;
        --user=*)
            MYSQL_USER="${arg#*=}"
            ;;
        --password=*)
            MYSQL_PASSWORD="${arg#*=}"
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            exit 1
            ;;
    esac
done

BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_BASE_DIR}/mydumper_${DATABASE}_${BACKUP_TIMESTAMP}"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  MyDumper Logical Backup${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}Configuration:${NC}"
echo -e "  Database:     ${YELLOW}${DATABASE}${NC}"
echo -e "  MySQL Host:   ${YELLOW}${MYSQL_HOST}:${MYSQL_PORT}${NC}"
echo -e "  MySQL User:   ${YELLOW}${MYSQL_USER}${NC}"
echo -e "  Threads:      ${YELLOW}${THREADS}${NC}"
echo -e "  Chunk size:   ${YELLOW}${CHUNK_SIZE} MB${NC}"
echo -e "  Compression:  ${YELLOW}$([ -n "$COMPRESS" ] && echo "Enabled" || echo "Disabled")${NC}"
echo -e "  Output:       ${YELLOW}${BACKUP_PATH}${NC}"
echo ""

# Check if mydumper is installed
echo -e "${CYAN}Checking mydumper installation...${NC}"
if ! command -v mydumper >/dev/null 2>&1; then
    echo -e "${RED}✗ mydumper is not installed${NC}"
    echo ""
    echo -e "${YELLOW}Please install mydumper:${NC}"
    echo "  CentOS/RHEL: sudo yum install https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper-0.16.3-3.el8.x86_64.rpm"
    echo "  Ubuntu/Debian: wget https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper_0.16.3-3.$(lsb_release -cs)_amd64.deb && sudo dpkg -i mydumper_*.deb"
    exit 1
fi
echo -e "${GREEN}✓ MyDumper $(mydumper --version 2>&1 | head -1)${NC}"
echo ""

# Check MySQL connectivity
echo -e "${CYAN}Testing MySQL connection...${NC}"
if ! mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to MySQL at ${MYSQL_HOST}:${MYSQL_PORT}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to MySQL${NC}"
echo ""

# Check if it's a Galera cluster (optional check)
echo -e "${CYAN}Checking cluster status...${NC}"
CLUSTER_STATUS=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
    "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size');" 2>/dev/null || echo "")

if [ -n "$CLUSTER_STATUS" ]; then
    echo -e "${GREEN}Galera cluster detected:${NC}"
    echo "$CLUSTER_STATUS" | while read -r line; do
        echo -e "  ${YELLOW}${line}${NC}"
    done

    # Verify cluster is in Primary state
    PRIMARY_COUNT=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
        "SHOW STATUS WHERE Variable_name='wsrep_cluster_status' AND Value='Primary';" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$PRIMARY_COUNT" != "1" ]; then
        echo -e "${RED}✗ Cluster is not in 'Primary' state${NC}"
        echo -e "${YELLOW}  Warning: Backup may be inconsistent${NC}"
    else
        echo -e "${GREEN}✓ Cluster is in Primary state${NC}"
    fi
else
    echo -e "${YELLOW}Not a Galera cluster (or wsrep not available)${NC}"
    echo -e "${YELLOW}Proceeding with standard MySQL backup${NC}"
fi
echo ""

# Check if database exists
echo -e "${CYAN}Verifying database exists...${NC}"
DB_EXISTS=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DATABASE}';" 2>/dev/null)

if [ "$DB_EXISTS" != "1" ]; then
    echo -e "${RED}✗ Database '${DATABASE}' does not exist${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Database '${DATABASE}' found${NC}"
echo ""

# Create backup directory
mkdir -p "${BACKUP_BASE_DIR}"

# Create backup
echo -e "${GREEN}Creating backup of database '${DATABASE}'...${NC}"
echo -e "${YELLOW}This may take several minutes depending on database size...${NC}"
echo ""

START_TIME=$(date +%s)

# Run mydumper
mydumper \
    --database="${DATABASE}" \
    --outputdir="${BACKUP_PATH}" \
    --host="${MYSQL_HOST}" \
    --port="${MYSQL_PORT}" \
    --user="${MYSQL_USER}" \
    --password="${MYSQL_PASSWORD}" \
    --threads="${THREADS}" \
    --chunk-filesize="${CHUNK_SIZE}" \
    --build-empty-files \
    --triggers \
    --events \
    --routines \
    --verbose=3 \
    ${COMPRESS} 2>&1

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Create metadata file
cat > "${BACKUP_PATH}/backup_metadata.txt" <<METADATA_EOF
Backup Information
==================
Database:        ${DATABASE}
Backup Date:     $(date)
Backup Method:   MyDumper (logical)
Duration:        ${DURATION} seconds
Source Host:     ${MYSQL_HOST}:${MYSQL_PORT}
Threads:         ${THREADS}
Chunk Size:      ${CHUNK_SIZE} MB
Compression:     $([ -n "$COMPRESS" ] && echo "Enabled" || echo "Disabled")

Cluster Status at Backup Time:
$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse "SHOW STATUS WHERE Variable_name LIKE 'wsrep_%' AND Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');" 2>/dev/null || echo "Not a Galera cluster")

MySQL Version:
$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -V 2>/dev/null)
METADATA_EOF

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  ✓ Backup completed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "${CYAN}Backup location:${NC} ${BACKUP_PATH}"
echo -e "${CYAN}Backup size:${NC}     $(du -sh "${BACKUP_PATH}" | cut -f1)"
echo -e "${CYAN}Duration:${NC}        ${DURATION} seconds"
echo ""
echo -e "${CYAN}Backup contents:${NC}"
ls -lh "${BACKUP_PATH}" | tail -n +2 | head -10
TOTAL_FILES=$(find "${BACKUP_PATH}" -type f | wc -l)
if [ "$TOTAL_FILES" -gt 10 ]; then
    echo -e "${YELLOW}... and $(($TOTAL_FILES - 10)) more files${NC}"
fi
echo ""
echo -e "${CYAN}To restore this backup, use:${NC}"
echo -e "  ${YELLOW}./scripts/restore.sh $(basename ${BACKUP_PATH}) ${DATABASE}${NC}"
echo ""
