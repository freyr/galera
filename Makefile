.PHONY: help setup start stop restart status clean destroy backup restore backup-cluster restore-cluster list-backups check-cluster load-test-db logs shell-node1 shell-node2 shell-node3

# Default target
.DEFAULT_GOAL := help

# Variables
BACKUP_DIR := ./backups
CONFIG_DIR := ./config
DATA_DIR := ./data
DATABASE ?= employees
BACKUP ?=
BACKUP_TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
THREADS ?= 4

# Colors for output
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

help: ## Show this help message
	@echo "$(CYAN)=========================================$(NC)"
	@echo "$(CYAN)  Percona XtraDB Cluster 5.7 - Makefile$(NC)"
	@echo "$(CYAN)=========================================$(NC)"
	@echo ""
	@echo "$(GREEN)Available targets:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""

setup: ## Initialize directories and configuration
	@echo "$(GREEN)Setting up Percona XtraDB Cluster environment...$(NC)"
	@mkdir -p $(CONFIG_DIR) $(BACKUP_DIR) $(DATA_DIR)/{pxc-node1,pxc-node2,pxc-node3}
	@if [ ! -f $(CONFIG_DIR)/pxc.cnf ]; then \
		echo "$(YELLOW)Configuration file not found. Please ensure config/pxc.cnf exists.$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Building backup-tools container...$(NC)"
	@docker compose build backup-tools
	@echo "$(GREEN)✓ Setup complete!$(NC)"

start: setup ## Start the cluster
	docker compose up -d
	@echo "$(GREEN)Cluster is starting...$(NC)"
	@echo "$(YELLOW)Waiting for nodes to be ready...$(NC)"
	@sleep 10
	@./scripts/status.sh || true

stop: ## Stop the cluster
	docker compose stop

restart: ## Restart the cluster
	docker compose restart

status: ## Show cluster status
	@./scripts/status.sh

logs: ## Show logs from all nodes
	@docker compose logs -f

shell-node1: ## Open MySQL shell on node 1
	@docker compose exec pxc-node1 mysql -uroot -prootpass

shell-node2: ## Open MySQL shell on node 2
	@docker compose exec pxc-node2 mysql -uroot -prootpass

shell-node3: ## Open MySQL shell on node 3
	@docker compose exec pxc-node3 mysql -uroot -prootpass

backup: ## Create logical backup with mydumper using tools container (use DATABASE=name, THREADS=N)
	@echo "$(CYAN)Using backup-tools container for backup...$(NC)"
	@docker compose exec -T backup-tools bash -c "\
		MYSQL_HOST=pxc-node1 MYSQL_PORT=3306 \
		/scripts/backup.sh $(DATABASE) --threads=$(THREADS)"

restore: ## Restore logical backup with myloader using tools container (use BACKUP=dir DATABASE=name THREADS=N)
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(RED)Error: BACKUP parameter is required$(NC)"; \
		echo ""; \
		echo "Usage: make restore BACKUP=<backup_directory> [DATABASE=name] [THREADS=N]"; \
		echo ""; \
		echo "Example:"; \
		echo "  make restore BACKUP=mydumper_employees_20250113_120000"; \
		echo "  make restore BACKUP=mydumper_employees_20250113_120000 DATABASE=new_db"; \
		echo ""; \
		echo "Available backups:"; \
		ls -1 ./backups/ 2>/dev/null | grep mydumper_ || echo "No logical backups found"; \
		exit 1; \
	fi
	@echo "$(CYAN)Using backup-tools container for restore...$(NC)"
	@docker compose exec -T backup-tools bash -c "\
		MYSQL_HOST=pxc-node1 MYSQL_PORT=3306 \
		GALERA_NODES=pxc-node1:3306,pxc-node2:3306,pxc-node3:3306 \
		/scripts/restore.sh $(BACKUP) $(DATABASE) --threads=$(THREADS) --overwrite"

backup-cluster: ## Create XtraBackup of entire cluster (physical backup - for full cluster recovery)
	@./scripts/backup-cluster.sh $(DATABASE)

