# Mock 模块部署运维手册（v1.0）

> 配套设计文档：[`docs/MOCK_REDESIGN.md`](./MOCK_REDESIGN.md) v1.4
> 适用版本：mock-service v1.0（test-mng-mock 模块首次发布）
> 涉及环境：dev / fat / prod
> 状态：✅ 编码完成（后端阶段 1–9 + 前端阶段 10–11），等待环境部署

---

## 0. 一句话概述

`test-mng-mock` 是一个**独立微服务**（Nacos 注册名 `mock-service`，默认端口 `18011`），提供接口 Mock 配置面 CRUD 与数据面流量拦截。本次发布涉及：

1. 新增一个微服务（mock-service）
2. 新增一个独立库（`tp_mock`）+ 6 张表
3. 网关追加 2 条路由 + 1 个 GlobalFilter（已随后端代码上线）
4. `system` 与 `api-test` 各加 1 个字段（`tb_space.enable_mock` / `tb_api_case.enable_mock`，Flyway migration）
5. 前端接口详情页 / case 编辑 / 企业设置三处页面改造

---

## 1. 影响面与风险盘点

| 组件 | 改动 | 风险等级 | 爆炸半径 |
|---|---|---|---|
| Nacos | 新建 `mock-service-{profile}.properties`，追加 `gateway-service-{profile}.properties` 中 mock 相关路由 | 低 | 仅 mock 模块 |
| MariaDB | 新建 `tp_mock` 库（6 表）+ `tp_system.tb_space` / `tp_interface.tb_api_case` 各加一字段 | 中 | Flyway 自动跑、字段无破坏性 |
| 网关 | 追加 `MockRoutingFilter`（GlobalFilter）+ 2 条 routes | 中 | Filter 顺序错可能影响其它路由——已固化 `RouteToRequestUrlFilter.ORDER + 1` |
| 后端 | 新增 `mock-service` 微服务 | 低 | 独立部署，不可达 gateway 自动 503 fallback |
| 前端 | 接口详情页 / case 编辑 / 企业设置三处改造 + 删除旧 mock 代码 | 中 | 影响最常用页面，须前后端版本对齐发布 |

**爆炸半径控制**：三级开关（设计 D8）任一层关闭即可停止 Mock 生效：

```
1) mock.audit.enabled=false                 → 紧急停日志写入（不影响命中）
2) tb_space.enable_mock=0                   → 按企业关停（前端「企业 → Mock 服务」总开关）
3) tb_mock_api.enabled=0                    → 按接口关停（前端接口详情页右上角 Mock 开关）
```

---

## 2. 部署前置依赖

| 项 | dev | fat | prod |
|---|---|---|---|
| Nacos 控制台 | http://dev-nacos.imchenr1024.com/nacos | _由运维提供_ | _由运维提供_ |
| Nacos 账号 / 密码 | `nacos` / `8f2598cdeedc4234b80c32424a7bd117` | _由运维提供_ | _由运维提供_ |
| Nacos Namespace | `5143d5aa-cce6-43f7-bf9b-e422aaf7667d` | _由运维提供_ | _由运维提供_ |
| Nacos Group | `DEFAULT_GROUP` | `DEFAULT_GROUP` | `DEFAULT_GROUP` |
| MariaDB Host:Port | `dev-mariadb.imchenr1024.com:13307` | `47.109.54.181:23307` | _由运维提供_ |
| Redis Host:Port | `dev-redis.imchenr1024.com:16379` | _由运维提供_ | _由运维提供_ |
| 启动脚本 | `script/start_test_mng_backend.sh` | _由运维提供_ | _由运维提供_ |
| profile | `dev` | `fat` | `prod` |

应用版本要求：JDK 21+、Maven 3.6+、Spring Boot 3.4.12、Spring Cloud 2024.0.2、MyBatis Plus 3.5.15。

---

## 3. 部署步骤（按依赖顺序）

### 3.1 创建独立库 `tp_mock`（DBA 操作）

