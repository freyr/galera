# PMM (Percona Monitoring and Management) Setup Guide

## Overview

This Galera cluster includes **PMM 3** for comprehensive monitoring and management of your Percona XtraDB Cluster.

## What PMM Provides

### Galera-Specific Monitoring
- **wsrep_* metrics**: Cluster size, status, replication lag
- **Flow control**: Detection of slow nodes affecting cluster
- **Certification conflicts**: Failed writes due to conflicts
- **SST/IST monitoring**: State transfer tracking
- **Node health**: Individual node performance and status

### General MySQL Monitoring
- **Query Analytics (QAN)**: Slow query tracking and analysis
- **Performance Schema**: Detailed performance metrics
- **InnoDB metrics**: Buffer pool, transactions, locks
- **Replication**: GTID position, lag monitoring
- **Resource usage**: CPU, memory, disk I/O

## Quick Start

### 1. Start the Cluster with PMM

```bash
make start
```

This starts:
- 3 PXC nodes (pxc-node1, pxc-node2, pxc-node3)
- 1 PMM Server (pmm-server)
- 3 PMM Client agents (one per node)

### 2. Setup PMM Monitoring

After the cluster is running, register the nodes with PMM:

```bash
make pmm-setup
```

This will:
- Wait for PMM Server to be ready
- Register all 3 PXC nodes with PMM
- Enable Query Analytics
- Configure Performance Schema monitoring

### 3. Access PMM

```bash
make pmm-open
```

Or open manually: `https://localhost:8443`

**Default Credentials:**
- Username: `admin`
- Password: `admin`

⚠️ **Important:** Change the password after first login!

## Available Makefile Commands

| Command | Description |
|---------|-------------|
| `make pmm-setup` | Register all nodes with PMM (run after first start) |
| `make pmm-open` | Open PMM web interface in browser |
| `make pmm-status` | Check if PMM server is healthy |

## PMM Dashboards

Once logged in, navigate to these key dashboards:

### For Galera Monitoring:
1. **Home Dashboard** → **MySQL** → **MySQL Cluster Summary**
   - Overview of all cluster nodes
   - wsrep metrics
   - Replication status

2. **Home Dashboard** → **MySQL** → **MySQL Instance Summary**
   - Per-node detailed metrics
   - InnoDB statistics
   - Query performance

3. **Home Dashboard** → **PMM Query Analytics (QAN)**
   - Slow query analysis
   - Query fingerprints
   - Execution patterns

### Key Metrics to Watch

#### Cluster Health
- **wsrep_cluster_status**: Should always be "Primary"
- **wsrep_cluster_size**: Should be "3"
- **wsrep_local_state_comment**: Should be "Synced"
- **wsrep_ready**: Should be "ON"

#### Performance Issues
- **wsrep_flow_control_paused**: High values indicate slow nodes
- **wsrep_cert_deps_distance**: High values indicate transaction conflicts
- **wsrep_local_recv_queue_avg**: Should be close to 0
- **wsrep_local_cert_failures**: Track certification failures
- **wsrep_local_bf_aborts**: Track aborted transactions

## Ports

- **8443**: PMM Web UI (HTTPS)
- **8080**: PMM API (HTTP)

## Data Persistence

PMM Server data is stored in Docker volume `pmm-server-data`:
- Historical metrics
- Dashboard configurations
- User settings
- Query Analytics data

## Troubleshooting

### PMM Server not starting

Check logs:
```bash
docker compose logs pmm-server
```

Check health:
```bash
make pmm-status
```

### Nodes not appearing in PMM

Re-run setup:
```bash
make pmm-setup
```

Check client logs:
```bash
docker compose logs pmm-client-node1
docker compose logs pmm-client-node2
docker compose logs pmm-client-node3
```

### Can't access PMM UI

1. Verify PMM is running:
```bash
docker compose ps | grep pmm
```

2. Check if port 8443 is accessible:
```bash
curl -k https://localhost:8443
```

3. Check firewall settings if accessing remotely

### Reset PMM Password

If you forgot the admin password:

```bash
# Stop PMM
docker compose stop pmm-server

# Remove PMM data volume (WARNING: loses historical data)
docker volume rm galera_pmm-server-data

# Restart PMM
docker compose up -d pmm-server

# Re-setup monitoring
make pmm-setup
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│              PMM Server (pmm-server)            │
│                                                 │
│  - Web UI (Grafana): Port 8443                 │
│  - API Server: Port 8080                       │
│  - Victoria Metrics (Time Series DB)           │
│  - PostgreSQL (QAN Storage)                    │
│  - ClickHouse (Query Analytics)                │
└─────────────────────────────────────────────────┘
                        ▲
                        │ Metrics & Queries
           ┌────────────┼────────────┐
           │            │            │
      ┌────▼───┐   ┌────▼───┐   ┌───▼────┐
      │ PMM    │   │ PMM    │   │ PMM    │
      │ Client │   │ Client │   │ Client │
      │ Node 1 │   │ Node 2 │   │ Node 3 │
      └────┬───┘   └────┬───┘   └────┬───┘
           │            │            │
      ┌────▼───┐   ┌────▼───┐   ┌───▼────┐
      │ PXC    │   │ PXC    │   │ PXC    │
      │ Node 1 │◄──│ Node 2 │◄──│ Node 3 │
      │ :3306  │   │ :3307  │   │ :3308  │
      └────────┘   └────────┘   └────────┘
```

## Configuration Details

### PMM Server
- Image: `percona/pmm-server:3`
- Data volume: `pmm-server-data`
- Telemetry: Disabled (`DISABLE_TELEMETRY=1`)

### PMM Clients
- Image: `percona/pmm-client:2`
- One client per PXC node
- Auto-registration with server
- Query source: Performance Schema
- Cluster name: `pxc-cluster`

## Security Considerations

For **production** environments:

1. **Change default credentials** immediately
2. **Enable TLS** for PMM Server (requires certificate configuration)
3. **Use strong passwords** for MySQL monitoring user
4. **Restrict network access** to PMM ports (8443, 8080)
5. **Regular updates**: Keep PMM Server and Clients updated
6. **Backup PMM data**: Volume `pmm-server-data` contains historical data

## Resource Usage

PMM Server typical resource usage:
- **CPU**: 1-2 cores
- **Memory**: 2-4 GB RAM
- **Disk**: Grows over time (metrics retention)

PMM Client per node:
- **CPU**: < 0.5 core
- **Memory**: 100-200 MB

## Advanced Features

### Custom Alerts

PMM 3 supports alerting via Grafana Alerting:
1. Navigate to **Alerting** → **Alert rules**
2. Create rules for critical Galera metrics
3. Configure notification channels (email, Slack, etc.)

### API Access

PMM provides REST API for automation:
```bash
# Example: Get server version
curl -k https://admin:admin@localhost:8443/v1/version
```

### Query Analytics Deep Dive

Access QAN for detailed query analysis:
1. Click **PMM** → **Query Analytics**
2. Filter by node, time range, or query pattern
3. Identify slow queries affecting cluster performance
4. Analyze query execution plans

## References

- [PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [PMM Docker Setup](https://docs.percona.com/percona-monitoring-and-management/3/install-pmm/install-pmm-server/deployment-options/docker/)
- [Galera Monitoring Guide](https://galeracluster.com/library/documentation/monitoring-cluster.html)