restore-cluster: ## Restore XtraBackup cluster backup (use BACKUP=dir) - Shows manual instructions
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(RED)Error: BACKUP parameter is required$(NC)"; \
		echo ""; \
		echo "Usage: make restore-cluster BACKUP=<backup_directory>"; \
		echo ""; \
		echo "Example:"; \
		echo "  make restore-cluster BACKUP=xtrabackup_20250113_120000"; \
		echo ""; \
		echo "Available XtraBackup backups:"; \
		docker compose exec -T pxc-node1 ls -1 /backups/ | grep xtrabackup_ || echo "No XtraBackup backups found"; \
		exit 1; \
	fi
	@./scripts/restore-cluster.sh $(BACKUP)

list-backups: ## List all available backups (both XtraBackup and logical)
	@echo "$(CYAN)=========================================$(NC)"
	@echo "$(CYAN)  Available Backups$(NC)"
	@echo "$(CYAN)=========================================$(NC)"
	@echo ""
	@echo "$(GREEN)XtraBackup (Physical) Backups:$(NC)"
	@docker compose exec -T pxc-node1 bash -c "ls -1dh /backups/xtrabackup_* 2>/dev/null | xargs -I {} basename {} | while read dir; do echo '  $(YELLOW)'\$$dir'$(NC)'; done" || echo "  $(YELLOW)No XtraBackup backups found$(NC)"
	@echo ""
	@echo "$(GREEN)MyDumper (Logical) Backups:$(NC)"
	@docker compose exec -T pxc-node1 bash -c "ls -1dh /backups/mydumper_* 2>/dev/null | xargs -I {} basename {} | while read dir; do echo '  $(YELLOW)'\$$dir'$(NC)'; done" || echo "  $(YELLOW)No logical backups found$(NC)"
	@echo ""
	@echo "$(CYAN)To restore a backup:$(NC)"
	@echo "  $(YELLOW)make restore BACKUP=<backup_directory>$(NC)"
	@echo ""

pmm-setup: ## Setup PMM monitoring for all nodes
	@./scripts/pmm-setup.sh

pmm-open: ## Open PMM web interface
	@echo "$(CYAN)Opening PMM at https://localhost:8443${NC}"
	@echo "Username: admin"
	@echo "Password: admin"
	@open https://localhost:8443 || xdg-open https://localhost:8443 || echo "Please open https://localhost:8443 in your browser"

pmm-status: ## Check PMM server status
	@echo "$(CYAN)PMM Server Status:${NC}"
	@docker compose exec -T pmm-server curl -s http://localhost:8080/v1/readyz && echo "$(GREEN)✓ PMM Server is healthy${NC}" || echo "$(RED)✗ PMM Server is not ready${NC}"

load-test-db: ## Download and load the test employees database
	@echo "$(GREEN)Loading test database (employees)...$(NC)"
	@if [ ! -d test_db-master ]; then \
		echo "$(YELLOW)Downloading test database...$(NC)"; \
		curl -L https://github.com/datacharmer/test_db/archive/refs/heads/master.zip -o test_db.zip; \
		unzip -q test_db.zip; \
		rm test_db.zip; \
	fi
	@echo "$(YELLOW)Copying test database files to container...$(NC)"
	@docker compose exec -T pxc-node1 mkdir -p /tmp/test_db
	@docker cp test_db-master/. galera-pxc-node1-1:/tmp/test_db/
	@echo "$(YELLOW)Importing database (this may take a few minutes)...$(NC)"
	@docker compose exec -T pxc-node1 bash -c "cd /tmp/test_db && mysql -uroot -prootpass < employees.sql"
	@docker compose exec -T pxc-node1 rm -rf /tmp/test_db 2>/dev/null || true
	@echo "$(GREEN)✓ Test database loaded successfully!$(NC)"

clean: ## Stop cluster and remove containers
	docker compose down

destroy: ## Stop cluster, remove containers and volumes (WARNING: deletes all data)
	docker compose down -v
	rm -rf $(DATA_DIR)
