#!/bin/bash

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Percona XtraDB Cluster Status${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

for node in pxc-node1 pxc-node2 pxc-node3; do
    echo "╔════════════════════════════════════════╗"
    echo "║  ${node}"
    echo "╚════════════════════════════════════════╝"

    docker compose exec -T ${node} mysql -uroot -prootpass -e "
        SELECT
            VARIABLE_NAME as Metric,
            VARIABLE_VALUE as Value
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME IN (
            'wsrep_cluster_status',
            'wsrep_cluster_size',
            'wsrep_local_state_comment',
            'wsrep_connected',
            'wsrep_ready',
            'wsrep_flow_control_paused',
            'wsrep_local_recv_queue_avg',
            'wsrep_cert_deps_distance'
        )
        ORDER BY VARIABLE_NAME;
    " 2>/dev/null || echo -e "${RED}Node not ready${NC}"

    echo ""
done

echo -e "${CYAN}Expected values:${NC}"
echo "  wsrep_cluster_status: Primary"
echo "  wsrep_cluster_size: 3"
echo "  wsrep_local_state_comment: Synced"
echo "  wsrep_ready: ON"
echo ""