| 项 | 值 |
|---|---|
| 库名 | `tp_mock` |
| 账号 | `tp_mock`（库名 = 用户名，遵循团队 `tp_{module}` 约定） |
| 密码 | 由 DBA 生成 16 位强口令 |
| 字符集 / 排序 | `utf8mb4` / `utf8mb4_general_ci` |
| 权限 | `tp_mock` 账号对 `tp_mock` 库 ALL PRIVILEGES，不跨库 |

DBA SQL：

```sql
CREATE DATABASE tp_mock CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'tp_mock'@'%' IDENTIFIED BY '<由 DBA 生成的强口令>';
GRANT ALL PRIVILEGES ON tp_mock.* TO 'tp_mock'@'%';
FLUSH PRIVILEGES;
```

验证：

```sql
SELECT user, host FROM mysql.user WHERE user = 'tp_mock';
SHOW DATABASES LIKE 'tp_mock';
```

> ⚠️ **密码回填三处**（见步骤 3.4 / 5.1 / 5.2），妥善保管。

---

### 3.2 执行 mock 6 表 DDL

脚本：`test-mng-service/sql/mock/mysql/20260507_init.sql`（153 行）

6 张表（按 init.sql 顺序）：

| 表 | 用途 | P0 必用 |
|---|---|---|
| `tb_mock_api` | 接口 Mock 配置主表 | ✅ |
| `tb_mock_scenario` | 场景（P1） | ⚪ 建好留空 |
| `tb_mock_expectation` | Mock 期望 | ✅ |
| `tb_mock_response` | 多响应加权（P1） | ⚪ 建好留空 |
| `tb_mock_chaos_rule` | Chaos 规则（P2） | ⚪ 建好留空 |
| `tb_mock_call_log` | 调用日志（含穿透） | ✅ |

> 6 表全建是为了避免 P1/P2 迭代时再次做 DDL 变更（设计 §15）。P0 不用的表保留空表即可。

**先 dry-run**：用 DBeaver / DataGrip / `mysql --execute` 跑 EXPLAIN 或语法预检。

**执行**：

```bash
mysql -h <db-host> -P <db-port> -u tp_mock -p tp_mock \
    < test-mng-service/sql/mock/mysql/20260507_init.sql
```

验证：

```bash
mysql -h <db-host> -P <db-port> -u tp_mock -p tp_mock \
    -e "SHOW TABLES"
# 期望返回 6 行：tb_mock_api / tb_mock_call_log / tb_mock_chaos_rule
#                 / tb_mock_expectation / tb_mock_response / tb_mock_scenario
```

---

### 3.3 system / api-test 库追加 `enable_mock` 字段

两个 Flyway migration 的执行依赖环境 `spring.flyway.enabled` 配置（⚠️ **本项目实测 dev 环境为 false** — 见 `api-test-service-dev.properties`，意味着 Flyway 不会自动跑、必须 DBA 手工预执行 ALTER；生产部署前先用 Nacos 控制台或 OpenAPI 确认目标环境的 `spring.flyway.enabled`）：

| Migration | 目标库.表 | 字段定义 |
|---|---|---|
| `test-mng-system/.../V1.0.19__add_enable_mock_to_space.sql` | `tp_system.tb_space` | `ADD COLUMN enable_mock TINYINT NOT NULL DEFAULT 0` |
| `test-mng-api-test/.../V20260521__add_enable_mock_to_api_case.sql` | `tp_interface.tb_api_case` | `ADD COLUMN enable_mock TINYINT NOT NULL DEFAULT 0` |

**部署顺序约束**：system 服务必须**先于** mock-service 启动（mock-service 会通过 `SystemInnerClient.isSpaceMockEnabled` 调 system 的 `/space/inner/get-mock-enabled`，依赖 `tb_space.enable_mock`）。

如果生产 Flyway 关闭或受审计管控，DBA 在服务发布前手工预执行这两个 ALTER（单行 ALTER，无破坏性、无锁表风险）。

验证：

```sql
SHOW COLUMNS FROM tp_system.tb_space LIKE 'enable_mock';
SHOW COLUMNS FROM tp_interface.tb_api_case LIKE 'enable_mock';
-- 各返回一行 `enable_mock TINYINT NOT NULL DEFAULT 0` 即 OK
```

