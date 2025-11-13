# Configuration Comparison: release.cnf vs pxc.cnf

## Executive Summary

**Overall Assessment: release.cnf needs significant adjustments for non-production use**

- **Rating: 6/10** for non-production but important cluster
- The production config is highly optimized for specific hardware (SSD, 12.5GB RAM allocation)
- Several settings are production-heavy and should be scaled down
- Contains good production practices that should be retained
- Some deprecated/problematic settings need attention

---

## Detailed Comparison

### 1. Galera/PXC Configuration

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `pxc_strict_mode` | `ENFORCING` | `PERMISSIVE` | ✅ **ENFORCING is better** - More strict validation |
| `wsrep_provider` | `/opt/local/lib/...` | Auto-detected | ⚠️ **Hardcoded path** - Won't work in Docker |
| `wsrep_cluster_address` | Hardcoded IPs | Not set (Docker DNS) | ⚠️ **Need to adapt** - IPs vs hostnames |
| `wsrep_provider_options` | Extensive (4GB gcache) | Basic (512M gcache) | ⚠️ **Too aggressive for dev** - Need middle ground |

**Recommendation:** Use ENFORCING mode, but adjust gcache size to 1-2GB for non-prod.

---

### 2. InnoDB Configuration

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `innodb_buffer_pool_size` | **12500M** | 512M | 🔴 **Way too high** - Scale to 2-4GB for non-prod |
| `innodb_buffer_pool_instances` | 6 | Not set | ✅ **Good for large pools** - Use 4 instances if >2GB |
| `innodb_log_file_size` | 200M | 128M | ✅ **Reasonable** - 200M is fine |
| `innodb_flush_log_at_trx_commit` | **1** | 2 | ⚠️ **Trade-off** - 1=safe, 2=faster but less durable |
| `innodb_doublewrite` | **0** (disabled) | Default (on) | 🔴 **DANGEROUS** - Only for SSD with battery-backed cache |
| `innodb_checksum_algorithm` | **none** | Default | 🔴 **VERY RISKY** - Disables corruption detection! |
| `innodb_io_capacity` | 2500 | Default | ✅ **SSD optimized** - Use 1000-2000 for non-prod |
| `innodb_io_capacity_max` | 4000 | Default | ✅ **SSD optimized** |
| `innodb_flush_neighbors` | 0 | Default | ✅ **Good for SSD** |
| `innodb_use_native_aio` | **0** (disabled) | Default (on) | ⚠️ **Platform specific** - Was disabled for a reason |

**Critical Issues:**
- `innodb_doublewrite=0` - Disabled for performance but risks data corruption
- `innodb_checksum_algorithm=none` - **VERY DANGEROUS** - No corruption detection!

---

### 3. Query Cache

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `query_cache_size` | 536870912 (512MB) | 0 | 🤔 **Conflicting config** |
| `query_cache_type` | 0 (OFF) | 0 (OFF) | ✅ **Correct** - Should be OFF for Galera |

**Issue:** release.cnf allocates 512MB for query cache but then disables it! Wastes memory.

---

### 4. Connection & Thread Settings

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `max_connections` | 251 | 500 | ⚠️ **pxc.cnf is higher** - 251 is production tuned, probably sufficient |
| `thread_cache_size` | **1000** | 50 | 🔴 **Way too high** - 100-200 is reasonable |
| `wait_timeout` | 86400 (24h) | Default | ⚠️ **Very long** - Can leak connections |
| `back_log` | 64 | Default | ✅ **Reasonable** |

---

### 5. Temporary Tables & Memory

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `tmp_table_size` | 64M | Default | ✅ **Reasonable** |
| `max_heap_table_size` | 64M | Default | ✅ **Reasonable** |
| `sort_buffer_size` | 1M | Default | ✅ **Conservative, good** |
| `read_buffer_size` | 1M | Default | ✅ **Reasonable** |

---

### 6. Logging & Monitoring

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `slow_query_log` | 1 (ON) | 1 (ON) | ✅ **Both good** |
| `log_slow_filter` | Detailed filters | Not set | ✅ **Production has better filtering** |
| `log_slow_verbosity` | "full" | Not set | ✅ **Good for troubleshooting** |
| `long_query_time` | Not set (default 10s) | 2s | ✅ **pxc.cnf is better** - More sensitive |

---

