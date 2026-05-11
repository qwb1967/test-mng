---
name: query-db
description: 在团队 dev / fat MariaDB 上执行 SQL 查询。用于"查 dev/fat 库 / 看表结构 / 跑 SQL / 列出库表"等场景。默认 dev，加 --env fat 切换到 fat。默认只读，DDL/DML 强制二次确认。
---

# query-db — 团队 dev / fat MariaDB 查询

> ⚠️ **环境**：开发（`dev`）/ 集成测试（`fat`），**都不是生产**。即便如此，写操作仍需二次确认。
> - `dev`：`dev-mariadb.imchenr1024.com:13307`，每个微服务独立账号（账号 = 库名）
> - `fat`：`47.109.54.181:23307`，统一 `root` 账号（可访问所有库）

## 何时触发

用户出现如下意图时调用本 skill：

- "查一下 dev 库里 xxx 表"、"看 tp_system 有哪些表"、"`tp_auth` 的 user 表结构"
- "查 fat 库 / fat 环境 xxx 表 / 集成测试环境数据库" → 加 `--env fat`
- "执行下这条 SQL：…"、"跑下这个查询"
- "dev/fat 数据库里有哪些库"
- 任何需要直接读 / 写 dev / fat MariaDB 的场景

## 工具

执行入口：`python3 .claude/scripts/db_query.py`

```
--env <dev|fat>       目标环境（默认 dev）
--db <name>           目标库（默认 tp_system）。dev 下必须在已知库列表中；fat 下任意（root 通吃）
--sql "<SQL>"         直接传 SQL 字符串
--file <path.sql>     从文件读 SQL
--list-databases      = SHOW DATABASES（用 --db 指定的账号）
--confirm             写操作（DDL/DML）必须加此参数才会执行
--json                输出 JSON 而非表格
```

脚本默认只允许 `SELECT / SHOW / DESCRIBE / DESC / EXPLAIN / USE` 开头的语句；其它语句（INSERT/UPDATE/DELETE/REPLACE/MERGE/CREATE/ALTER/DROP/TRUNCATE/GRANT/REVOKE/...）一律拒绝，除非加 `--confirm`。

## 操作约定（重要）

1. **只读语句**：直接执行，把结果回给用户。
2. **写 / DDL 语句**（任何会改库结构或数据的）：
   - **第一步**：把要执行的 SQL **完整复述给用户**，**同时复述目标环境与库**（特别是 fat：root 账号写错代价更大），并明确说"这是写操作，需要你确认。回复 `yes` / `确认` 才会执行。"
   - **第二步**：必须收到用户的明确同意，才能加 `--confirm` 重跑。
   - **不要** 默认任何"看起来安全"的写操作（即便是带 WHERE 的 UPDATE / DELETE）。
   - 用户的"同意"必须是针对当前这条 SQL + 当前环境的，不能套用到后续语句，也不能跨环境复用。
3. **跨库**：
   - `dev`：每个库账号互相隔离，`tp_system` 账号查不到 `tp_auth` 的表。要查别的库就用 `--db tp_auth` 切换。
   - `fat`：root 账号可访问所有库，`--db` 仍要指定（影响 SQL 里非全限定的表名），但任何库都能连。
4. **大结果集**：`SELECT * FROM xxx` 不加 LIMIT 时，先建议加 `LIMIT 50`。
5. **环境选择**：默认 `dev`，用户没明说 fat 就用 dev。用户提到 "fat / 集测 / 集成测试 / 47.109.54.181" 等才加 `--env fat`。

## 已知数据库（dev）

`dev-mariadb.imchenr1024.com:13307`

| 库名 / 用户名 | 密码 | 对应微服务 |
|---|---|---|
| `tp_system` | `rYFi8p2Ak4dW8NYF` | test-mng-system |
| `tp_auth` | `5bKMtkkhxb3GWEpz` | test-mng-auth |
| `tp_functional` | `Zyz8HZsDSjR4a55D` | test-mng-functional |
| `tp_storage` | `MzneehQNcBY8JTPR` | test-mng-storage |
| `tp_interface` | `arGtWAWcRsGJbZAb` | test-mng-api-test / test-mng-api-test-execution（接口测试）|
| `tp_task` | `t6kSKrhQMMsNQjit` | test-mng-task-center |
| `tp_code_review` | `HSn3jQs5mHi6EsXn` | test-mng-code-review |
| `tp_ui_test_base` | `tx7b5e7FETxMAeB3` | test-mng-ui-auto（UI 自动化测试基础库）|

> 命名规则：**库名 = 用户名 = `tp_{module}`，密码各库独立**。
> 业务账号只能 `SHOW DATABASES` 看到自己的库 + `information_schema`，不能跨库查。
> 凭据硬编码在 `.claude/scripts/db_query.py` 的 `ENVS["dev"]["creds"]`；新库就在那里加一行。

## 已知数据库（fat）

`47.109.54.181:23307`，统一账号 `root` / `mariadb_4NWCkt`。

- root 账号可访问所有库，库名沿用 `tp_*` 系列（与 dev 同构）。
- 不确定 fat 上有哪些库时，先用 `--list-databases` 查一下：

  ```bash
  python3 .claude/scripts/db_query.py --env fat --db tp_system --list-databases
  ```

- 凭据写在 `.claude/scripts/db_query.py` 的 `ENVS["fat"]["default_creds"]`。如果之后 fat 切换到每库独立账号，再往 `ENVS["fat"]["creds"]` 里补条目即可（同 dev 结构）。

## 调用示例

```bash
# === dev（默认环境）===
# 看 tp_system 有哪些表
python3 .claude/scripts/db_query.py --db tp_system --sql "SHOW TABLES"

# 看某张表的结构
python3 .claude/scripts/db_query.py --db tp_auth --sql "DESC sys_user"

# 查前 20 行（建议加 LIMIT）
python3 .claude/scripts/db_query.py --db tp_system --sql "SELECT * FROM sys_dict LIMIT 20"

# === fat ===
# 列出 fat 上有哪些库
python3 .claude/scripts/db_query.py --env fat --db tp_system --list-databases

# 查 fat 上 tp_system 的表
python3 .claude/scripts/db_query.py --env fat --db tp_system --sql "SHOW TABLES"

# 跨库查询（root 通吃，但 --db 仍需指定一个默认库）
python3 .claude/scripts/db_query.py --env fat --db tp_system --sql "SELECT * FROM tp_auth.sys_user LIMIT 10"

# === 写操作 ===
# 拦截示例 —— 不会执行
python3 .claude/scripts/db_query.py --db tp_system --sql "UPDATE sys_user SET status=1 WHERE id=999"
# → 报错退出，提示需 --confirm

# 用户明确确认后才加 --confirm
python3 .claude/scripts/db_query.py --db tp_system --sql "UPDATE sys_user SET status=1 WHERE id=999" --confirm
```

## 失败处理

- **连接超时**：先排查网络（VPN / 代理）
  - dev：`nc -vz dev-mariadb.imchenr1024.com 13307`
  - fat：`nc -vz 47.109.54.181 23307`
- **Access denied**：
  - dev：检查 `--db` 与账号是否匹配（账号 = 库名）
  - fat：确认 root 密码未变更（默认 `mariadb_4NWCkt`）
- **Unknown database '<x>'**：
  - dev：`<x>` 不在 `ENVS["dev"]["creds"]` 里，先确认这个库存在；如确实有但缺密码，去 Nacos 找 `spring.datasource.password` 加进去
  - fat：root 默认可访问所有库，如报错说明该库在 fat 上确实不存在（先用 `--list-databases` 看一下）