---

### 3.4 Nacos 新建 `mock-service-{profile}.properties`

在 dev / fat / prod 对应 Nacos 控制台：

| 项 | 值 |
|---|---|
| Namespace | _见 §2 环境表_ |
| Group | `DEFAULT_GROUP` |
| Data ID | `mock-service-{profile}.properties`（profile = dev / fat / prod） |
| Type | `properties` |

**完整内容**（环境差异参数化标红，其余通用）：

```properties
# ===== 服务基础 =====
server.port=18011
spring.application.name=mock-service

# ===== 数据源（独立库 tp_mock）=====
spring.datasource.driver-class-name=com.mysql.cj.jdbc.Driver
# ▼▼▼ 替换 <db-host> / <db-port> 为对应环境值 ▼▼▼
spring.datasource.url=jdbc:mysql://<db-host>:<db-port>/tp_mock?autoReconnect=false&useUnicode=true&characterEncoding=UTF-8&characterSetResults=UTF-8&zeroDateTimeBehavior=convertToNull&useSSL=false&allowPublicKeyRetrieval=true
spring.datasource.username=tp_mock
# ▼▼▼ 替换为步骤 3.1 拿到的实际密码 ▼▼▼
spring.datasource.password=<tp_mock 密码>
spring.datasource.hikari.maximum-pool-size=20
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.connection-timeout=30000

# ===== Redis（与该环境其它服务共用同一实例）=====
# ▼▼▼ 替换 <redis-host> / <redis-port> / <redis-password> ▼▼▼
spring.data.redis.host=<redis-host>
spring.data.redis.port=<redis-port>
spring.data.redis.password=<redis-password>
spring.data.redis.timeout=3000ms
spring.data.redis.lettuce.pool.max-active=16
spring.data.redis.lettuce.pool.max-idle=8

# ===== MyBatis Plus =====
mybatis-plus.mapper-locations=classpath*:mapper/xml/*.xml
mybatis-plus.global-config.db-config.id-type=ASSIGN_ID
mybatis-plus.global-config.db-config.logic-delete-field=deleted
mybatis-plus.global-config.db-config.logic-not-delete-value=0
mybatis-plus.global-config.db-config.logic-delete-value=1
mybatis-plus.configuration.map-underscore-to-camel-case=true

# ===== Sa-Token =====
sa-token.token-name=satoken
sa-token.timeout=2592000
sa-token.is-share=false
sa-token.token-style=uuid
sa-token.is-log=false

# ===== Knife4j（自身 OpenAPI）=====
knife4j.enable=true
knife4j.openapi.title=Mock 服务 API
knife4j.openapi.description=test-mng-mock 配置面 + 数据面
knife4j.openapi.version=v1.0

# ===== Mock 自定义配置 =====
mock.cache.reconcile-interval-seconds=60
mock.cache.invalidate-channel=mock:invalidate
mock.cache.expectation-max-size=20000
mock.cel.cache-size=2000
mock.pebble.cache-size=2000

# 调用日志
mock.audit.enabled=true
mock.audit.retention-days=7
mock.audit.queue-capacity=10000
mock.audit.batch-size=500
mock.audit.flush-interval-ms=1000
mock.audit.body-max-bytes=1048576
mock.audit.cleanup-cron=0 0 3 * * ?

mock.state.default-ttl-seconds=86400

# 穿透
mock.proxy.resolve-timeout-ms=2000
mock.proxy.default-connect-timeout-ms=5000
mock.proxy.default-response-timeout-ms=30000
mock.proxy.log-detail=true
mock.proxy.space-enabled-cache-ttl-seconds=60

# OpenFeign
spring.cloud.openfeign.client.config.default.connect-timeout=5000
spring.cloud.openfeign.client.config.default.read-timeout=20000

# 日志
logging.level.cloud.aisky=info
logging.level.cloud.aisky.engine.matcher=debug
```

**环境差异参数表**：

