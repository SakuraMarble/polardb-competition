#!/bin/bash

# default configuration
# user: "postgres"
# database: "postgres"
# host: "localhost"
# primary port: "5432"
pg_user=postgres
pg_database=postgres
pg_host=~/tmp_master_dir_polardb_pg_1100_bld 
pg_port=5432
clean=
tpch_dir=tpch-dbgen
data_dir=../Data1

# 提升 nice 权限
chmod u+s /usr/bin/nice

# 将 postgres 用户加入 root 组
usermod -a -G root postgres

usage () {
cat <<EOF

  1) Use default configuration to run tpch_copy
  ./tpch_copy.sh
  2) Use limited configuration to run tpch_copy
  ./tpch_copy.sh --user=postgres --db=postgres --host=localhost --port=5432
  3) Clean the test data. This step will drop the database or tables.
  ./tpch_copy.sh --clean

EOF
  exit 0;
}

for arg do
  val=`echo "$arg" | sed -e 's;^--[^=]*=;;'`

  case "$arg" in
    --user=*)                   pg_user="$val";;
    --db=*)                     pg_database="$val";;
    --host=*)                   pg_host="$val";;
    --port=*)                   pg_port="$val";;
    --clean)                    clean=on ;;
    -h|--help)                  usage ;;
    *)                          echo "wrong options : $arg";
                                exit 1
                                ;;
  esac
done

export PGPORT=$pg_port
export PGHOST=$pg_host
export PGDATABASE=$pg_database
export PGUSER=$pg_user

# clean the tpch test data
if [[ $clean == "on" ]];
then
  make clean
  if [[ $pg_database == "postgres" ]];
  then
    echo "drop all the tpch tables"
    psql -c "drop table customer cascade"
    psql -c "drop table lineitem cascade"
    psql -c "drop table nation cascade"
    psql -c "drop table orders cascade"
    psql -c "drop table part cascade"
    psql -c "drop table partsupp cascade"
    psql -c "drop table region cascade"
    psql -c "drop table supplier cascade"
  else
    echo "drop the tpch database: $PGDATABASE"
    psql -c "drop database $PGDATABASE" -d postgres
  fi
  exit;
fi


###################### PHASE 1: Create Database and Tables ######################
# 并行度 N
N=7
if [[ $PGDATABASE != "postgres" ]];
then
  echo "create the tpch database: $PGDATABASE"
  psql -c "create database $PGDATABASE" -d postgres
fi

# 启用 PolarDB 预分配功能
echo "Configuring PolarDB pre-allocation settings..."
psql -c "ALTER SYSTEM SET polar_bulk_read_size = '128kB';"
psql -c "ALTER SYSTEM SET polar_bulk_extend_size = '4MB';"  
psql -c "ALTER SYSTEM SET polar_index_create_bulk_extend_size = 512;"  
psql -c "ALTER SYSTEM SET max_parallel_workers = 8;"  
psql -c "ALTER SYSTEM SET max_parallel_workers_per_gather = 4;"  
psql -c "ALTER SYSTEM SET shared_buffers = '8GB';"  
# psql -c "ALTER SYSTEM SET autovacuum = 'off' ;"  
# psql -c "ALTER SYSTEM SET maintenance_work_mem='256MB';"  
psql -c "ALTER SYSTEM SET checkpoint_timeout='30min';"
psql -c "ALTER SYSTEM SET checkpoint_completion_target = 0.9;" 
psql -c "ALTER SYSTEM SET wal_level = 'minimal';"  
psql -c "ALTER SYSTEM SET max_wal_senders = 0;"  
psql -c "ALTER SYSTEM SET synchronous_standby_names = '';"  
psql -c "ALTER SYSTEM SET hot_standby = 'off';"
psql -c "ALTER SYSTEM SET archive_mode = 'off';"
psql -c "ALTER SYSTEM SET wal_log_hints = 'off';"
psql -c "ALTER SYSTEM SET max_replication_slots = 0;"
psql -c "ALTER SYSTEM SET fsync=off;"
psql -c "ALTER SYSTEM SET synchronous_commit = 'off';"
psql -c "ALTER SYSTEM SET full_page_writes=off;"
psql -c "ALTER SYSTEM SET wal_buffers='64MB';"
# psql -c "ALTER SYSTEM SET work_mem='100MB';"
psql -c "ALTER SYSTEM SET wal_writer_delay='1000ms';" 
psql -c "ALTER SYSTEM SET max_wal_size='4GB';" 
psql -c "ALTER SYSTEM SET commit_delay=500;" 
psql -c "ALTER SYSTEM SET wal_writer_flush_after='16MB';" 
psql -c "ALTER SYSTEM SET commit_siblings=10;" 

