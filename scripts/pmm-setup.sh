#!/bin/bash
set -e

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Registering PXC Nodes with PMM${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Wait for PMM Server to be ready
echo -e "${YELLOW}Waiting for PMM Server to be ready...${NC}"
timeout=60
while [ $timeout -gt 0 ]; do
    if docker compose exec -T pmm-server curl -sf http://localhost:8080/v1/readyz > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PMM Server is ready!${NC}"
        break
    fi
    sleep 2
    timeout=$((timeout - 2))
done

if [ $timeout -le 0 ]; then
    echo -e "${RED}✗ PMM Server failed to start${NC}"
    exit 1
fi

# Configure pmm-agent with proper credentials
echo -e "${YELLOW}Configuring PMM Agent...${NC}"
docker compose exec -T pmm-server bash -c "
    sed -i 's/username: \"\"/username: \"admin\"/' /usr/local/percona/pmm/config/pmm-agent.yaml 2>/dev/null || true
    sed -i 's/password: \"\"/password: \"admin\"/' /usr/local/percona/pmm/config/pmm-agent.yaml 2>/dev/null || true
    sed -i 's/username: admin/username: \"admin\"/' /usr/local/percona/pmm/config/pmm-agent.yaml 2>/dev/null || true
    sed -i 's/password: admin/password: \"admin\"/' /usr/local/percona/pmm/config/pmm-agent.yaml 2>/dev/null || true
" > /dev/null 2>&1

# Restart pmm-agent to apply changes
docker compose exec -T pmm-server supervisorctl restart pmm-agent > /dev/null 2>&1
sleep 3
echo -e "${GREEN}✓ PMM Agent configured${NC}"

echo ""
echo -e "${YELLOW}Creating PMM monitoring user on all PXC nodes...${NC}"

# Create PMM user on all nodes
for node in pxc-node1 pxc-node2 pxc-node3; do
    echo -e "${CYAN}Creating PMM user on ${node}...${NC}"
    docker compose exec -T ${node} mysql -uroot -prootpass -e "
        CREATE USER IF NOT EXISTS 'pmm'@'%' IDENTIFIED BY 'pmmpass';
        GRANT SELECT, PROCESS, REPLICATION CLIENT, RELOAD, BACKUP_ADMIN ON *.* TO 'pmm'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null && echo -e "${GREEN}  ✓ PMM user created${NC}" || echo -e "${YELLOW}  (User may already exist)${NC}"
done

echo ""
echo -e "${YELLOW}Registering PXC nodes with PMM Server...${NC}"

# Function to register a MySQL node
register_node() {
    local node_name=$1
    local node_host=$2

    echo -e "${CYAN}Registering ${node_name}...${NC}"

    # Add MySQL service using pmm-admin
    result=$(docker compose exec -T pmm-server pmm-admin add mysql \
        --username=pmm \
        --password=pmmpass \
        --host=${node_host} \
        --port=3306 \
        --service-name=${node_name} \
        --cluster=pxc-cluster \
        --environment=dev \
        --query-source=perfschema \
        ${node_name} ${node_host}:3306 2>&1 || true)

    if echo "$result" | grep -q "Service added"; then
        echo -e "${GREEN}  ✓ Registered${NC}"
    elif echo "$result" | grep -q "already exists\|already added"; then
        echo -e "${YELLOW}  (Already registered)${NC}"
    else
        echo -e "${RED}  ✗ Failed${NC}"
        echo "$result" | head -2
    fi
}

# Register all nodes
register_node "pxc-node1" "pxc-node1"
register_node "pxc-node2" "pxc-node2"
register_node "pxc-node3" "pxc-node3"

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Node Registration Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "Access PMM at: ${CYAN}https://localhost:8443${NC}"
echo -e "Username: ${YELLOW}admin${NC}"
echo -e "Password: ${YELLOW}admin${NC}"
echo ""
echo -e "${YELLOW}Wait a few minutes for metrics to start appearing in PMM dashboards.${NC}"
echo ""
