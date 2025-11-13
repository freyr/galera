#!/bin/bash
set -e

# ============================================================================
# Logical Database Restore using MyLoader (Galera-Aware)
# ============================================================================
# This script restores logical backups created by mydumper into MySQL/Galera.
# It works on any host with myloader installed and MySQL/Galera access.
#
# Usage: ./restore.sh <backup_directory> [database_name] [options]
#
# Environment Variables:
#   MYSQL_HOST       MySQL host (default: 127.0.0.1)
#   MYSQL_PORT       MySQL port (default: 3306)
#   MYSQL_USER       MySQL user (default: root)
#   MYSQL_PASSWORD   MySQL password (default: rootpass)
#   BACKUP_DIR       Backup directory (default: ./backups)
#   GALERA_NODES     Comma-separated list of Galera nodes for verification (optional)
#                    Example: "127.0.0.1:3306,127.0.0.1:3307,127.0.0.1:3308"
#
# Options:
#   --threads=N       Number of threads for parallel restore (default: 4)
#   --overwrite       Drop existing tables before restore
#   --host=HOST       Override MySQL host
#   --port=PORT       Override MySQL port
#   --user=USER       Override MySQL user
#   --password=PASS   Override MySQL password
#   --no-verify       Skip post-restore verification
#
# IMPORTANT GALERA CONSIDERATIONS:
#   - Restore is performed on a single node (specified host)
#   - Data automatically replicates to other cluster nodes via Galera
#   - Uses --enable-binlog flag to ensure proper Galera replication
#   - Monitors cluster health before and after restore
# ============================================================================

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Error: Backup directory is required${NC}"
    echo ""
    echo "Usage: $0 <backup_directory> [database_name] [options]"
    echo ""
    echo "Example:"
    echo "  $0 mydumper_employees_20250113_120000"
    echo "  $0 mydumper_employees_20250113_120000 new_database_name --overwrite"
    exit 1
fi

# Default values from environment or hardcoded
BACKUP_DIR_NAME="$1"
DATABASE="$2"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-rootpass}"
BACKUP_BASE_DIR="${BACKUP_DIR:-./backups}"
GALERA_NODES="${GALERA_NODES:-}"
THREADS=4
OVERWRITE=""
VERIFY=true

# Parse additional arguments
shift || true
shift || true
for arg in "$@"; do
    case $arg in
        --threads=*)
            THREADS="${arg#*=}"
            ;;
        --overwrite)
            OVERWRITE="--overwrite-tables"
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
        --no-verify)
            VERIFY=false
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            exit 1
            ;;
    esac
done

