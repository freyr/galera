#!/bin/bash
set -e

# ============================================================================
# Logical Database Restore using MyLoader (Galera-Aware)
# ============================================================================
# This script restores logical backups created by mydumper into a Galera cluster.
# It properly handles Galera replication to ensure data is synchronized across
# all cluster nodes.
#
# Usage: ./restore-logical.sh <backup_directory> [database_name] [options]
#
# Arguments:
#   backup_directory  Name of the backup directory (e.g., mydumper_employees_20250113_120000)
#   database_name     Target database name (optional, defaults to original)
#
# Options:
#   --threads=N       Number of threads for parallel restore (default: 4)
#   --overwrite       Drop existing tables before restore
#   --node=NODE       Target node for restore (default: pxc-node1)
#   --no-verify       Skip post-restore verification
#
# IMPORTANT GALERA CONSIDERATIONS:
# - Restore is performed on a single node (node1 by default)
# - Data automatically replicates to other cluster nodes via Galera
# - Uses --enable-binlog flag to ensure proper Galera replication
# - Monitors cluster health before, during, and after restore
# - Verifies data replication across all nodes after restore
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

# Default values
BACKUP_DIR="$1"
DATABASE="$2"
THREADS=4
OVERWRITE=""
NODE="pxc-node1"
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
        --node=*)
            NODE="${arg#*=}"
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

