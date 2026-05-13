# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
使用用中文和用户对话

## 仓库结构

这是一个测试管理平台 (test-mng) 的 monorepo，由两个独立子项目 + 启动脚本组成。后端和前端有各自独立的 git 仓库，在根目录下聚合。

```
test-mng/
├── test-mng-service/   # 后端（Spring Cloud 微服务聚合工程，独立 git 仓库）
├── test-mng-web/       # 前端（Vue 3 单页应用，独立 git 仓库）
├── docs/               # 跨模块/全局设计文档（业务模块说明、设计方案等，新写的 MD 都放这里）
└── script/             # 一键启动脚本（前后端）
```

**⚠️ 文档优先级（重要）**：

- **本根目录 `CLAUDE.md` 是我们自己维护的（GitHub `qwb1967/test-mng`），Claude 写代码 / 给建议时一律以本文件为准。**
- 子目录 `test-mng-service/CLAUDE.md` 和 `test-mng-web/CLAUDE.md` 是**团队共享的独立仓库（Codeup）里的文档**，由团队维护、**可能与代码现状不一致**（典型差异：里面写的 `Result` / `PageResult` / `BusinessException` 等类名已过时，实际代码用的是 `JsonDataVO` / `PageDataVO` / `BizException`）。这两份文档**仅作为补充参考**（部分 UI 规范、目录结构等细节仍准确），**与本文件冲突时以本文件为准**。
- **不要修改子项目的 `CLAUDE.md`**——它们是团队共享文件，我们要记录的内容统一写到本文件中。

**新建跨模块/全局文档统一放到 `docs/` 目录**（已有：`API_TEST_PLAN_DESIGN.md` / `API_TEST_PLAN_ISSUES.md` / `API_TEST_PLAN_PROGRESS.md`）。子项目内部的设计文档仍留在各自子项目下。

- 后端规范（团队版，**仅供参考**）：[test-mng-service/CLAUDE.md](test-mng-service/CLAUDE.md)
- 前端规范（团队版，**仅供参考**）：[test-mng-web/CLAUDE.md](test-mng-web/CLAUDE.md)

## 后端：test-mng-service

**技术栈**：Java 21 · Spring Boot 3.4.12 · Spring Cloud 2024.0.2 · Spring Cloud Alibaba · MyBatis Plus 3.5.15 · Sa-Token · Nacos 2.x · MySQL 8 · Redis · Redisson · Knife4j。

**微服务模块**（每个都是独立的 Spring Boot 应用，配置走 Nacos）：

| 模块 | 作用 |
|------|------|
| `test-mng-gateway` | API 网关（路由、鉴权透传、Knife4j 聚合文档）|
| `test-mng-auth` | 认证授权（Sa-Token）|
| `test-mng-system` | 系统管理（用户、角色、菜单、字典等）|
| `test-mng-api-test` | API 测试管理（用例/场景/环境）|
| `test-mng-api-test-execution` | API 测试执行引擎（多协议：gRPC/WebSocket/MQTT/Thrift/Dubbo 等）|
| `test-mng-functional` | 功能测试管理 |
| `test-mng-ui-auto` | UI 自动化测试 |
| `test-mng-code-review` | 基于 Spring AI + JGit 的代码评审 |
| `test-mng-storage` | 文件存储（S3 兼容）|
| `test-mng-task-center` | 任务中心（调度、异步执行）|
| `test-mng-license-core` / `test-mng-license-issuer` | License 核心库 / 签发服务 |
| `test-mng-common` | 共享代码（`JsonDataVO`、`PageDataVO`、`BizException` + `BizCodeEnum`、MyBatis Plus 基类等）|

**关键架构约定**（详见后端 CLAUDE.md）：