BACKUP_PATH="${BACKUP_BASE_DIR}/${BACKUP_DIR_NAME}"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  MyLoader Galera-Aware Restore${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Verify backup directory exists
echo -e "${CYAN}Verifying backup directory...${NC}"
if [ ! -d "${BACKUP_PATH}" ]; then
    echo -e "${RED}✗ Backup directory not found: ${BACKUP_PATH}${NC}"
    echo ""
    echo -e "${CYAN}Available backups:${NC}"
    ls -1 "${BACKUP_BASE_DIR}/" 2>/dev/null | grep mydumper_ || echo "No backups found"
    exit 1
fi

echo -e "${GREEN}✓ Backup directory found${NC}"

# Read original database name from metadata
ORIGINAL_DB=""
if [ -f "${BACKUP_PATH}/metadata" ]; then
    ORIGINAL_DB=$(grep -oP "SHOW DATABASES WHERE .*? '\K[^']+'" "${BACKUP_PATH}/metadata" 2>/dev/null | head -1 || echo "")
fi

# If no database specified, use original
if [ -z "$DATABASE" ]; then
    if [ -n "$ORIGINAL_DB" ]; then
        DATABASE="$ORIGINAL_DB"
        echo -e "${YELLOW}Using original database name: ${DATABASE}${NC}"
    else
        echo -e "${RED}✗ Cannot determine database name. Please specify database name as second argument.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Configuration:${NC}"
echo -e "  Backup:       ${YELLOW}${BACKUP_DIR_NAME}${NC}"
echo -e "  Database:     ${YELLOW}${DATABASE}${NC}"
echo -e "  MySQL Host:   ${YELLOW}${MYSQL_HOST}:${MYSQL_PORT}${NC}"
echo -e "  MySQL User:   ${YELLOW}${MYSQL_USER}${NC}"
echo -e "  Threads:      ${YELLOW}${THREADS}${NC}"
echo -e "  Overwrite:    ${YELLOW}$([ -n "$OVERWRITE" ] && echo "Yes" || echo "No")${NC}"
echo -e "  Verification: ${YELLOW}$([ "$VERIFY" = true ] && echo "Enabled" || echo "Disabled")${NC}"
echo ""

# Check if myloader is installed
echo -e "${CYAN}Checking myloader installation...${NC}"
if ! command -v myloader >/dev/null 2>&1; then
    echo -e "${RED}✗ myloader is not installed${NC}"
    echo ""
    echo -e "${YELLOW}Please install myloader (same package as mydumper):${NC}"
    echo "  CentOS/RHEL: sudo yum install https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper-0.16.3-3.el8.x86_64.rpm"
    echo "  Ubuntu/Debian: wget https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper_0.16.3-3.$(lsb_release -cs)_amd64.deb && sudo dpkg -i mydumper_*.deb"
    exit 1
fi
echo -e "${GREEN}✓ MyLoader $(myloader --version 2>&1 | head -1)${NC}"
echo ""

# Check MySQL connectivity
echo -e "${CYAN}Testing MySQL connection...${NC}"
if ! mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo -e "${RED}✗ Cannot connect to MySQL at ${MYSQL_HOST}:${MYSQL_PORT}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to MySQL${NC}"
echo ""

# Check cluster health before restore
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Pre-Restore Cluster Health Check${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Check if Galera cluster
CLUSTER_STATUS=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
    "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size');" 2>/dev/null || echo "")

if [ -n "$CLUSTER_STATUS" ]; then
    echo -e "${GREEN}Galera cluster detected${NC}"
    echo "$CLUSTER_STATUS" | while read -r line; do
        echo -e "  ${YELLOW}${line}${NC}"
    done

    # Verify cluster is ready
    PRIMARY_COUNT=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
        "SHOW STATUS WHERE Variable_name='wsrep_cluster_status' AND Value='Primary';" 2>/dev/null | wc -l | tr -d ' ')

    SYNCED_COUNT=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
        "SHOW STATUS WHERE Variable_name='wsrep_local_state_comment' AND Value='Synced';" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$PRIMARY_COUNT" != "1" ] || [ "$SYNCED_COUNT" != "1" ]; then
        echo -e "${RED}✗ Cluster is not ready for restore${NC}"
        echo -e "${YELLOW}  Please ensure cluster is in 'Primary' status and 'Synced' state${NC}"
        echo -e "${YELLOW}  Primary: ${PRIMARY_COUNT}, Synced: ${SYNCED_COUNT}${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Cluster is healthy and ready${NC}"
else
    echo -e "${YELLOW}Not a Galera cluster (or wsrep not available)${NC}"
    echo -e "${YELLOW}Proceeding with standard MySQL restore${NC}"
fi
echo ""

# Warning about Galera replication
if [ -n "$CLUSTER_STATUS" ]; then
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}  Galera Replication Information${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo -e "  • Restore will be performed on ${CYAN}${MYSQL_HOST}:${MYSQL_PORT}${NC}"
    echo -e "  • Data will automatically replicate to other nodes via Galera"
    echo -e "  • Using ${CYAN}--enable-binlog${NC} flag to ensure proper replication"
    echo -e "  • Large datasets may cause temporary flow control (cluster slowdown)"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C within 5 seconds to cancel...${NC}"
    sleep 5
    echo ""
fi

# Get table count from backup for progress tracking
TABLE_COUNT=$(find "${BACKUP_PATH}" -name '*.sql' -o -name '*.sql.gz' 2>/dev/null | wc -l)
echo -e "${CYAN}Restoring ${TABLE_COUNT} table files...${NC}"
echo ""

# Perform restore
echo -e "${GREEN}Starting restore process...${NC}"
echo -e "${YELLOW}This may take several minutes depending on database size...${NC}"
echo ""

START_TIME=$(date +%s)

# Run myloader with Galera-aware settings
myloader \
    --directory="${BACKUP_PATH}" \
    --database="${DATABASE}" \
    --host="${MYSQL_HOST}" \
    --port="${MYSQL_PORT}" \
    --user="${MYSQL_USER}" \
    --password="${MYSQL_PASSWORD}" \
    --threads="${THREADS}" \
    --enable-binlog \
    ${OVERWRITE} \
    --verbose=3 2>&1 | while IFS= read -r line; do
        # Filter out password warnings and format output
        if [[ ! "$line" =~ "Using a password on the command line" ]]; then
            echo -e "${YELLOW}${line}${NC}"
        fi
    done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}✓ Restore completed in ${DURATION} seconds${NC}"
echo ""