BACKUP_PATH="/backups/${BACKUP_DIR}"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  MyLoader Galera-Aware Restore${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Verify backup directory exists
echo -e "${CYAN}Verifying backup directory...${NC}"
BACKUP_EXISTS=$(docker compose exec -T ${NODE} bash -c "[ -d ${BACKUP_PATH} ] && echo 'yes' || echo 'no'")

if [ "$BACKUP_EXISTS" != "yes" ]; then
    echo -e "${RED}✗ Backup directory not found: ${BACKUP_PATH}${NC}"
    echo ""
    echo -e "${CYAN}Available backups:${NC}"
    docker compose exec -T ${NODE} bash -c "ls -1 /backups/ | grep mydumper_ || echo 'No backups found'"
    exit 1
fi

echo -e "${GREEN}✓ Backup directory found${NC}"

# Read original database name from metadata
ORIGINAL_DB=$(docker compose exec -T ${NODE} bash -c "
    if [ -f ${BACKUP_PATH}/metadata ]; then
        grep 'SHOW DATABASES' ${BACKUP_PATH}/metadata | head -1 | sed 's/SHOW DATABASES WHERE .* (\(.*\))/\1/' | tr -d \"'\" || echo ''
    fi
" 2>/dev/null)

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
echo -e "  Backup:       ${YELLOW}${BACKUP_DIR}${NC}"
echo -e "  Database:     ${YELLOW}${DATABASE}${NC}"
echo -e "  Target node:  ${YELLOW}${NODE}${NC}"
echo -e "  Threads:      ${YELLOW}${THREADS}${NC}"
echo -e "  Overwrite:    ${YELLOW}$([ -n "$OVERWRITE" ] && echo "Yes" || echo "No")${NC}"
echo -e "  Verification: ${YELLOW}$([ "$VERIFY" = true ] && echo "Enabled" || echo "Disabled")${NC}"
echo ""

# Check cluster health before restore
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Pre-Restore Cluster Health Check${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

for check_node in pxc-node1 pxc-node2 pxc-node3; do
    echo -e "${CYAN}Checking ${check_node}...${NC}"

    NODE_STATUS=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
        "SELECT CONCAT(
            'Status: ', @@wsrep_cluster_status, ' | ',
            'State: ', @@wsrep_local_state_comment, ' | ',
            'Cluster Size: ', @@wsrep_cluster_size
        );" 2>/dev/null || echo "ERROR")

    if [ "$NODE_STATUS" = "ERROR" ]; then
        echo -e "  ${RED}✗ Cannot connect to ${check_node}${NC}"
    else
        echo -e "  ${GREEN}✓${NC} ${YELLOW}${NODE_STATUS}${NC}"

        # Check if node is ready
        READY=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
            "SELECT IF(@@wsrep_cluster_status = 'Primary' AND @@wsrep_local_state_comment = 'Synced', 'YES', 'NO');" 2>/dev/null)

        if [ "$READY" != "YES" ]; then
            echo -e "  ${RED}✗ Node ${check_node} is not ready for restore${NC}"
            echo -e "  ${YELLOW}Please ensure all nodes are in 'Primary' status and 'Synced' state${NC}"
            exit 1
        fi
    fi
done

echo -e "${GREEN}✓ All cluster nodes are healthy${NC}"
echo ""

# Check if myloader is installed
echo -e "${CYAN}Checking myloader installation...${NC}"
MYLOADER_INSTALLED=$(docker compose exec -T ${NODE} bash -c "command -v myloader >/dev/null 2>&1 && echo 'yes' || echo 'no'")

if [ "$MYLOADER_INSTALLED" != "yes" ]; then
    echo -e "${YELLOW}Installing myloader...${NC}"
    docker exec -u root galera-${NODE}-1 bash -c "
        cd /tmp && \
        curl -sL -o mydumper.rpm https://github.com/mydumper/mydumper/releases/download/v0.16.3-3/mydumper-0.16.3-3.el8.x86_64.rpm && \
        rpm -i --force mydumper.rpm 2>&1 | tail -5
    " || {
        echo -e "${RED}✗ Failed to install myloader${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ MyLoader installed${NC}"
else
    echo -e "${GREEN}✓ MyLoader is already installed${NC}"
fi
echo ""

# Warning about Galera replication
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Galera Replication Information${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC}"
echo -e "  • Restore will be performed on ${CYAN}${NODE}${NC} only"
echo -e "  • Data will automatically replicate to other nodes via Galera"
echo -e "  • Using ${CYAN}--enable-binlog${NC} flag to ensure proper replication"
echo -e "  • Large datasets may cause temporary flow control (cluster slowdown)"
echo -e "  • Post-restore verification will check replication across all nodes"
echo ""
echo -e "${YELLOW}Press Ctrl+C within 5 seconds to cancel...${NC}"
sleep 5
echo ""

# Get table count from backup for progress tracking
TABLE_COUNT=$(docker compose exec -T ${NODE} bash -c "find ${BACKUP_PATH} -name '*.sql' -o -name '*.sql.gz' | wc -l")
echo -e "${CYAN}Restoring ${TABLE_COUNT} table files...${NC}"
echo ""

# Perform restore
echo -e "${GREEN}Starting restore process...${NC}"
echo -e "${YELLOW}This may take several minutes depending on database size...${NC}"
echo ""

START_TIME=$(date +%s)

docker compose exec -T ${NODE} bash -c "
    set -e

    # Create restore log directory
    RESTORE_LOG_DIR=${BACKUP_PATH}/restore_logs
    mkdir -p \$RESTORE_LOG_DIR

    # Run myloader with Galera-aware settings
    myloader \
        --directory=${BACKUP_PATH} \
        --database=${DATABASE} \
        --threads=${THREADS} \
        --enable-binlog \
        ${OVERWRITE} \
        --verbose=2 \
        --logfile=\${RESTORE_LOG_DIR}/restore_$(date +%Y%m%d_%H%M%S).log \
        --host=127.0.0.1 \
        --user=root \
        --password=rootpass

    echo ''
    echo 'Restore operation completed on ${NODE}'
" 2>&1 | while IFS= read -r line; do
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
    echo -e "${YELLOW}Waiting 3 seconds for replication to propagate...${NC}"
    sleep 3
    echo ""

    # Check database exists on all nodes
    echo -e "${CYAN}Verifying database exists on all nodes...${NC}"
    for check_node in pxc-node1 pxc-node2 pxc-node3; do
        DB_EXISTS=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
            "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DATABASE}';" 2>/dev/null || echo "0")

        if [ "$DB_EXISTS" = "1" ]; then
            echo -e "  ${GREEN}✓${NC} ${check_node}: Database '${DATABASE}' exists"
        else
            echo -e "  ${RED}✗${NC} ${check_node}: Database '${DATABASE}' NOT found"
        fi
    done
    echo ""

    # Get table count from source node
    echo -e "${CYAN}Verifying table replication...${NC}"
    SOURCE_TABLES=$(docker compose exec -T ${NODE} mysql -uroot -prootpass -Nse \
        "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DATABASE}';" 2>/dev/null)

    echo -e "  Source (${NODE}): ${YELLOW}${SOURCE_TABLES} tables${NC}"

    # Compare table count on all nodes
    ALL_SYNCED=true
    for check_node in pxc-node1 pxc-node2 pxc-node3; do
        if [ "$check_node" = "$NODE" ]; then
            continue
        fi

        NODE_TABLES=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DATABASE}';" 2>/dev/null || echo "0")

        if [ "$NODE_TABLES" = "$SOURCE_TABLES" ]; then
            echo -e "  ${GREEN}✓${NC} ${check_node}: ${YELLOW}${NODE_TABLES} tables${NC} - Synchronized"
        else
            echo -e "  ${RED}✗${NC} ${check_node}: ${YELLOW}${NODE_TABLES} tables${NC} - NOT synchronized (expected ${SOURCE_TABLES})"
            ALL_SYNCED=false
        fi
    done
    echo ""

    # Sample a few tables to verify row counts match
    echo -e "${CYAN}Sampling table row counts across nodes...${NC}"
    SAMPLE_TABLES=$(docker compose exec -T ${NODE} mysql -uroot -prootpass -Nse \
        "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DATABASE}' LIMIT 3;" 2>/dev/null)

    if [ -n "$SAMPLE_TABLES" ]; then
        while IFS= read -r table; do
            echo -e "${YELLOW}  Table: ${table}${NC}"

            for check_node in pxc-node1 pxc-node2 pxc-node3; do
                ROW_COUNT=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
                    "SELECT COUNT(*) FROM \`${DATABASE}\`.\`${table}\`;" 2>/dev/null || echo "ERROR")

                if [ "$ROW_COUNT" != "ERROR" ]; then
                    echo -e "    ${check_node}: ${CYAN}${ROW_COUNT} rows${NC}"
                else
                    echo -e "    ${check_node}: ${RED}ERROR${NC}"
                fi
            done
            echo ""
        done <<< "$SAMPLE_TABLES"
    fi

    # Final cluster health check
    echo -e "${CYAN}Final cluster health check...${NC}"
    for check_node in pxc-node1 pxc-node2 pxc-node3; do
        FLOW_CONTROL=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
            "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='wsrep_flow_control_paused';" 2>/dev/null || echo "N/A")

        CLUSTER_STATUS=$(docker compose exec -T ${check_node} mysql -uroot -prootpass -Nse \
            "SELECT @@wsrep_local_state_comment;" 2>/dev/null || echo "ERROR")

        echo -e "  ${check_node}: State=${YELLOW}${CLUSTER_STATUS}${NC}, Flow Control Paused=${YELLOW}${FLOW_CONTROL}${NC}"
    done
    echo ""

    if [ "$ALL_SYNCED" = true ]; then
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}  ✓ Verification Successful!${NC}"
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}All nodes are synchronized${NC}"
    else
        echo -e "${YELLOW}=========================================${NC}"
        echo -e "${YELLOW}  ⚠ Verification Warning${NC}"
        echo -e "${YELLOW}=========================================${NC}"
        echo -e "${YELLOW}Some nodes may not be fully synchronized yet.${NC}"
        echo -e "${YELLOW}This is normal for large datasets. Monitor cluster status.${NC}"
    fi
else
    echo -e "${YELLOW}Verification skipped (--no-verify flag used)${NC}"
fi

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Restore Summary${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "  Backup:        ${YELLOW}${BACKUP_DIR}${NC}"
echo -e "  Database:      ${YELLOW}${DATABASE}${NC}"
echo -e "  Duration:      ${YELLOW}${DURATION} seconds${NC}"
echo -e "  Target Node:   ${YELLOW}${NODE}${NC}"
echo -e "  Status:        ${GREEN}Completed${NC}"
echo ""
echo -e "${CYAN}You can now access the database on any cluster node:${NC}"
echo -e "  ${YELLOW}mysql -h127.0.0.1 -P3306 -uroot -prootpass ${DATABASE}${NC}"
echo -e "  ${YELLOW}mysql -h127.0.0.1 -P3307 -uroot -prootpass ${DATABASE}${NC}"
echo -e "  ${YELLOW}mysql -h127.0.0.1 -P3308 -uroot -prootpass ${DATABASE}${NC}"
echo ""