- 包命名：`cloud.aisky.{module}.{controller|service|mapper|entity|dto|vo|enums|config|handler}`
- 分层：Controller → Service/ServiceImpl → Mapper (`BaseMapper`)；Entity ↔ DTO ↔ VO 用 Converter 显式转换
- Controller 统一返回 `JsonDataVO<T>`（`new JsonDataVO<T>().buildSuccess(data)` / `.buildError(msg)` / `.buildResult(BizCodeEnum.X)`），分页返回 `JsonDataVO<PageDataVO<T>>`
- 业务异常 `throw new BizException(BizCodeEnum.XXX)` 或 `new BizException(BizCodeEnum.XXX, "自定义消息")`；**不要在业务代码里 `try/catch` 后 `return new JsonDataVO().buildError(...)`**——交给 `@RestControllerAdvice` 全局统一处理
- `BizCodeEnum` 业务码 6 位整数，**前 2 位是服务编号**，后 4 位按模块码段顺序；新增业务码追加在末尾，不要插入中间打乱已有编号
- 表前缀：实体表 `tb_xxx`，关联关系表 `tr_xxx`；主键统一 `@TableId(type = IdType.ASSIGN_ID)`（雪花）；逻辑删除字段加 `@TableLogic`；当前登录用户在 Controller 用 `SessionUtils.getCurrentUserId()` 取，再传给 Service
- `create_time` / `modify_time` / `create_user_id` / `modify_user_id` 由 `MpMetaObjectHandler` 自动填充，**Service 中不要手动 `set`**
- DTO/VO 字段必须带 `@Schema(description = ..., requiredMode = ...)`（前端依赖 Knife4j 生成类型）；Entity ↔ VO 转换用私有 `toVO()` 或 `BeanUtil.copyProperties`，不用引入 MapStruct 这类额外框架
- 依赖注入用 `@RequiredArgsConstructor` + `final` 字段（不用字段级 `@Autowired`）
- 校验用 `@Valid` + Jakarta Validation 注解；DTO/VO 字段必须带 `@Schema` 描述（见用户 memory `feedback_dto_vo_schema.md`）
- 分页统一用 MyBatis Plus 的 `Page` + `LambdaQueryWrapper`
- 脚本引擎：同时支持 Groovy / Nashorn / BeanShell / Jython / GraalPy（Python3），执行服务里按协议动态选用
- 国产数据库驱动已在 parent `pom.xml` 管理：openGauss / 达梦 / OceanBase / 金仓 / 海量

**本地启动需要的外部依赖**：Nacos、MySQL、Redis（见 `script/start_test_mng_backend.sh` 中 `NACOS_ADDR` 等环境变量，默认指向团队 dev Nacos）。

**团队 dev Nacos 访问信息**（来自 `script/start_test_mng_backend.sh`，可用环境变量覆盖）：

- 控制台地址：<http://dev-nacos.imchenr1024.com/nacos>
- 服务端地址（`NACOS_ADDR`）：`dev-nacos.imchenr1024.com`
- 账号 / 密码：`nacos` / `8f2598cdeedc4234b80c32424a7bd117`
- Namespace：`5143d5aa-cce6-43f7-bf9b-e422aaf7667d`
- Discovery group / cluster：`QIANWENBO_LOCAL_GROUP` / `QIANWENBO-LOCAL`（metadata cluster：`QIANWENBO_LOCAL`）

**团队 dev 数据库访问信息**（MariaDB，HikariCP，连接配置在 Nacos 中各模块的 `*.yml` / `*.properties`）：

- 主机端口：`dev-mariadb.imchenr1024.com:13307`
- 每个微服务有独立的库与账号，**库名 = 用户名 = `tp_{module}`，密码各库独立**。
- JDBC URL 模板：`jdbc:mysql://dev-mariadb.imchenr1024.com:13307/{db}?autoReconnect=false&useUnicode=true&characterEncoding=UTF-8&characterSetResults=UTF-8&zeroDateTimeBehavior=convertToNull&useSSL=false&allowPublicKeyRetrieval=true`
- 已知库与密码：

  | 模块 | 库名 / 用户名 | 密码 |
  |------|----------------|------|
  | system | `tp_system` | `rYFi8p2Ak4dW8NYF` |
  | auth | `tp_auth` | `5bKMtkkhxb3GWEpz` |
  | functional | `tp_functional` | `Zyz8HZsDSjR4a55D` |
  | storage | `tp_storage` | `MzneehQNcBY8JTPR` |
  | api-test / api-test-execution | `tp_interface` | `arGtWAWcRsGJbZAb` |
  | task-center | `tp_task` | `t6kSKrhQMMsNQjit` |
  | code-review | `tp_code_review` | `HSn3jQs5mHi6EsXn` |
  | ui-auto | `tp_ui_test_base` | `tx7b5e7FETxMAeB3` |

- 其它模块的库 / 密码以 Nacos 配置为准（在 Nacos 控制台搜对应 `*.yml` 中的 `spring.datasource.*`）。
- **直接查 dev / fat MariaDB**：用 `.claude/skills/query-db.md` + `.claude/scripts/db_query.py`（默认只读，DDL/DML 须 `--confirm`；`--env dev|fat` 切换环境）。

**团队 dev Redis 访问信息**：

- Host / Port：`dev-redis.imchenr1024.com:16379`
- 密码：`redis_5285Aw`

### 数据库设计红线（新增表 / 字段 / 索引时必读）