| Key | dev | fat | prod |
|---|---|---|---|
| `spring.datasource.url` host | `dev-mariadb.imchenr1024.com:13307` | `47.109.54.181:23307` | _由运维提供_ |
| `spring.datasource.password` | _DBA 分配_ | _DBA 分配_ | _DBA 分配_ |
| `spring.data.redis.host` | `dev-redis.imchenr1024.com` | _由运维提供_ | _由运维提供_ |
| `spring.data.redis.port` | `16379` | _由运维提供_ | _由运维提供_ |
| `spring.data.redis.password` | `redis_5285Aw` | _由运维提供_ | _由运维提供_ |

---

### 3.5 Nacos 改 `gateway-service-{profile}.properties`（追加路由）

打开现有 `gateway-service-{profile}.properties`，**末尾追加**以下条目。`<N>` / `<M>` 替换为现有 routes 列表的下一个递增 index（控制台查 `spring.cloud.gateway.routes[X].id` 最大值 + 1）。

```properties
# ===== 新增路由 1：Mock 数据面（被测流量入口；由 MockRoutingFilter 改写 URI 到 lb://mock-service）=====
spring.cloud.gateway.routes[<N>].id=mock-runtime
spring.cloud.gateway.routes[<N>].uri=lb://mock-service
spring.cloud.gateway.routes[<N>].predicates[0]=Path=/__mock/**

# ===== 新增路由 2：Mock 管理面（前端调 /mock-service/api/* + /mock-service/expectation/*）=====
spring.cloud.gateway.routes[<M>].id=mock-admin
spring.cloud.gateway.routes[<M>].uri=lb://mock-service
spring.cloud.gateway.routes[<M>].predicates[0]=Path=/mock-service/**
spring.cloud.gateway.routes[<M>].filters[0]=StripPrefix=1
```

> 💡 **Knife4j 聚合**：现有 gateway 使用 `knife4j.gateway.strategy=discover` 模式 —— mock-service 注册到 Nacos 后会被自动聚合到 `doc.html`，**无需手动加 knife4j routes**。启动后访问 `doc.html` 确认 mock-service 出现即可。

---

### 3.6 凭据登记（项目内，便于 db_query.py 用）

#### 根 `CLAUDE.md` 已知库与密码表追加

文件：`CLAUDE.md`，找到「已知库与密码」表格，在末尾追加一行：

```markdown
  | mock | `tp_mock` | `<DBA 分配的密码>` |
```

#### `.claude/scripts/db_query.py` 凭据字典追加

文件：`.claude/scripts/db_query.py`，找到 `ENVS["dev"]["creds"]`（约第 26 行）字典，在末尾追加：

```python
            "tp_mock": ("tp_mock", "<DBA 分配的密码>"),
```

fat / prod 走各自的运维凭据管理体系，按团队约定办。

---

## 4. 启动顺序（首次发布）

> Flyway 自动跑要求 system / api-test **先启动**，让 enable_mock 字段就位。

```
1. system 服务 重启       → V1.0.19 跑，tb_space.enable_mock 字段就位
2. api-test 服务 重启     → V20260521 跑，tb_api_case.enable_mock 字段就位
3. mock-service 启动      → 连 tp_mock 库，注册 Nacos
4. gateway 重启           → 拉 Nacos 新路由 + MockRoutingFilter 生效
5. 前端 部署新版本        → 含 Mock UI + axios 拦截器注入 X-Space-Id/X-Mock-Enabled
```

**自动容错**：mock-service 启动失败时，gateway 自动返回 503 `X-Mock-Fallback: unavailable`（已实现），不会影响其它业务流量。

---

## 5. 灰度策略（推荐）

按"开关粒度从大到小"逐步放量：

| 阶段 | 操作 | 验证 |
|---|---|---|
| **T0 部署完成** | 所有企业 `tb_space.enable_mock=0`（默认值即可） | 业务无感知；mock-service 注册成功；db / Nacos 配置正常 |
| **T1 单企业验证** | 选 1 个测试企业，前端进「企业 → Mock 服务」打开总开关；测试团队配置 1 个 mock 接口 | mock 命中、穿透、日志落库三链路通 |
| **T2 灰度 10%** | 选 10% 企业开 enable_mock | 监控调用日志写入速率、mock-service CPU/内存、`tp_mock` 库连接数 |
| **T3 全量** | 全部企业可自助打开 | 注意 `tb_mock_call_log` 增长速度，cleanup-cron 已设凌晨 3 点跑保留 7 天 |