### 7. Replication & GTID

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `binlog_format` | ROW | ROW | ✅ **Both correct** |
| `gtid_mode` | ON | Not set | ✅ **Good for external replication** |
| `enforce_gtid_consistency` | ON | Not set | ✅ **Required when GTID enabled** |
| `log_slave_updates` | ON | Not set | ✅ **Needed for chain replication** |
| `expire_logs_days` | 7 | Not set | ✅ **Good housekeeping** |

---

### 8. Character Sets

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `character-set-server` | utf8 | utf8mb4 | 🔴 **pxc.cnf is better** - utf8mb4 is proper UTF-8 |
| `collation_server` | Not set | utf8mb4_unicode_ci | ✅ **pxc.cnf has full emoji support** |

---

### 9. SQL Mode

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `sql_mode` | Custom (less strict) | Default (MySQL 5.7) | ⚠️ **Trade-off** - release is more lenient |

**Production sql_mode:** `NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION`

**Missing from production:**
- `STRICT_TRANS_TABLES` - Should be included for data integrity
- `NO_ENGINE_SUBSTITUTION` - Already included (good)

---

### 10. Hardware-Specific Paths

| Setting | release.cnf | pxc.cnf | Evaluation |
|---------|-------------|---------|------------|
| `datadir` | /ssd/datadir | Default | ⚠️ **SSD optimized** - Won't work in Docker |
| `innodb_data_file_path` | /ssd/... | Default | ⚠️ **Custom SSD paths** |
| `tmpdir` | /ssd/tmpdir | Default | ⚠️ **SSD optimized** |

---

## Critical Issues in release.cnf

### 🔴 DANGEROUS Settings (Fix Immediately)

1. **`innodb_checksum_algorithm=none`**
   - Disables corruption detection
   - **Risk:** Silent data corruption
   - **Fix:** Remove this setting (use default `crc32`)

2. **`innodb_doublewrite=0`**
   - Only safe with battery-backed RAID cache
   - **Risk:** Partial page writes can corrupt database
   - **Fix:** Set to `1` unless you have enterprise-grade hardware

3. **`query_cache_size=536870912` with `query_cache_type=0`**
   - Wastes 512MB of RAM
   - **Fix:** Set `query_cache_size=0` when type is 0

### ⚠️ Warning Settings (Review & Adjust)

4. **`innodb_buffer_pool_size=12500M`**
   - Way too high for non-production
   - **Recommendation:** 2-4GB for non-prod

5. **`thread_cache_size=1000`**
   - Excessive for 251 max connections
   - **Recommendation:** 100-200

6. **`wait_timeout=86400`** (24 hours)
   - Can leak connections
   - **Recommendation:** 3600-7200 (1-2 hours)

7. **`character-set-server=utf8`**
   - Should be `utf8mb4` for full Unicode support
   - **Risk:** Cannot store emojis, some Asian characters

### 🤔 Performance Trade-offs

8. **`innodb_flush_log_at_trx_commit=1`** (production) vs `2` (dev)
   - 1 = Full ACID compliance, slower
   - 2 = Faster, can lose 1 second of transactions
   - **Recommendation for non-prod:** Use `2` for better performance

9. **`innodb_use_native_aio=0`**
   - Disabled in production (probably for stability)
   - **Recommendation:** Test with it enabled in non-prod

---

## Recommended Non-Production Configuration