> 来源：团队《研发迭代规范》。Claude 写 DDL 或 Entity 时严格遵守，违反任何一条都要主动指出并修正。

**硬性要求（必须）**：

- 库 / 表 / 字段 / 索引名 **全小写**，禁用 MySQL 关键字
- 实体表名前缀 `tb_`，关联关系表前缀 `tr_`（例：`tb_api_case` / `tr_user_role`）
- 主键统一：`id` `BIGINT UNSIGNED NOT NULL AUTO_INCREMENT`（实体类用 `@TableId(type = IdType.ASSIGN_ID)`），**禁止组合主键**
- 所有字段 `NOT NULL` + 默认值（数值 `0`，字符串 `''`）
- 所有表必须有 `create_time` `DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP`、`modify_time` `DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`
- 所有表必须为 `modify_time` 建普通索引 `ix_modify_time(modify_time)`
- 所有表 / 字段必须写 `COMMENT`
- 时间类型用 `DATETIME`（**不用 `TIMESTAMP`**，避免时区性能损耗 + 2038 问题）
- 索引命名：非唯一 `ix_<字段>[_字段]`，唯一 `uk_<字段>[_字段]`
- JOIN 关联字段类型必须一致并建索引

**强烈建议**：

- `VARCHAR(N)` 的 N 尽量小、`N < 255`
- 用 `TINYINT` 替代 `ENUM`，字段 `COMMENT` 注明值含义（如 `0-不通过 / 1-通过`）
- 逻辑删除：加 `deleted` 字段 + `@TableLogic`，**禁止物理 `DELETE`**
- 单表数据量控制在千万级以下，超量提前规划归档
- 组合索引把高区分度字段放左边

**绝对禁止**：

- 删字段 / 删表 / 改字段名 / 改字段类型 / 改字段顺序（**只允许新增字段**，新增禁用 `AFTER` / `BEFORE`）
- `INSERT INTO ... SELECT`（会锁表）
- 无 `ORDER BY` 的 `UPDATE/DELETE ... LIMIT ...`
- 超过 2 张表的 JOIN、子查询（`WHERE id IN (SELECT ...)`）
- 外键、视图、存储过程、函数、触发器、事件
- `ORDER BY RAND()`
- **程序中执行任何 DDL**（建表/改表/删索引等都走工单，不能在代码里 `executeUpdate`）

**分库分表命名**：自增数字补零（`tb_00`~`tb_99`）；按年 `tb_2025`；按月 `tb_202501`；按天 `tb_20250101`。

> 💡 直接查 / 改 dev/fat MariaDB 用 `.claude/skills/query-db.md`（只读默认放行，DDL/DML 必须 `--confirm`）。

### 常用命令（后端）

```bash
# 在 test-mng-service/ 目录下
mvn clean install                 # 构建全部模块（默认不 skipTests）
mvn clean package -DskipTests     # 打包 fat jar（启动脚本用的就是这个）
mvn -pl test-mng-api-test -am clean package -DskipTests   # 只构建单个模块及其依赖
mvn -pl test-mng-api-test test -Dtest=SomeTest#method     # 跑单个测试方法

# 一键构建并启动全部微服务（推荐，从仓库根目录运行）
./script/start_test_mng_backend.sh
# 日志：/tmp/{service}.log，脚本会 tail 所有日志带前缀打印
# Ctrl+C 会触发 trap cleanup，优雅停止所有 jar
```

启动脚本用 `/usr/libexec/java_home -v 21` 自动定位 JDK 21，并注入 Nacos 连接与 discovery 元数据（`QIANWENBO_LOCAL` 集群）。如需改注册中心 / namespace / cluster，通过同名环境变量覆盖即可，**不要改脚本默认值**。

### 可用 Skills（后端）

位于 `test-mng-service/.claude/skills/`：

- `check-backend` — 按命名/结构/注解/分页/异常等清单审查后端代码
- `create-api` — 按规范生成 Entity / DTO / VO / Mapper / Service / Controller 模板
- `review-backend` — 全面的后端代码质量审查（规范、性能、安全、异常、测试）

## 前端：test-mng-web

**技术栈**：Vue 3.4（Composition API + `<script setup>`）· TypeScript 5.5 · Vite 5 · Element Plus 2.7 · Pinia 2（含 persistedstate）· Vue Router 4 · SCSS · Tailwind · i18n。图表 echarts + AntV G6 + sigma，编辑器 Monaco / CodeMirror / wangEditor。基于 Geeker-Admin 模板二次开发。