**任一阶段发现异常时的处置**：

```
全停 Mock 日志写：    Nacos 改 mock.audit.enabled=false（保留命中能力，停日志）
某企业有问题：        tb_space.enable_mock=0（该企业全部 mock 失效，流量穿透）
某接口有问题：        前端关接口右上角 Mock 开关（或直改 tb_mock_api.enabled=0）
mock-service 整挂：   gateway 自动 503 fallback，不影响其他业务；
                     如需完全下线，把 gateway 中 mock 两条路由临时移除即可
```

---

## 6. 回滚策略

### 6.1 应用回滚

- **mock-service**：回退到旧 jar 即可（首次发布场景下，回滚 = 停服并撤掉 gateway 路由，因为没有"旧 jar"）。
- **前端**：旧版前端会用旧 mock 代码（如果回滚到 mock 重构之前的版本）—— 但**注意**旧 mock 后端代码已删除（D6），所以前端如要回滚必须**同步回滚到删除前的提交**。
- **gateway**：移除追加的 2 条 mock routes，移除 `MockRoutingFilter`（或回滚 jar）。

### 6.2 数据回滚（一般无需）

- `tp_mock` 库**不需要删除**：即使整个 mock 功能下线，6 张表保留也不影响其他系统。
- `tb_space.enable_mock` / `tb_api_case.enable_mock` 字段**不需要回滚**：默认 0、不影响业务（不开 Mock 时无效字段）。

### 6.3 Nacos 配置回滚

- `gateway-service-{profile}.properties`：删除追加的 mock 相关路由（数据面 + 管理面共 2 条）。
- `mock-service-{profile}.properties`：可保留（不影响其他模块）或删除。

> 🔒 **强烈建议**：前端 + 后端版本绑定发布。Mock 重构的旧前端 mock 代码已删，必须配套部署新前端。

---

## 7. 验收自测脚本

> 4 项部署完成后，按顺序跑下面的 curl 模板。

```bash
GATEWAY=http://localhost:<gateway-port>        # 替换为实际网关地址

# ===== 7.1 管理面通：按 apiInfoId 查 mock_api =====
curl -i $GATEWAY/mock-service/api/by-api-info \
  -H "Content-Type: application/json" \
  -H "X-Space-Id: 1" \
  -d '{"apiInfoId":2031006}'
# 期望：HTTP 200 + {"code":0,"data":null,"msg":"..."}（首次未配过返回 null）

# ===== 7.2 Knife4j 聚合页：看 mock-service 文档是否出现 =====
open $GATEWAY/doc.html
# 期望：左侧服务列表能看到 "Mock 服务"

# ===== 7.3 数据面状态映射（设计 §4.5.4）=====

# (a) space 总开关 OFF → 直接穿透
curl -X POST $GATEWAY/system/space/toggle-mock \
  -H "Content-Type: application/json" \
  -d '{"spaceId":1,"enableMock":false}'

curl -i $GATEWAY/api/login \
  -H "X-Mock-Enabled: true" -H "X-Space-Id: 1" -H "X-Env-Id: 5" \
  -d '{}'
# 期望响应头：X-Mock-Hit: passthrough   X-Mock-Passthrough-Reason: space_disabled

# (b) space ON 但 api 没配 → 穿透
curl -X POST $GATEWAY/system/space/toggle-mock \
  -H "Content-Type: application/json" \
  -d '{"spaceId":1,"enableMock":true}'

curl -i $GATEWAY/api/some-not-mocked \
  -H "X-Mock-Enabled: true" -H "X-Space-Id: 1" -H "X-Env-Id: 5"
# 期望响应头：X-Mock-Hit: passthrough   X-Mock-Passthrough-Reason: api_not_found

# (c) 缺 X-Env-Id → 400
curl -i $GATEWAY/api/login \
  -H "X-Mock-Enabled: true" -H "X-Space-Id: 1"
# 期望 HTTP 400 + {"code":400,"msg":"X-Env-Id Header missing"}

# ===== 7.4 调用日志落盘验证（异步 ~1s 后）=====
mysql -h <db-host> -P <db-port> -u tp_mock -p tp_mock -e "
  SELECT id, trace_id, space_id, env_id, method, path, matched, passthrough,
         miss_reason, status_code, cost_ms, create_time
  FROM tb_mock_call_log ORDER BY id DESC LIMIT 5"
# 期望：上面几次 curl 都有对应记录，passthrough=1、miss_reason 对应
```

