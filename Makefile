.PHONY: help setup start stop restart status clean destroy backup backup-logical restore-logical restore list-backups check-cluster load-test-db logs shell-node1 shell-node2 shell-node3

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
	@echo "$(GREEN)✓ Setup complete!$(NC)"

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

backup: ## Create XtraBackup of a database (use DATABASE=name to specify) [DEPRECATED - use backup-logical]
	@./scripts/backup.sh $(DATABASE)

backup-logical: ## Create logical backup with mydumper (use DATABASE=name, THREADS=N)
	@./scripts/backup-logical.sh $(DATABASE) --threads=$(THREADS)

restore-logical: ## Restore logical backup with myloader (use BACKUP=dir DATABASE=name THREADS=N)
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(RED)Error: BACKUP parameter is required$(NC)"; \
		echo ""; \
		echo "Usage: make restore-logical BACKUP=<backup_directory> [DATABASE=name] [THREADS=N]"; \
		echo ""; \
		echo "Example:"; \
		echo "  make restore-logical BACKUP=mydumper_employees_20250113_120000"; \
		echo "  make restore-logical BACKUP=mydumper_employees_20250113_120000 DATABASE=new_db"; \
		echo ""; \
		echo "Available backups:"; \
		docker compose exec -T pxc-node1 ls -1 /backups/ | grep mydumper_ || echo "No logical backups found"; \
		exit 1; \
	fi
	@./scripts/restore-logical.sh $(BACKUP) $(DATABASE) --threads=$(THREADS)

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
	@echo "$(CYAN)To restore a logical backup:$(NC)"
	@echo "  $(YELLOW)make restore-logical BACKUP=<backup_directory>$(NC)"
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
