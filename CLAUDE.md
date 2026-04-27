# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库结构

这是一个测试管理平台 (test-mng) 的 monorepo，由两个独立子项目 + 启动脚本组成。后端和前端有各自独立的 git 仓库，在根目录下聚合。

```
test-mng/
├── test-mng-service/   # 后端（Spring Cloud 微服务聚合工程，独立 git 仓库）
├── test-mng-web/       # 前端（Vue 3 单页应用，独立 git 仓库）
└── script/             # 一键启动脚本（前后端）
```

**在不同子项目工作时，优先遵循该子项目自己的 `CLAUDE.md`（以下链接），根目录文档只提供跨模块/全局视角。**

- 后端规范：[test-mng-service/CLAUDE.md](test-mng-service/CLAUDE.md)
- 前端规范：[test-mng-web/CLAUDE.md](test-mng-web/CLAUDE.md)

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
| `test-mng-common` | 共享代码（Result、PageResult、BusinessException、MyBatis Plus 基类等）|

**关键架构约定**（详见后端 CLAUDE.md）：

- 包命名：`cloud.aisky.{module}.{controller|service|mapper|entity|dto|vo|enums|config|handler}`
- 分层：Controller → Service/ServiceImpl → Mapper (`BaseMapper`)；Entity ↔ DTO ↔ VO 用 Converter 显式转换
- Controller 统一返回 `Result<T>`，分页返回 `PageResult<T>`，业务异常抛 `BusinessException`，全局异常处理在 `@RestControllerAdvice`
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
- **直接查 dev MariaDB**：用 `.claude/skills/query-dev-db.md` + `.claude/scripts/db_query.py`（默认只读，DDL/DML 须 `--confirm`）。

**团队 dev Redis 访问信息**：

- Host / Port：`dev-redis.imchenr1024.com:16379`
- 密码：`redis_5285Aw`

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