# psql -c "ALTER SYSTEM SET wal_writer_flush_after=128KB;" default
# ALTER SYSTEM SET wal_level='minimal';
# ALTER SYSTEM SET max_wal_senders=0;
# ALTER SYSTEM SET work_mem='100MB'
# ALTER SYSTEM SET synchronous_commit = off;
# alter system set maintenance_work_mem='256MB';
# alter system set wal_buffers='50MB';
# alter system set max_wal_size='5GB';
# alter system set wal_writer_delay=1000; （1秒）
# alter system set wal_writer_flush_after=10240;
# alter system set commit_delay=1000;
# alter system set commit_siblings=6;
# alter system set checkpoint_timeout=1800
# echo "Loading table definitions..."
psql -f "$tpch_dir/dss.ddl"
psql -c "update pg_class set relpersistence ='u' where relnamespace='public'::regnamespace;" 
psql -c "SELECT pg_reload_conf();" 

# ===================== PHASE 2: Load Data with Index Creation =====================

# Split the 'lineitem' table into 20 parts
split -n l/50 "$data_dir/lineitem.tbl" "$data_dir/lineitem_split_"

# Split the 'orders' table into 10 parts
split -n l/15 "$data_dir/orders.tbl" "$data_dir/orders_split_"

# 并行运行函数
run_parallel() {
  local max_jobs=$1
  shift
  local commands=("$@")
  local job_count=0

  for cmd in "${commands[@]}"; do
    eval "$cmd" &
    ((job_count++))

    if (( job_count >= max_jobs )); then
      wait -n
      ((job_count--))
    fi
  done

  wait
}

# 准备 COPY 和索引创建命令列表
copy_and_index_commands=()

# 'lineitem' 表的数据导入和索引创建
for i in {a..d}; do
  for j in {a..z}; do
    part="lineitem_split_${i}${j}"
    if [[ -f "$data_dir/$part" ]]; then
      copy_and_index_commands+=("psql -c \"\\COPY lineitem FROM '$data_dir/$part' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_lineitem_l_orderkey ON lineitem (l_orderkey);\"")
    fi
  done
done

# 'orders' 表的数据导入和索引创建
for i in {a..b}; do
  for j in {a..z}; do
    part="orders_split_${i}${j}"
    if [[ -f "$data_dir/$part" ]]; then
      copy_and_index_commands+=("psql -c \"\\COPY orders FROM '$data_dir/$part' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_o_orderkey ON orders (o_orderkey);\"")
    fi
  done
done

# 'partsupp' 和其他表
copy_and_index_commands+=("psql -c \"\\COPY partsupp FROM '$data_dir/partsupp.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_partsupp_ps_partkey ON partsupp (ps_partkey, ps_suppkey);\"")

copy_and_index_commands+=("psql -c \"\\COPY part FROM '$data_dir/part.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_part_p_partkey ON part (p_partkey);\"")

copy_and_index_commands+=("psql -c \"\\COPY customer FROM '$data_dir/customer.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customer_c_custkey ON customer (c_custkey);\"")

copy_and_index_commands+=("psql -c \"\\COPY supplier FROM '$data_dir/supplier.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_supplier_s_suppkey ON supplier (s_suppkey);\"")

copy_and_index_commands+=("psql -c \"\\COPY nation FROM '$data_dir/nation.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_nation_n_nationkey ON nation (n_nationkey);\"")

copy_and_index_commands+=("psql -c \"\\COPY region FROM '$data_dir/region.tbl' WITH (FORMAT csv, DELIMITER '|');\" && \
psql -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_region_r_regionkey ON region (r_regionkey);\"")

# 并行运行导入和索引创建
run_parallel 8 "${copy_and_index_commands[@]}"

echo "数据导入和索引创建完成。"
# ===================== PHASE 3: Add Primary Keys and Foreign Keys =====================