---

## 8. 监控与运维

### 8.1 关键指标（P0 默认基础，Prometheus Metrics 在 P1）

- mock-service 注册到 Nacos（控制台 → 服务列表 → mock-service 实例数 ≥ 1）
- mock-service HikariCP 池状态（默认配置 20 个连接）
- gateway routes 加载（`doc.html` 看到 mock-service 即说明路由生效）
- `tb_mock_call_log` 写入速率（生产建议加慢查询监控）

### 8.2 日志位置

| 服务 | 日志路径 |
|---|---|
| mock-service | `/tmp/mock-service.log`（启动脚本写入） |
| gateway | 现有 gateway 日志位置 |

关键日志类（INFO/DEBUG 级别可观察）：

- `cloud.aisky.filter.MockRoutingFilter` — 流量进 mock 通道
- `cloud.aisky.service.runtime.MockMatchService` — 三级开关命中
- `cloud.aisky.service.runtime.MockProxyService` — 穿透
- `cloud.aisky.service.runtime.MockCallLogger` — 调用日志入队/批量落盘

### 8.3 调用日志查询模板

```sql
-- 最近 100 条调用
SELECT trace_id, space_id, env_id, method, path, matched, passthrough,
       miss_reason, status_code, cost_ms, create_time
FROM tb_mock_call_log ORDER BY id DESC LIMIT 100;

-- 某接口 24h 命中率
SELECT api_id, COUNT(*) AS total, SUM(matched) AS hit,
       ROUND(SUM(matched)/COUNT(*)*100, 2) AS hit_rate
FROM tb_mock_call_log
WHERE create_time >= NOW() - INTERVAL 1 DAY AND api_id > 0
GROUP BY api_id ORDER BY total DESC;

-- 24h 穿透失败原因 TOP
SELECT miss_reason, COUNT(*) AS cnt
FROM tb_mock_call_log
WHERE passthrough = 1 AND status_code >= 500
  AND create_time >= NOW() - INTERVAL 1 DAY
GROUP BY miss_reason ORDER BY cnt DESC;

-- 慢请求 TOP（cost_ms > 1000）
SELECT trace_id, method, path, status_code, cost_ms, miss_reason, create_time
FROM tb_mock_call_log
WHERE cost_ms > 1000 AND create_time >= NOW() - INTERVAL 1 DAY
ORDER BY cost_ms DESC LIMIT 50;
```

---

## 9. 已知限制（P0 范围）

P0 不含：

- Scenario 场景管理 / SCRIPT / FAKER 响应类型 / 多响应加权随机
- Chaos 故障注入 / 状态机 / 录制回放（P2）
- OpenAPI 一键导入、Postman Collection 复制按钮
- Mock 调用日志前端页（前端只在 Mock Tab 看不到日志，需通过 SQL 查 `tb_mock_call_log`）
- 表单 → CEL 单向（CEL 不反推回表单）
- cURL 复制使用 `VITE_API_URL` 作 origin（不是被测系统真实域名）—— 复制后用户自己改 host
- apiMockStore.refresh() 异步刷新（开 Mock 后立即发请求可能漏 X-Mock-Enabled，重试一次即可）
- 接口右上角 Mock 开关 UI 位置在 ApiInfoView actions slot（切到 Mock Tab 时隐藏；后续可挪到 detail-header）

