# tpch_copy.sh相对于原始文件的修改

对比文件一和文件二，以下是两者的主要不同之处：

### 1. **`pg_host` 设置**
   - **文件一**：`pg_host=~/tmp_master_dir_polardb_pg_1100_bld`
   - **文件二**：`pg_host=localhost`
   - **差异**：文件一使用的是 `~/tmp_master_dir_polardb_pg_1100_bld`，而文件二使用的是 `localhost`，这可能表示不同的数据库主机或环境设置。这里实际上是`UNIX_SOCKET`的使用，conf里面默认的路径就在这里。

### 2. **`data_dir` 路径**
   - **文件一**：`data_dir=../Data1`
   - **文件二**：`data_dir=/data`
   - **差异**：文件一使用相对路径 `../Data1`，而文件二使用绝对路径 `/data`，这意味着文件二可能是用于不同的系统环境或不同的数据存储路径。

### 3. **使用的 SQL 脚本**
   - **文件一**：在 `PHASE 1` 中执行了多个 `ALTER SYSTEM` 命令配置 PolarDB 相关的参数，涉及大量的系统级配置，如 `polar_bulk_read_size`，`max_parallel_workers` 等。这些是针对 PolarDB 的优化。
   - **文件二**：没有类似的 PolarDB 配置，而是直接执行了 `psql -f $tpch_dir/dss.ddl` 以创建表。
   - **差异**：文件一针对 PolarDB 做了许多系统级配置，而文件二则没有。文件二更简洁，直接加载表结构。

### 4. **数据导入 (Phase 2)**
   - **文件一**：文件一的导入过程更为复杂，分为多个步骤，使用 `split` 将数据拆分成多个部分，并通过 `run_parallel` 函数并行执行多个导入和索引创建命令。
   - **文件二**：文件二直接通过 `\COPY` 命令逐个导入各个表的数据，没有拆分和并行执行。
   - **差异**：文件一有并行化和拆分数据的步骤，从而优化了数据加载过程；而文件二则是直接串行导入数据。

### 5. **索引创建**
   - **文件一**：在数据导入的同时，还会创建索引，例如 `CREATE INDEX CONCURRENTLY` 命令用于 `lineitem`、`orders` 等表。
   - **文件二**：没有单独的索引创建步骤，仅在 `PHASE 3` 中通过 `psql -f $tpch_dir/dss.ri` 处理外键和主键。
   - **差异**：文件一在数据导入时创建索引，文件二则在最后通过外部脚本创建主键和外键。

### 6. **外键和主键创建**
   - **文件一**：文件一在 `PHASE 3` 中创建了详细的主键和外键，逐个表处理，并且并行执行。
   - **文件二**：文件二在 `PHASE 3` 中简单地通过 `psql -f $tpch_dir/dss.ri` 脚本处理外键和主键的创建。
   - **差异**：文件一显式列出了所有表的主键和外键创建命令，并且并行执行；文件二则通过外部 SQL 脚本来处理，没有显式列出。

### 7. **临时文件清理**
   - **文件一**：在数据导入完成后，文件一清理了数据拆分过程中生成的临时文件：`rm -f "$data_dir/lineitem_split_"*` 和 `rm -f "$data_dir/orders_split_"*`。
   - **文件二**：没有清理临时文件的步骤。
   - **差异**：文件一在数据加载后清理了临时文件，文件二没有此步骤。

### 8. **其他配置**
   - **文件一**：包括了 PolarDB 特有的配置，如 `polar_bulk_read_size`、`polar_index_create_bulk_extend_size` 等。
   - **文件二**：没有涉及任何 PolarDB 特有的配置，偏向标准 PostgreSQL 配置。

### 总结：
- **文件一** 是针对 **PolarDB** 进行了特定优化，使用了更多的自定义配置（如并行加载、PolarDB 优化参数设置、索引创建等），同时在数据导入时进行了数据拆分并行处理。
- **文件二** 是一个较为简单和直接的脚本，主要执行数据加载、表结构创建以及主键和外键添加，适合标准的 PostgreSQL 环境。

两者的主要差异在于配置的复杂性、数据加载方式（并行与串行）、PolarDB 的专有优化等方面。

# polardb_build.sh相对于原始文件的修改

## initdb的区别
* 现在：`su_eval "$pg_bld_basedir/bin/initdb -U $pg_db_user -D $pg_bld_master_dir --no-locale --encoding=SQL_ASCII $tde_initdb_args"`

* 之前：`su_eval "$pg_bld_basedir/bin/initdb -k -U $pg_db_user -D $pg_bld_master_dir $tde_initdb_args"`

* 解释：可以禁用区域设置，且用SQL_ASCII不进行编码检查，有些许性能提升

## GCC编译选项的区别
* 现在：`gcc_opt_level_flag="-pipe -Wall -grecord-gcc-switches -march=native -mtune=native -fno-omit-frame-pointer -I/usr/include/et"`

* 之前：`gcc_opt_level_flag="-g -pipe -Wall -grecord-gcc-switches -I/usr/include/et"`

* 解释：利用了cpu的优化，但是存在问题，这里需要打开调试与添加调试有关的信息吗？如-grecord-gcc-switches和-fno-omit-frame-pointer

## asan工具的区别
* 现在：off

* 之前：on

* 解释：避免更多的内存占用（牺牲一定的安全检查）

## debug mode的区别
* 现在：off

* 之前：on

* 解释：避免debug模式带来的编译额外开销