# 提升内存配置以优化索引创建
psql -c "ALTER SYSTEM SET maintenance_work_mem = '4GB';"
psql -c "SELECT pg_reload_conf();"

# 准备主键和外键创建命令列表
commands=()

# Command 1: ORDERS 主键和 LINEITEM 的外键
commands+=("psql -c \"ALTER TABLE ORDERS ADD PRIMARY KEY (O_ORDERKEY) USING INDEX idx_orders_o_orderkey;\" && \
psql -c \"ALTER TABLE LINEITEM ADD FOREIGN KEY (L_ORDERKEY) REFERENCES ORDERS (O_ORDERKEY) NOT VALID;\"")

# Command 2: PARTSUPP 主键和 LINEITEM 的外键
commands+=("psql -c \"ALTER TABLE PARTSUPP ADD PRIMARY KEY (PS_PARTKEY, PS_SUPPKEY) USING INDEX idx_partsupp_ps_partkey;\" && \
psql -c \"ALTER TABLE LINEITEM ADD FOREIGN KEY (L_PARTKEY, L_SUPPKEY) REFERENCES PARTSUPP (PS_PARTKEY, PS_SUPPKEY) NOT VALID;\"")

# Command 3: LINEITEM 主键
commands+=("psql -c \"ALTER TABLE LINEITEM ADD PRIMARY KEY (L_ORDERKEY, L_LINENUMBER) USING INDEX idx_lineitem_l_orderkey;\"")

# Command 4: CUSTOMER 主键和 ORDERS 的外键
commands+=("psql -c \"ALTER TABLE CUSTOMER ADD PRIMARY KEY (C_CUSTKEY) USING INDEX idx_customer_c_custkey;\" && \
psql -c \"ALTER TABLE ORDERS ADD FOREIGN KEY (O_CUSTKEY) REFERENCES CUSTOMER (C_CUSTKEY) NOT VALID;\"")

# Command 5: PART 主键和 PARTSUPP 的外键
commands+=("psql -c \"ALTER TABLE PART ADD PRIMARY KEY (P_PARTKEY) USING INDEX idx_part_p_partkey;\" && \
psql -c \"ALTER TABLE PARTSUPP ADD FOREIGN KEY (PS_PARTKEY) REFERENCES PART (P_PARTKEY) NOT VALID;\"")

# Command 6: SUPPLIER 主键和 PARTSUPP 的外键
commands+=("psql -c \"ALTER TABLE SUPPLIER ADD PRIMARY KEY (S_SUPPKEY) USING INDEX idx_supplier_s_suppkey;\" && \
psql -c \"ALTER TABLE PARTSUPP ADD FOREIGN KEY (PS_SUPPKEY) REFERENCES SUPPLIER (S_SUPPKEY) NOT VALID;\"")

# Command 7: NATION 主键及 SUPPLIER 和 CUSTOMER 的外键
commands+=("psql -c \"ALTER TABLE NATION ADD PRIMARY KEY (N_NATIONKEY) USING INDEX idx_nation_n_nationkey;\" && \
psql -c \"ALTER TABLE SUPPLIER ADD FOREIGN KEY (S_NATIONKEY) REFERENCES NATION (N_NATIONKEY) NOT VALID;\" && \
psql -c \"ALTER TABLE CUSTOMER ADD FOREIGN KEY (C_NATIONKEY) REFERENCES NATION (N_NATIONKEY) NOT VALID;\"")

# Command 8: REGION 主键和 NATION 的外键
commands+=("psql -c \"ALTER TABLE REGION ADD PRIMARY KEY (R_REGIONKEY) USING INDEX idx_region_r_regionkey;\" && \
psql -c \"ALTER TABLE NATION ADD FOREIGN KEY (N_REGIONKEY) REFERENCES REGION (R_REGIONKEY) NOT VALID;\"")

# 并行运行所有主键和外键创建任务
run_parallel 8 "${commands[@]}"

# 清理临时文件
rm -f "$data_dir/lineitem_split_"*
rm -f "$data_dir/orders_split_"*

# 恢复表的持久性设置
psql -c "update pg_class set relpersistence ='p' where relnamespace='public'::regnamespace;"

# 完成通知
echo "主键和外键创建完成，数据加载和索引构建完成。"