完整 P1 / P2 / P3 清单见 [`docs/MOCK_REDESIGN.md`](./MOCK_REDESIGN.md) §15。

---

## 10. 应急预案

| 现象 | 处理 |
|---|---|
| mock-service 启动失败 | 检查 Nacos `mock-service-{profile}.properties`；检查 `tp_mock` 库连接；gateway fallback 自动生效、业务流量不阻塞 |
| 大量 `X-Mock-Hit: passthrough_failed` | 检查 ApiTestInnerClient 可达；检查 env 配置的 base_url；必要时设 `tb_space.enable_mock=0` 全停 |
| `tb_mock_call_log` 写崩 / 库满 | Nacos 改 `mock.audit.enabled=false` 立即停日志写入；不影响 mock 命中；之后清理历史日志（按 retention-days 自动清理或手工 DELETE） |
| 穿透下游真实接口超时 | Nacos 调 `mock.proxy.default-response-timeout-ms`（默认 30000）；或 env 配置 per-request 超时 |
| 全局 Mock 命中错乱 | `tb_space.enable_mock=0` → 该企业全部穿透；或 `tb_mock_api.enabled=0` → 接口级穿透 |
| gateway 加载新路由失败 | Nacos 控制台改回旧版（删除追加的 2 条路由）；gateway 自动刷新（或手动重启） |
| Flyway migration 卡住 | 检查 `flyway_schema_history` 表，找到失败记录手工 `UPDATE ... SET success=1`；或 DBA 手工跑 ALTER 后 mark migration 为 success |

---

## 11. 发布检查清单（Checklist）

发布前打钩：

- [ ] **3.1** DBA 已创建 `tp_mock` 库 + `tp_mock` 账号，密码已发回
- [ ] **3.2** `20260507_init.sql` 在目标环境 `tp_mock` 库执行成功，`SHOW TABLES` 返回 6 表
- [ ] **3.3** Flyway 状态正常（system / api-test 服务启动日志看到 V1.0.19 / V20260521 success）
- [ ] **3.3** `SHOW COLUMNS FROM tp_system.tb_space LIKE 'enable_mock'` 与 `tp_interface.tb_api_case` 各返回一行
- [ ] **3.4** Nacos 已新建 `mock-service-{profile}.properties`，密码字段已填实际值
- [ ] **3.5** Nacos `gateway-service-{profile}.properties` 已追加 2 条 routes，index 无冲突
- [ ] **3.6**（dev/team）根 `CLAUDE.md` + `db_query.py` 凭据登记完成
- [ ] **4** 启动顺序正确：system → api-test → mock-service → gateway → 前端
- [ ] mock-service 在 Nacos 控制台已注册
- [ ] gateway `doc.html` 能看到 Mock 服务 OpenAPI
- [ ] **7** 验收自测脚本 7.1–7.4 全通过

发布后观察 24 小时：

- [ ] mock-service CPU/内存/连接池正常
- [ ] `tb_mock_call_log` 写入正常，无积压
- [ ] 业务报障无 mock 关联

---

## 12. 文档版本

- v1.0 — 2026-05-23 — 首次发布手册（配套 mock-service v1.0、设计文档 MOCK_REDESIGN.md v1.4）

---

## 附录 · 参考链接

- 设计文档：[`docs/MOCK_REDESIGN.md`](./MOCK_REDESIGN.md)
- 后端模块：`test-mng-service/test-mng-mock/`
- 前端关键路径：
  - `test-mng-web/src/views/api-module/components/ApiMockTab.vue`
  - `test-mng-web/src/views/api-module/components/MockExpectationDrawer.vue`
  - `test-mng-web/src/views/enterprise/mock/index.vue`
  - `test-mng-web/src/stores/modules/apiMock.ts`
- DDL：`test-mng-service/sql/mock/mysql/20260507_init.sql`
- Migration：
  - `test-mng-service/test-mng-system/src/main/resources/db/migration/V1.0.19__add_enable_mock_to_space.sql`
  - `test-mng-service/test-mng-api-test/src/main/resources/db/migration/V20260521__add_enable_mock_to_api_case.sql`