**路由组织**（重要）：登录页与布局外页面在 `src/routers/modules/staticRouter.ts` 静态注册；业务菜单从 `src/assets/json/authMenuList.json` 读取，由 `src/routers/modules/dynamicRouter.ts` 动态挂载到 `layout` 路由下。定位页面时以 `authMenuList.json` 中的 path 为准。

**页面入口速查（重要）**：完整的"路由 → 视图文件 → 组件 → 弹窗"对照表见 [test-mng-web/PAGE_ENTRY_POINTS.md](test-mng-web/PAGE_ENTRY_POINTS.md)。改页面前先查这个文档定位入口，比 grep 快得多。

**UI 规范要点**（详见前端 CLAUDE.md）：

- **颜色必须走 CSS 变量**：`var(--el-text-color-theme)` (主题色 `#6b62ff`) / `--el-text-color-primary|assistant|secondary` / `--el-bg-color-page(-white)` / `--el-border-color`，禁止硬编码十六进制值
- **间距优先用工具类**：`src/styles/common.scss` 定义了 `.mt{0..100}` / `.mr / .mb / .ml` / `.pt / .pr / .pb / .pl`，禁止内联 style
- **布局工具类**：`.flx-center` / `.flx-justify-between` / `.flx-align-center`；文本省略 `.sle`（单行）/ `.mle`（两行）
- **卡片** `padding:20px; border-radius:6px`；**对话框** `border-radius:12px`；**表单项** `margin-bottom:15px`
- 组件用 `<script setup lang="ts">`，必须 `defineOptions({ name })`，Props/Emits 用 TS 接口，禁用 `any`

**前端命名 / 目录约定**（项目里两套并存，新建时一定要选对）：

- **目录两套约定（容易混淆）**：`src/components/<子目录>` 用 **PascalCase**（如 `CommonTable/`、`CodeEditor/`），`src/views/<子目录>` 用 **kebab-case**（如 `api-module/`、`code-review/`）
- 文件名：Vue 组件 PascalCase（`UserList.vue`）；工具 / hooks / API 模块 camelCase（`formatDate.ts`、`useTable.ts`）；独立样式文件 kebab-case（`user-list.scss`）
- TypeScript：class / interface / type / enum 都 **PascalCase**；业务枚举可加 `Enum` 后缀（如 `ItemFieldTypeEnum`、`ResultEnum`）；变量 / 函数 camelCase，布尔加 `is/has/can` 前缀；模板 ref 加 `Ref` 后缀（`formRef`、`tableRef`）；模块级常量 UPPER_SNAKE_CASE
- CSS class 用 kebab-case（`.user-list` / `.case-detail`）
- 前端调后端接口的响应类型与后端对齐：`JsonDataVO<T>` 包络，分页用 `PageDataVO<T>`（**不是** `PageResult`）

### 常用命令（前端）

```bash
# 在 test-mng-web/ 目录下（项目用 pnpm，package.json 有 scripts）
pnpm install
pnpm dev                # 启动 Vite dev server
pnpm build:dev          # 打包开发环境
pnpm build:test         # 打包测试环境
pnpm build:pro          # 打包生产环境
pnpm type:check         # vue-tsc --noEmit 类型检查
pnpm lint:eslint        # eslint --fix
pnpm lint:prettier      # prettier --write
pnpm lint:stylelint     # stylelint --fix

# 一键重启前端开发服务器（仓库根目录）
./script/start_test_mng_frontend.sh
```

Husky + lint-staged + commitlint 已接入，commit 走 `pnpm commit`（czg）。

### 可用 Skills（前端）

位于 `test-mng-web/.claude/skills/`：

- `check-ui` — 按颜色/工具类/字号/间距/圆角/组件结构清单审查 UI
- `create-component` — 按规范生成 Vue 组件骨架（script setup + TS + scoped SCSS）
- `review-frontend` — 全面的前端代码质量审查（UI 规范 / 类型 / 性能 / Composition API 最佳实践）

## 跨模块协作注意事项

- **前后端是两个独立 git 仓库**：`test-mng-service/.git` 和 `test-mng-web/.git`。在根目录下执行 `git status` 是无效的，要进到对应子目录。
- **接口联调**：前端通过 `src/api/` 调用后端 API；后端网关聚合各微服务的 Knife4j 文档，默认在 `http://localhost:{gateway-port}/doc.html`。
- **用户偏好记忆**：用户的项目级约定存在 `~/.claude/projects/-Users-qianwenbo-IdeaProjects-test-mng/memory/`，其中 `project_test_mng_conventions.md` 是后端新建子模块时包/依赖/响应/异常/分页/软删/Nacos 的一览表，`feedback_dto_vo_schema.md` 要求 DTO/VO 字段必须带 `@Schema`。