```ini
[mysqld]
# ============================================
# PXC 5.7 Configuration - Non-Production
# (Based on production, adjusted for dev/staging)
# ============================================

# ============================================
# Galera/PXC Settings
# ============================================
pxc_strict_mode=ENFORCING
innodb_autoinc_lock_mode=2
wsrep_sst_method=xtrabackup-v2
wsrep_sst_auth="sstuser:password"  # Change this!
wsrep_slave_threads=4

# Galera provider options - scaled for non-prod
wsrep_provider_options="gcache.size=2G;gcache.page_size=128M;gcache.keep_pages_count=2;gcache.keep_pages_size=512M;evs.suspect_timeout=PT8S;evs.inactive_timeout=PT25S;gcache.recover=yes"

# ============================================
# Storage Engine
# ============================================
default_storage_engine=innodb
character_set_server=utf8mb4
collation_server=utf8mb4_unicode_ci
skip_external_locking

# ============================================
# SQL Mode (include STRICT for data integrity)
# ============================================
sql_mode="STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"

# ============================================
# Query Cache (DISABLED for Galera)
# ============================================
query_cache_type=0
query_cache_size=0

# ============================================
# InnoDB Configuration (scaled for non-prod)
# ============================================
# Buffer pool - 2-4GB for non-prod (vs 12.5GB prod)
innodb_buffer_pool_size=3G
innodb_buffer_pool_instances=4

# Log files
innodb_log_file_size=200M
innodb_log_buffer_size=16M

# Flushing - relaxed for better performance
innodb_flush_log_at_trx_commit=2
innodb_flush_method=fsync

# Data integrity - KEEP ENABLED
innodb_doublewrite=1
innodb_checksum_algorithm=crc32

# Performance
innodb_file_per_table=1
innodb_io_capacity=1000
innodb_io_capacity_max=2000
innodb_read_io_threads=8
innodb_write_io_threads=8
innodb_lru_scan_depth=2048
innodb_max_dirty_pages_pct=75
innodb_adaptive_flushing=ON
innodb_flush_neighbors=0
innodb_lock_wait_timeout=50

# SSD optimizations (if using SSD)
innodb_log_write_ahead_size=16384

# ============================================
# Connection Settings
# ============================================
max_connections=300
thread_cache_size=150
wait_timeout=7200
back_log=64

# ============================================
# Buffer Sizes
# ============================================
sort_buffer_size=1M
read_buffer_size=1M
read_rnd_buffer_size=4M
myisam_sort_buffer_size=64M
key_buffer_size=256M

# ============================================
# Table Settings
# ============================================
open_files_limit=10240
table_open_cache=4096
table_definition_cache=1400

# ============================================
# Temporary Tables
# ============================================
tmp_table_size=64M
max_heap_table_size=64M

# ============================================
# Network
# ============================================
max_allowed_packet=64M
net_write_timeout=300
net_buffer_length=16K
thread_stack=256K

# ============================================
# Replication (for external slaves if needed)
# ============================================
binlog_format=ROW
expire_logs_days=7
slave_net_timeout=3600

# GTID for advanced replication (optional)
gtid_mode=ON
enforce_gtid_consistency=ON
log_slave_updates=ON
log_bin_trust_function_creators=1

# ============================================
# Logging
# ============================================
slow_query_log=1
slow_query_log_file=/var/log/mysql/slowquery.log
long_query_time=2
log_slow_filter="full_scan,tmp_table_on_disk,filesort_on_disk"
log_slow_verbosity="full"
log_error=/var/log/mysql/error.log
```

---

## Summary: What to Keep, Change, or Remove

### ✅ Keep from release.cnf
- `pxc_strict_mode=ENFORCING`
- InnoDB I/O settings (scaled down)
- Slow query logging with filters
- GTID configuration
- Advanced wsrep_provider_options structure

### 🔄 Change from release.cnf
- `innodb_buffer_pool_size`: 12500M → 2-4G
- `thread_cache_size`: 1000 → 150
- `wait_timeout`: 86400 → 7200
- `character-set-server`: utf8 → utf8mb4
- `innodb_flush_log_at_trx_commit`: 1 → 2
- `gcache.size`: 4G → 2G

### 🔴 Remove/Fix from release.cnf
- `innodb_checksum_algorithm=none` → Remove (use default)
- `innodb_doublewrite=0` → Set to 1
- `query_cache_size=536870912` → Set to 0
- Hardware-specific paths (won't work in Docker)
- `innodb_use_native_aio=0` → Test with default (enabled)

### ✅ Keep from pxc.cnf
- Simplified approach
- utf8mb4 character set
- Query cache properly disabled
- Lower buffer pool for dev

---

## Final Recommendation

**For a non-production but relatively important cluster:**

1. **Start with the recommended config above** (middle ground between prod and dev)
2. **Monitor resource usage** and adjust buffer pool size accordingly
3. **Enable data integrity features** (doublewrite, checksums) - don't sacrifice safety for speed
4. **Use relaxed durability** (`innodb_flush_log_at_trx_commit=2`) for better performance
5. **Keep advanced monitoring** (slow query filters, verbosity)
6. **Test thoroughly** before promoting any config to production

**Rating Breakdown:**
- Production optimization: 9/10 (excellent for specific hardware)
- Non-prod suitability: 6/10 (needs significant scaling down)
- Data safety: 4/10 (critical issues with checksums and doublewrite)
- Docker compatibility: 3/10 (hardcoded paths won't work)
