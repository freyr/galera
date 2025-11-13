# Quick Start: PMM Monitoring

## 1️⃣ Start Everything

```bash
make start
```

Starts the Galera cluster (3 nodes) + PMM Server + PMM Clients

## 2️⃣ Register Nodes with PMM

```bash
make pmm-setup
```

Registers all 3 PXC nodes with PMM for monitoring

## 3️⃣ Access PMM Dashboard

```bash
make pmm-open
```

Or open: **https://localhost:8443**

Login:
- **Username**: `admin`
- **Password**: `admin`

⚠️ **Change password after first login!**

## 4️⃣ View Galera Metrics

In PMM UI:
1. Go to **Dashboards** → **MySQL** → **MySQL Cluster Summary**
2. View your 3-node cluster metrics
3. Check **wsrep_cluster_status** (should be "Primary")
4. Monitor replication lag and conflicts

## Key Dashboards

- **MySQL Cluster Summary**: Overview of all nodes
- **MySQL Instance Summary**: Per-node details
- **Query Analytics**: Slow query analysis

## Useful Commands

```bash
make pmm-status   # Check PMM health
make status       # Check Galera cluster status
make help         # See all commands
```

## What PMM Monitors

✅ Galera cluster health (wsrep_* metrics)
✅ Flow control and replication lag
✅ Certification conflicts
✅ Query performance (QAN)
✅ InnoDB metrics
✅ Resource usage (CPU, memory, disk)

## Troubleshooting

**PMM not loading?**
```bash
docker compose logs pmm-server
make pmm-status
```

**Nodes not showing?**
```bash
make pmm-setup  # Re-register nodes
```

For detailed documentation, see: **PMM_SETUP.md**