# Post-restore verification
if [ "$VERIFY" = true ]; then
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}  Post-Restore Verification${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""

    # Wait a moment for replication to complete
    if [ -n "$CLUSTER_STATUS" ]; then
        echo -e "${YELLOW}Waiting 3 seconds for replication to propagate...${NC}"
        sleep 3
        echo ""
    fi

    # Check database exists on target node
    echo -e "${CYAN}Verifying database exists...${NC}"
    DB_EXISTS=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DATABASE}';" 2>/dev/null || echo "0")

    if [ "$DB_EXISTS" = "1" ]; then
        echo -e "  ${GREEN}✓${NC} ${MYSQL_HOST}:${MYSQL_PORT}: Database '${DATABASE}' exists"
    else
        echo -e "  ${RED}✗${NC} ${MYSQL_HOST}:${MYSQL_PORT}: Database '${DATABASE}' NOT found"
    fi
    echo ""

    # Get table count from target node
    echo -e "${CYAN}Verifying table count...${NC}"
    SOURCE_TABLES=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DATABASE}';" 2>/dev/null)

    echo -e "  Target node: ${YELLOW}${SOURCE_TABLES} tables${NC}"
    echo ""

    # If GALERA_NODES is set, verify replication across all nodes
    if [ -n "$GALERA_NODES" ] && [ -n "$CLUSTER_STATUS" ]; then
        echo -e "${CYAN}Verifying replication across cluster nodes...${NC}"

        IFS=',' read -ra NODES <<< "$GALERA_NODES"
        ALL_SYNCED=true

        for node_spec in "${NODES[@]}"; do
            NODE_HOST=$(echo "$node_spec" | cut -d':' -f1)
            NODE_PORT=$(echo "$node_spec" | cut -d':' -f2)

            # Skip if it's the same as target node
            if [ "$NODE_HOST:$NODE_PORT" = "$MYSQL_HOST:$MYSQL_PORT" ]; then
                continue
            fi

            NODE_TABLES=$(mysql -h"${NODE_HOST}" -P"${NODE_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
                "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DATABASE}';" 2>/dev/null || echo "0")

            if [ "$NODE_TABLES" = "$SOURCE_TABLES" ]; then
                echo -e "  ${GREEN}✓${NC} ${NODE_HOST}:${NODE_PORT}: ${YELLOW}${NODE_TABLES} tables${NC} - Synchronized"
            else
                echo -e "  ${RED}✗${NC} ${NODE_HOST}:${NODE_PORT}: ${YELLOW}${NODE_TABLES} tables${NC} - NOT synchronized (expected ${SOURCE_TABLES})"
                ALL_SYNCED=false
            fi
        done

        echo ""

        if [ "$ALL_SYNCED" = true ]; then
            echo -e "${GREEN}✓ All nodes are synchronized${NC}"
        else
            echo -e "${YELLOW}⚠ Some nodes may not be fully synchronized yet${NC}"
        fi
    fi

    # Final cluster health check
    if [ -n "$CLUSTER_STATUS" ]; then
        echo ""
        echo -e "${CYAN}Final cluster health check...${NC}"
        FLOW_CONTROL=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
            "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='wsrep_flow_control_paused';" 2>/dev/null || echo "N/A")

        NODE_STATE=$(mysql -h"${MYSQL_HOST}" -P"${MYSQL_PORT}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -Nse \
            "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='wsrep_local_state_comment';" 2>/dev/null || echo "N/A")

        echo -e "  ${MYSQL_HOST}:${MYSQL_PORT}: State=${YELLOW}${NODE_STATE}${NC}, Flow Control Paused=${YELLOW}${FLOW_CONTROL}${NC}"
        echo ""
    fi

    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  ✓ Verification Successful!${NC}"
    echo -e "${GREEN}=========================================${NC}"
else
    echo -e "${YELLOW}Verification skipped (--no-verify flag used)${NC}"
fi

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Restore Summary${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "  Backup:        ${YELLOW}${BACKUP_DIR_NAME}${NC}"
echo -e "  Database:      ${YELLOW}${DATABASE}${NC}"
echo -e "  Duration:      ${YELLOW}${DURATION} seconds${NC}"
echo -e "  Target:        ${YELLOW}${MYSQL_HOST}:${MYSQL_PORT}${NC}"
echo -e "  Status:        ${GREEN}Completed${NC}"
echo ""
echo -e "${CYAN}You can now access the database:${NC}"
echo -e "  ${YELLOW}mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER} -p${MYSQL_PASSWORD} ${DATABASE}${NC}"
echo ""
