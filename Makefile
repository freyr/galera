.PHONY: help setup start stop restart status clean destroy backup restore check-cluster load-test-db logs shell-node1 shell-node2 shell-node3

# Default target
.DEFAULT_GOAL := help

# Variables
BACKUP_DIR := ./backups
CONFIG_DIR := ./config
DATA_DIR := ./data
DATABASE ?= employees
BACKUP_TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)

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

backup: ## Create XtraBackup of a database (use DATABASE=name to specify)
	@./scripts/backup.sh $(DATABASE)

load-test-db: ## Download and load the test employees database
	@echo "$(GREEN)Loading test database (employees)...$(NC)"
	@if [ ! -d test_db-master ]; then \
		echo "$(YELLOW)Downloading test database...$(NC)"; \
		curl -L https://github.com/datacharmer/test_db/archive/refs/heads/master.zip -o test_db.zip; \
		unzip -q test_db.zip; \
		rm test_db.zip; \
	fi
	@echo "$(YELLOW)Importing database (this may take a few minutes)...$(NC)"
	@docker compose exec -T pxc-node1 mysql -uroot -prootpass < test_db-master/employees.sql
	@echo "$(GREEN)✓ Test database loaded successfully!$(NC)"

clean: ## Stop cluster and remove containers
	docker compose down

destroy: ## Stop cluster, remove containers and volumes (WARNING: deletes all data)
	docker compose down -v
	rm -rf $(DATA_DIR)
