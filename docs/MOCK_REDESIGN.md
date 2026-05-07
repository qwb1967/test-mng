# Mock 模块重构设计文档

> 把现有散落在 `test-mng-api-test` 模块里的 Mock 能力，重构为一个**独立的微服务 + 网关层接入**的、覆盖全平台的通用 Mock 能力。
>
> 关键诉求：客户端 **URL 不变**、用 **Header 标记**触发 Mock；规则配置独立管理；性能、扩展性、可观测性全面升级。

---

## 0. 决策记录（v1.2 已全部确认 ✅）

> 代码侧 review + 产品形态对齐后的关键决策。本节作为决策档案保留，正文相关章节已按决策结果回填。
>
> 同步动作清单见 §15 P0 前置任务。

| # | 决策项 | 选项 | 决策 ✅ |
|---|---|---|---|
| D1 | 响应壳 / 异常类型 | A) 沿用现网 `JsonDataVO<T>` / `PageDataVO<T>` / `BizException` / `BizCodeEnum`<br>B) 在 `test-mng-common` 引入 `Result<T>` / `PageResult<T>` / `BusinessException` 并迁移所有模块 | **A** ✅（v1.1）：与现网（api-test / system / functional / …）一致；B 套类在 common 里**根本不存在**，统一换 B 工程量爆炸 |
| D2 | 包结构 | A) 沿用现网 `cloud.aisky.{controller\|service\|...}`（无 module 子包）<br>B) mock 模块用 `cloud.aisky.mock.*` 规范化 | **A** ✅（v1.1）：与所有现网模块一致 |
| D3 | Servlet vs Reactive | A) Spring MVC + servlet stack（与现网一致）<br>B) WebFlux + `Mono<ResponseEntity>` | **A** ✅（v1.1）：B 与 MyBatis Plus / Sa-Token / Knife4j / `SessionUtils` 全链路换轨道，P0 收益不明显；P1 视压测量级再 spike |
| D4 | spaceId 来源 | A) 前端 axios interceptor 从 Pinia store 读 `currentSpaceId` 写 `X-Space-Id` Header<br>B) 改用 `enterpriseId` 隔离（放弃 space 粒度）<br>C) 网关从 token session 取"当前活跃 space" 注入 Header | **A** ✅（v1.1）：现网 `SessionEnum` 没有 space 字段，C 方案要改 auth + 前端 + 数据库，工程量大；A 前端 axios 加一行即可 |
| D5 | 原始路径如何带到 mock-service | A) mock-service 直接 `substring("/__mock".length())` 自己 strip<br>B) 网关注入 `X-Mock-Original-Path` Header | **A** ✅（v1.1）：更简单、零额外协议 |
| D6 | 旧版处置 | **完全重写、不兼容**：旧 `tb_api_mock*` 留库归档但不再写入；旧 `/mock/{spaceId}/...` URL 不保留兼容路由；旧 `ApiMockController` / `ApiMockServiceImpl` / `MockRequestMatcher` / `MockTemplateProcessor` 在新版上线后整体删除 | ✅（v1.1）|
| **D7** | **产品形态：分散式 vs 中心式** | A) 一级菜单"Mock 中心"+ 接口详情页快捷 Tab<br>B) **完全分散式**：接口详情 Tab + case 详情 Tab + space 设置页 Mock 总开关，无独立菜单 | **B** ✅（v1.2）：贴合现网 UI 模式，用户始终在业务上下文里操作；跨接口的全局视图（调用日志 / Chaos）放 space 设置 - Mock 子页 |
| **D8** | **三级开关结构** | space 总开关 → api 接口开关 → expectation 期望开关；case 上有独立的"执行时是否走 mock"开关 | ✅（v1.2）：见 §6.2 / §10.2 |
| **D9** | **case 与 mock 的关系** | A) case 有独立期望（`tb_mock_expectation.case_id`）<br>B) **case 不存独立期望，引用接口期望** | **B** ✅（v1.2）：接口层定义所有期望，case 执行时按 case 的请求参数 CEL 命中接口下的某条期望；`tb_api_case` 加 `enable_mock` 字段（执行引擎用） |
| **D10** | **未命中处理：穿透还是 503** | A) **穿透到真实业务**（mock-service 内部代理，对客户端透明）<br>B) 返回 404/503，客户端重试 | **A** ✅（v1.2）：客户端体感是"mock 没配就走真实接口"，无需感知；穿透目标 URL 由 mock-service 调 api-test InnerClient 解析环境配置（详见 §4.5）；**`PROXY` 响应类型从 P2 提前到 P0**（穿透就是 PROXY 的实质实现） |
| **D11** | **环境信息怎么传** | 新增 `X-Env-Id` Header；前端 axios 从 currentEnvironment store 读，case 执行引擎从 case 配置读 | ✅（v1.2）：mock-service 穿透时用 envId 调 api-test InnerClient 解析 base_url |

---

## 1. 背景与目标

### 1.1 业务背景

平台目前已经有「API 测试管理」模块自带的 Mock 能力，但实际使用中暴露出几个根本性问题：

1. **URL 模式不友好**：现在 Mock 走 `/mock/{spaceId}/{原路径}` 这样独立的地址前缀，**客户端必须改代码**才能联调到 Mock，破坏了"无感切换"的核心价值。
2. **Mock 不止 API 测试要用**：UI 自动化、性能测试、前端联调、第三方 webhook 模拟都有 Mock 诉求，但现在 Mock 长在 `test-mng-api-test` 里，跨模块复用很别扭，后续每个模块都要重新对接一遍。
3. **能力天花板低**：当前只支持「静态响应 + `{{var}}` 简单替换」，没有脚本响应、状态机、录制回放、场景切换、故障注入。一旦联调场景稍复杂（先登录失败再登录成功、轮询直到成功、限流模拟），就要回归"自己写 Mock 服务"的老路。
4. **前后端不一致**：UI 上已经暴露了"IP 条件"、"path 条件"、"Faker.js / Nunjucks"等概念，但后端没实现，导致设置后行为不符合预期。
5. **可观测性为零**：用户不知道哪条规则命中、为什么没命中、Mock 被谁调用过；没有调用日志、没有命中统计、没有性能数据。
6. **性能与可扩展性堪忧**：当前匹配是 O(n) 遍历 + 业务库（`tp_interface`）的同步查询，无缓存、无索引；规则上千条之后会成为瓶颈。

### 1.2 目标（一句话）

> **把 Mock 变成一个独立、强大、对客户端无感、对平台所有模块通用的能力。**

详细拆解：

| # | 目标 | 衡量标准 |
|---|---|---|
| G1 | **URL 透明**：客户端真实 URL 不变 | Header `X-Mock-Enabled: true` 即可触发，不需要改 base URL |
| G2 | **独立微服务**：脱离 `test-mng-api-test` | 新增 `test-mng-mock` 模块、独立部署（库复用 `tp_interface`，表前缀 `tb_mock_*` 隔离） |
| G3 | **网关层接入**：流量分流在网关完成 | `test-mng-gateway` 增加 Mock 路由 Filter，命中 Header 的请求自动改写 routing |
| G4 | **DSL 升级**：规则表达力全面增强 | 支持 `AND/OR/NOT`、跨字段条件、JsonPath、CEL 表达式 |
| G5 | **多种响应模式**：静态 + 模板 + 脚本 + Faker + OpenAPI 范例 | 一条期望可声明响应类型 |
| G6 | **状态机 / 场景** | 支持 stateful mock（次数、状态流转）；场景一键切换 |
| G7 | **流量录制回放** | 透传真实接口 → 自动落库为期望，3 步上手 |
| **G12** | **未命中自动穿透**（v1.2 新增） | mock 没配 / 接口开关关 / 期望未命中时，mock-service 自动用 `X-Env-Id` 解析真实业务 URL 转发；客户端体感"mock 没配就走真实接口"，零感知 |
| G8 | **故障注入（Chaos）** | 延迟、错误率、丢字段、限流可配 |
| G9 | **配置热更新** | 规则变更 ≤ 3s 全实例生效（无需重启） |
| G10 | **可观测** | 每次调用异步落库，前端可查命中详情、原始请求、渲染响应、耗时 |
| G11 | **多租户隔离** | 规则按 `spaceId` / `enterpriseId` 隔离 |

### 1.3 非目标（明确不做）

- ❌ 跨协议 Mock 第一期只覆盖 HTTP / HTTPS，gRPC / WebSocket / MQTT 第二期再说
- ❌ Mock 数据的可视化大屏 / BI 看板（独立项目）
- ❌ Mock 配置的版本管理 / Git 同步（第三期再考虑）
- ❌ 跨企业（`enterpriseId`）的规则共享与市场化（暂不做）
- ❌ Mock 服务对外暴露 SaaS 化（仅平台内部使用）

---

## 2. 当前实现盘点（现状分析）

### 2.1 物理位置

```
test-mng-service/
├── test-mng-api-test/src/main/java/cloud/aisky/   # ⬅ Mock 完整长在这里
│   ├── controller/ApiMockController.java          # CRUD + 运行时入口（同一个 Controller）
│   ├── service/ApiMockService.java                # Service 接口
│   ├── service/impl/ApiMockServiceImpl.java       # 业务逻辑 ~570 行
│   ├── util/MockRequestMatcher.java               # 匹配引擎
│   ├── util/MockTemplateProcessor.java            # 模板引擎
│   ├── entity/{ApiMock, ApiMockExpectation, ApiMockCondition}.java
│   └── mapper/{ApiMockMapper, ApiMockExpectationMapper, ApiMockConditionMapper}.java
└── sql/api-test/mysql/20260404.sql                # 三表 DDL + 历史数据初始化
```

> **包路径说明**：项目根 CLAUDE.md 描述的命名约定是 `cloud.aisky.{module}.{layer}`，但**现网代码实际不含 `{module}` 段**（直接 `cloud.aisky.{layer}`，如 `cloud.aisky.controller.ApiMockController`）。本设计沿用现网约定，参见 §0 D2。

库：与接口管理共用 `tp_interface`。

### 2.2 数据模型（现状）

| 表 | 关系 | 说明 |
|---|---|---|
| `tb_api_mock` | 一接口一条 | 接口创建时由 `ApiInfoServiceImpl` 自动初始化 `mock_url = /mock/{spaceId}/{path}` |
| `tb_api_mock_expectation` | mock 1 : N expectation | 期望级，存响应体、状态码、延迟、`response_headers (JSON)` |
| `tb_api_mock_condition` | expectation 1 : N condition | 条件级，**仅 AND 关系**，13 个枚举操作符 |

完整 DDL 见 `test-mng-service/sql/api-test/mysql/20260404.sql`。

### 2.3 请求执行链路（现状）

```
HTTP /mock/{spaceId}/...  ──▶  test-mng-gateway
                                    │ (路由到 api-test 模块)
                                    ▼
                          ApiMockController#handleMockRequest
                                    │
                                    ▼
                          ApiMockServiceImpl#handleMockRequest
                                    │
   ┌────────────────────────────────┼────────────────────────────────┐
   │                                                                 │
   ① readBody 入 attribute    ② extractSpaceId    ③ DB: select tb_api_mock by space+method
   ④ filter URL pattern      ⑤ DB: select expectations enabled  ⑥ DB: select conditions
   ⑦ MockRequestMatcher.match (线性扫描)    ⑧ Thread.sleep(delayMs)
   ⑨ MockTemplateProcessor.process (静态变量替换)    ⑩ 拼 ContentType + Headers + StatusCode 返回
```

### 2.4 现有问题清单（按严重程度）

| # | 问题 | 严重程度 | 位置 |
|---|---|---|---|
| P1 | URL 必须改成 `/mock/{spaceId}/...`，客户端要改 base URL | 🔴 阻塞业务价值 | 整体架构 |
| P2 | Mock 长在业务模块，无法服务全平台 | 🔴 阻塞复用 | 模块归属 |
| P3 | 每次请求 3 次同步 DB 查询，无缓存 | 🔴 性能 | `ApiMockServiceImpl:282-347` |
| P4 | 每次匹配 O(n) 全表扫描 | 🟠 性能 | `ApiMockServiceImpl:306` |
| P5 | `path` / `ip` 条件位置后端没实现，前端却暴露了 UI | 🔴 前后端不一致 | `MockRequestMatcher:122-123` |
| P6 | `Thread.sleep` 在 Reactive 链路里会阻塞（虽然现在还没接到 reactive 链路） | 🟠 性能 | `ApiMockServiceImpl:358-364` |
| P7 | 条件只能 AND，不能 OR / NOT / 嵌套 | 🟠 表达力 | `MockRequestMatcher:46-64` |
| P8 | 模板只支持顶层 key（`{{$request.body.foo}}` 不能取 `foo.bar.baz`），与 matcher 内部用法不对称 | 🟠 表达力 | `MockTemplateProcessor:142-148` |
| P9 | 脚本引擎依赖装了（Groovy/GraalJS/Jython 等）但 Mock 完全没接 | 🟡 资源浪费 | `pom.xml` |
| P10 | 无调用日志、无命中统计 | 🔴 不可观测 | — |
| P11 | 配置变更无主动推送，需要 Mock 服务 query 才能感知（每次都 query DB → 更慢） | 🟠 性能 / 实时性 | — |
| P12 | 同 space 同 url+method 会拼 `?apiId=` 区分，破坏了 URL 透明 | 🟠 设计欠缺 | `ApiMockServiceImpl:69-70` (SQL) |
| P13 | 没有场景、没有状态机、没有录制 | 🟠 能力缺口 | — |
| P14 | `responseHeaders` 用 JSON 字符串存，前端发的格式（对象 `{"k":"v"}`）和后端解析要的格式（数组）不完全一致，靠运行时 try-catch 兼容 | 🟡 数据格式混乱 | `ApiMockServiceImpl:530-553` |
| P15 | 优先级 `priority` 字段后端有，但前端 UI 不暴露，用户实际上无法控制匹配优先级 | 🟡 功能不完整 | `CreateExpectationDialog.vue` |

### 2.5 现有可借鉴的设计点

> 旧版本未投入使用，数据与表结构整体丢弃，但部分设计与代码骨架可以沿用：

- ✅ **expectation 字段设计**：`name / enabled / response_body / status_code / delay_ms / content_type` 这套字段命名与语义保留，落到新表 `tb_mock_expectation`。
- ✅ **接口与 Mock 自动绑定**：`ApiInfoServiceImpl` 创建接口时自动 insert mock 主表的思路保留（变成"创建接口同时在 Mock 服务声明它的契约"）。
- ✅ **前端 `ApiMock.vue` Tab**：作为接口详情页的一个"快速 Mock"入口可保留；但完整的 Mock 管理工作台需要新建独立菜单。
- ✅ **前端 API 文件 `src/api/modules/api-mock.ts`**：路径前缀替换为 `/mock-service/...`、调整 DTO 后可继续用。

---

## 3. 重构目标与范围

### 3.1 用户视角的核心使用流程（重构后）

> v1.2：完全分散式（D7=B），Mock 长在每个接口/case 详情里，不再有独立菜单。

#### 流程 A：**配 mock + 联调（外部客户端）**
```
1. space 设置 → Mock 总开关：ON（一次性，整个 space 启用 Mock 能力）
2. 接口详情页 → 右上角 Mock 开关：ON
3. 接口详情页 → 「Mock」Tab → 新建期望（CEL 匹配 + Pebble 响应）
4. 前端切到该 space + 任意环境 → axios 自动带：
       X-Mock-Enabled: true   （由 Mock 开关 ON 触发）
       X-Space-Id: <currentSpaceId>
       X-Env-Id:   <currentEnvId>
5. 同样的请求 URL → mock 命中返回模拟响应；未命中 → 自动穿透到 X-Env-Id 解析的真实 URL（G12）
```

#### 流程 B：**case 执行时走 mock**
```
1. 接口下面定义好 mock 期望（如"A 用户登录成功"，CEL 条件 username='A'）
2. 在 case 编辑页打开「Mock」开关
3. 跑 case：执行引擎给请求加 X-Mock-Enabled / X-Space-Id / X-Env-Id Header
4. mock-service 按 case 的请求参数 CEL 命中接口下的期望
5. 期望未匹配 → 穿透到真实接口（与流程 A 一致）
```

#### 流程 C：**多场景切换**（P1）
```
1. 接口 Mock Tab 内创建多个"场景"：默认 / 登录失败 / 服务限流
2. 客户端 Header：X-Mock-Scenario: scene_login_fail
3. 命中该场景下的期望；未命中场景内任何期望 → 走默认场景；默认也未命中 → 穿透
```

> 录制回放、Chaos 故障注入分别在 P2 提供，使用流程见 §8.3 / §8.4。

### 3.2 关键设计原则

1. **关注点分离**：`gateway` 只做路由分流，`mock-service` 只做匹配与响应生成，不混杂。
2. **配置面 vs 数据面**：CRUD 走管理 API（低 QPS、强一致）、运行时走数据面（高 QPS、最终一致）。
3. **未命中自动穿透**（v1.2 D10）：mock 未命中（含未配置 / 接口开关关 / space 开关关 / 期望都禁用）时，mock-service **自身作为代理**转发到真实业务（用 `X-Env-Id` 解析 base_url），对客户端透明。mock-service **进程不可用**才走 gateway 熔断 fallback（503）。
4. **租户隔离**：所有规则、调用日志、状态机数据都按 `spaceId` + `enterpriseId` 隔离。

### 3.3 阶段范围

详见 §15 实施计划。本文整体描述的是**目标态**，文中 §7 响应类型表、§8 高级特性、§13 管理端 API、§14 前端改造均会在条目级别标注 P0/P1/P2 阶段，第一版（P0）只交付带 P0 标记的子集。

---

## 4. 整体架构

### 4.1 部署拓扑

```
                        ┌──────────────────────────────────────────┐
                        │ Browser / SDK / Postman / 任意 HTTP 客户端 │
                        └──────────────────────────┬───────────────┘
                                                   │  Header: X-Mock-Enabled: true
                                                   │
                                                   ▼
                          ┌──────────────────────────────────────────┐
                          │ test-mng-gateway (Spring Cloud Gateway)  │
                          │ ┌──────────────────────────────────────┐ │
                          │ │ 1. GatewayGlobalFilter（已存在）      │ │
                          │ │ 2. MockRoutingFilter（新增）          │ │
                          │ │     │                                 │ │
                          │ │     ├ 命中 X-Mock-* Header           │ │
                          │ │     │   → 改写 route 到 mock-service │ │
                          │ │     │                                 │ │
                          │ │     └ 否则                            │ │
                          │ │       → 原业务路由                    │ │
                          │ └──────────────────────────────────────┘ │
                          └────────────────┬───────────────┬─────────┘
                                           │               │
                            (mock 流量)    │               │ (业务流量)
                                           ▼               ▼
              ┌────────────────────────────────────┐    ┌──────────────┐
              │ test-mng-mock (新独立微服务)        │    │ 各业务微服务  │
              │ ┌────────────────────────────────┐ │    └──────────────┘
              │ │ Runtime（数据面）              │ │
              │ │  ① 路由解析（method+path）     │ │
              │ │  ② Radix Tree 索引匹配         │ │
              │ │  ③ CEL 表达式过滤场景/条件     │ │
              │ │  ④ 选中 Expectation            │ │
              │ │  ⑤ 响应组合器                  │ │
              │ │  ⑥ Stateful 状态机             │ │
              │ │  ⑦ Chaos 注入                  │ │
              │ │  ⑧ 异步审计（队列批量落库）     │ │
              │ └────────────────────────────────┘ │
              │ ┌────────────────────────────────┐ │
              │ │ Admin（配置面）                │ │
              │ │  CRUD / Scenario / 录制管理     │ │
              │ └────────────────────────────────┘ │
              └─────┬────────────┬─────────────┬───┘
                    │            │             │
                    ▼            ▼             ▼
              ┌──────────────┐   ┌─────────┐   ┌──────────────┐
              │ MySQL        │   │ Redis   │   │ MySQL        │
              │ tp_interface │   │ 热缓存+  │   │ tp_interface │
              │ (规则源)     │   │ 状态机+  │   │ (调用日志)   │
              │ tb_mock_*    │   │ pub/sub │   │ tb_mock_*    │
              └──────────────┘   └─────────┘   └──────────────┘

> 第一版调用日志直接落 MySQL（按 `space_id` + `create_time` 索引、TTL 清理）。
> 写入端抽象为 `MockCallLogRepository`，量级真起来后可平滑切到 ClickHouse / Kafka，不重写业务代码。
```

### 4.2 模块划分

新增 Maven 模块 `test-mng-mock`，结构按现有规范（参考 `test-mng-api-test`）。

> **下面是目标态完整结构**。第一版（P0）只落：
> `runtime/MockMatchService` · `runtime/MockResponseBuilder` · **`runtime/MockProxyService`（穿透，v1.2 D10 提前）** · `admin/MockApiController` · `admin/MockExpectationController` ·
> `client/ApiTestInnerClient`（Feign 调 api-test 解析环境 base_url）· `audit/*` · `engine/{matcher,expr,template}` · `cache/*`。
> 其它目录（`stateMachine` / `chaos` / `script` / `faker` / `record`）留空待 P1/P2 补。

```
test-mng-mock/
├── pom.xml
└── src/main/java/cloud/aisky/                  # 沿用现网约定，不加 .mock 子包（见 §0 D2）
    ├── MockApplication.java
    ├── controller/
    │   ├── runtime/MockRuntimeController.java       # 数据面入口（/__mock/**）
    │   └── admin/                                   # 配置面
    │       ├── MockApiController.java
    │       ├── MockExpectationController.java
    │       ├── MockScenarioController.java
    │       ├── MockRecordController.java
    │       └── MockLogController.java
    ├── service/
    │   ├── runtime/                                 # 数据面服务
    │   │   ├── MockMatchService.java                # 匹配（P0）
    │   │   ├── MockResponseBuilder.java             # 响应组合（P0）
    │   │   ├── MockProxyService.java                # 未命中穿透（P0，v1.2）+ 录制（P2）
    │   │   ├── MockStateMachineService.java         # 状态机（P2）
    │   │   └── MockChaosService.java                # 故障注入（P2）
    │   └── admin/                                   # 配置面服务
    │       ├── MockApiService.java
    │       ├── MockExpectationService.java
    │       └── MockScenarioService.java
    ├── client/                                      # 跨服务 Feign（v1.2 新增）
    │   └── ApiTestInnerClient.java                  # 调 api-test 解析环境 base_url
    ├── engine/
    │   ├── matcher/RadixTreeIndex.java              # 路径索引
    │   ├── expr/CelEvaluator.java                   # CEL 表达式求值
    │   ├── template/PebbleTemplateEngine.java       # Pebble 模板
    │   ├── script/GraalJsExecutor.java              # GraalJS 脚本
    │   └── faker/FakerProvider.java                 # JavaFaker 包装
    ├── cache/
    │   ├── MockRuleCache.java                       # 本地 Caffeine
    │   └── MockRuleCacheInvalidator.java            # Redis pub/sub 监听
    ├── audit/
    │   ├── MockCallLogger.java                      # 内存队列 + 批量 flush
    │   ├── MockCallLogRepository.java               # 写入抽象（默认 MySQL 实现）
    │   └── MockCallLog.java                         # 调用日志实体
    ├── entity/                                       # 同 api-test 命名规范
    ├── dto/
    ├── vo/
    ├── enums/
    │   ├── MockResponseTypeEnum.java                # STATIC / TEMPLATE / SCRIPT / FAKER / PROXY
    │   ├── MockMatchModeEnum.java                   # SCENARIO / EXPECTATION / RANDOM / WEIGHTED
    │   └── MockChaosTypeEnum.java                   # LATENCY / ERROR_RATE / DROP_FIELD / RATE_LIMIT
    ├── config/                                       # Sa-Token / WebClient / Caffeine
    └── mapper/

test-mng-gateway/
└── src/main/java/cloud/aisky/filter/
    ├── GatewayGlobalFilter.java                    # 已存在，改 order = 0
    └── MockRoutingFilter.java                      # 新增，order = -10（必须在 GatewayGlobalFilter 之前？看 4.3 的讨论）
```

### 4.3 网关 Filter 与现有 Filter 的执行顺序

现有 `GatewayGlobalFilter` (order=0) 做两件事：
1. 解析 token → 注入 `X-User-Id` / `X-Enterprise-Id`
2. 校验企业归属

新增的 `MockRoutingFilter` 应该在 **`GatewayGlobalFilter` 之后**执行（order > 0），因为：
- Mock 也需要 `X-User-Id` / `X-Enterprise-Id` 来做租户隔离
- Mock 路由的请求**也要经过企业归属校验**（不能因为加 Mock Header 就绕过权限）

最终顺序：

```
1. (Spring Cloud 内置) RoutePredicate
2. GatewayGlobalFilter (order=0)        — 注入用户/企业 Header + 校验
3. MockRoutingFilter (order=10)          — 新增：检查 X-Mock-Enabled 并改写 routing
4. (内置 NettyRoutingFilter)              — 实际转发
```

### 4.4 三级开关结构（v1.2 D8）

```
┌─────────────────────────────────────────────────────────┐
│ 层 1：space.enable_mock        （tb_space, system 模块）│
│        ON  → 该 space 下所有 Mock 才有意义              │
│        OFF → 跳到穿透流程（即使带 X-Mock-Enabled）      │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 层 2：tb_mock_api.enabled      （单接口开关）           │
│        ON  → 进入期望匹配                                │
│        OFF → 跳到穿透流程                               │
└─────────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────────┐
│ 层 3：tb_mock_expectation.enabled （单条期望开关）      │
│        ON  → 参与 CEL 匹配                              │
│        OFF → 不参与匹配；同接口下其它期望可命中          │
│        若所有 enabled=0 → 跳到穿透流程                  │
└─────────────────────────────────────────────────────────┘

[case 侧的额外开关]
┌─────────────────────────────────────────────────────────┐
│ tb_api_case.enable_mock  （api-test 模块；执行引擎用）   │
│   ON  → case 执行时给请求加 X-Mock-Enabled Header       │
│   OFF → case 执行直接打真实接口（不走 Mock 链路）       │
│   注：开关只决定"是否触发 Mock 路由"，不影响接口期望    │
└─────────────────────────────────────────────────────────┘
```

### 4.5 穿透与环境集成（v1.2 D10/D11）

> 穿透是 v1.2 关键能力——客户端体感"mock 没配就走真实接口"，不需要换 URL / 改 Header / 重试。

#### 4.5.1 穿透时 mock-service 的工作

```
未命中 mock 期望（详见 §6.2 [P] 分支）
    ↓
MockProxyService.passthrough(envId, spaceId, originalRequest, missReason)
    ↓
[1] 调 api-test InnerClient 解析环境
       Feign: POST /environment/inner/resolve-base-url
       入参: { envId, path, apiInfoId, method, spaceId }
       出参: { baseUrl, hostMappings, defaultHeaders, connectTimeoutMs, responseTimeoutMs }
    ↓
[2] 重组请求转发
       target URL = baseUrl + originalPath + originalQuery
       headers 重组：
         - strip：所有 X-Mock-* / X-Space-Id / X-Env-Id（防死循环）
         - 透传：客户端原 Header（Authorization / Cookie / Content-Type / 业务 Header）
         - 追加：env.defaultHeaders（环境默认 Header，如 Bearer token）
       method / body / query 原样转发
    ↓
[3] WebClient / RestTemplate 发请求（超时按 env 配置）
    ↓
[4] 响应原样回给客户端 + 加 X-Mock-Hit: passthrough 响应头
```

#### 4.5.2 环境解析的复杂性（来自现网 api-test 模型）

> 现网 `tb_environment_service_name` 不是简单 base_url，而是按 (env_id, path, directory_id) 多条件路由：

```
tb_environment              ← 环境主表（dev / test / staging）
   │
   └─ tb_environment_service_name (1:N)  ← 一个环境多个服务配置
         字段：service_name / base_url / enable_condition / url_pattern / priority
         enable_condition: 1=无条件 / 2=按目录 / 3=URL 模糊 / 4=URL 精确
         匹配优先级：精确(10) > 模糊(20) > 按目录(30) > 无条件(100)

tb_environment_host  ← host alias（hosts_enabled=1 时改写域名→IP）
```

**关键**：mock-service **不重复造轮子**，把 `(envId, path, apiInfoId, method)` 扔给 api-test 模块的 InnerClient，让它复用现有 case 执行引擎里"按环境解析 URL"的逻辑（业务代码已经存在）。详见 §13.4 跨服务接口契约。

#### 4.5.3 穿透必备的 3 个 Header

```
X-Mock-Enabled: true       ← 触发 mock 路由
X-Space-Id: <currentSpaceId>  ← 隔离空间
X-Env-Id:   <currentEnvId>    ← 穿透时解析真实 URL
```

**任一缺失** → mock-service 返回 400 + 错误信息，提示客户端补 Header。

#### 4.5.4 穿透失败的处理

| 场景 | mock-service 行为 |
|---|---|
| `X-Env-Id` 不存在 | 400 + `{"code":400,"msg":"X-Env-Id Header missing"}` |
| envId 在 api-test 查不到 | 400 + `{"code":400,"msg":"Environment <id> not found"}` |
| envId 有效但 path 在该环境无匹配 service config | 404 + `X-Mock-Hit: passthrough_no_route` |
| api-test InnerClient 调用失败 | 502 + `X-Mock-Hit: passthrough_failed` + `X-Mock-Reason: env_resolve_error` |
| 真实后端连接失败 / 5xx / 超时 | 502 + `X-Mock-Hit: passthrough_failed` + `X-Mock-Reason: upstream_error` |

---

## 5. 网关接入设计（MockRoutingFilter）

### 5.1 Header 协议

| Header | 是否必需 | 说明 | 示例 |
|---|---|---|---|
| `X-Mock-Enabled` | ✅ 总开关 | `true` / `false` 大小写不敏感；缺省 = false（不走 Mock） | `true` |
| `X-Space-Id` | ✅ 必需 | 隔离空间（D4=A，前端 axios 注入） | `1024` |
| **`X-Env-Id`** | ✅ 必需（v1.2） | 环境 ID，mock-service 穿透时用此查 api-test 拿真实 base_url；前端 axios 从 currentEnvironment store 注入；case 执行引擎从 case 配置注入 | `5` |
| `X-Mock-Scenario` | ⭕ 可选 | 场景 ID 或 code | `scene_login_fail` |
| `X-Mock-Expectation` | ⭕ 调试用 | 强指定某条期望，跳过匹配 | `78421` |
| `X-Mock-Delay` | ⭕ Chaos | 临时叠加延迟（毫秒），覆盖期望本身的 delay | `500` |
| `X-Mock-Status` | ⭕ Chaos | 临时强制状态码 | `500` |
| `X-Mock-Record` | ⭕ 录制 | `true` 时透传真实接口并落库为期望 | `true` |
| `X-Mock-Trace` | ⭕ 调试 | `true` 时响应 Header 带 `X-Mock-Hit-Rule-Id` 等命中详情 | `true` |

> **设计权衡**：所有 Mock 控制 Header 都用 `X-Mock-*` 前缀，便于网关层一次性识别和透传。`X-Mock-Enabled` 是唯一的"开关"，其它都是修饰符。

### 5.2 Filter 实现骨架

文件：`test-mng-gateway/src/main/java/cloud/aisky/filter/MockRoutingFilter.java`

```java
package cloud.aisky.filter;

import lombok.extern.slf4j.Slf4j;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.cloud.gateway.support.ServerWebExchangeUtils;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.URI;

/**
 * 检测 X-Mock-Enabled 头并改写路由到 mock-service。
 * 仅做路由分流，不做匹配。
 */
@Slf4j
@Component
public class MockRoutingFilter implements GlobalFilter, Ordered {

    private static final String MOCK_ENABLED_HEADER = "X-Mock-Enabled";
    private static final String MOCK_SERVICE_NAME = "test-mng-mock";
    /** mock-service 数据面入口前缀，与 MockRuntimeController 的 RequestMapping 对齐 */
    private static final String MOCK_RUNTIME_PREFIX = "/__mock";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String path = exchange.getRequest().getURI().getRawPath();
        // 守卫：管理面 / 数据面前缀直接放行，避免循环改写（详见 §5.3）
        // 客户端调 /mock-service/api/page 时即使误带 X-Mock-Enabled 也不能再被改写
        if (path.startsWith("/mock-service/") || path.startsWith(MOCK_RUNTIME_PREFIX)) {
            return chain.filter(exchange);
        }

        String enabled = exchange.getRequest().getHeaders().getFirst(MOCK_ENABLED_HEADER);
        if (!"true".equalsIgnoreCase(enabled)) {
            return chain.filter(exchange);
        }

        URI originalUri = exchange.getRequest().getURI();
        String rewrittenPath = MOCK_RUNTIME_PREFIX + originalUri.getRawPath();
        URI mockUri = URI.create("lb://" + MOCK_SERVICE_NAME + rewrittenPath
                + (originalUri.getRawQuery() != null ? "?" + originalUri.getRawQuery() : ""));

        log.debug("MockRoutingFilter - 转发到 Mock: {} -> {}", originalUri, mockUri);
        exchange.getAttributes().put(ServerWebExchangeUtils.GATEWAY_REQUEST_URL_ATTR, mockUri);
        // 注：ServerWebExchange.attributes 跨进程到 mock-service 后会丢失（见 §0 D5）
        // 不再写 original-path 到 attribute；mock-service 自己用 substring("/__mock".length()) 还原

        return chain.filter(exchange);
    }

    @Override
    public int getOrder() {
        return 10;
    }
}
```

### 5.3 关键决策与权衡

| 决策 | 方案 A | 方案 B | 选定 |
|---|---|---|---|
| **匹配在哪做** | 网关 Filter 内做完匹配并直接返回 | 网关只分流，mock-service 做匹配 | ✅ B —— 隔离故障域，mock-service 可独立扩缩 |
| **路径前缀** | 直接转发（mock-service 用 `/**` 拦截） | 加 `/__mock` 前缀（避免与 mock-service Admin API 冲突） | ✅ 加 `/__mock` 前缀 —— 数据面 / 配置面物理隔离 |
| **Header 名字** | `Mock-Enabled` | `X-Mock-Enabled` | ✅ `X-` 前缀 —— 业界惯例 |
| **失败兜底** | mock-service 返回特殊状态码 → 网关重试到业务 | mock-service 5xx → 网关 fallback | ✅ Spring Cloud Gateway `CircuitBreaker` + `fallbackUri`，确保 mock-service 故障不影响业务 |

### 5.4 fallback 兜底

mock-service 不可用时，必须能让流量自动回落到原业务路由。在 `application.yml` 配置：

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: mock-route-fallback
          uri: lb://test-mng-mock
          predicates:
            - Header=X-Mock-Enabled, true
          filters:
            - name: CircuitBreaker
              args:
                name: mockServiceCircuitBreaker
                fallbackUri: forward:/mock-fallback   # 触发降级时转回真实业务路由
```

**两类"不可用"区分**（v1.1 已确认）：
- **mock-service 进程不可用 / 超时**：连接失败 / 5xx，由 CircuitBreaker 触发，走 `fallbackUri`，**P0 直接返回 `503 Mock Service Unavailable` + `X-Mock-Fallback: unavailable` Header**，客户端摘掉 `X-Mock-Enabled` 重试即可
- **未匹配到任何期望**：业务 200，由 mock-service 内部返回 `404 / X-Mock-Hit: none` 标记响应，由客户端逻辑处理；**不走熔断**

P2 再视情况实现"网关本地 controller 回查 Nacos + WebClient 转发到真实业务"的高级 fallback。

---

## 6. Mock 数据面（test-mng-mock 服务）

### 6.1 Runtime Controller

文件：`test-mng-mock/src/main/java/cloud/aisky/mock/controller/runtime/MockRuntimeController.java`

```java
@RestController
@RequestMapping("/__mock")
@RequiredArgsConstructor
@Tag(name = "Mock 运行时", description = "数据面：匹配并返回 Mock 响应")
public class MockRuntimeController {

    private final MockMatchService matchService;
    private final MockResponseBuilder responseBuilder;
    private final MockCallLogger callLogger;

    @RequestMapping("/**")
    public Mono<ResponseEntity<byte[]>> handle(ServerWebExchange exchange) {
        return matchService.match(exchange)
                .flatMap(matched -> responseBuilder.build(matched, exchange))
                .doOnNext(resp -> callLogger.logAsync(exchange, resp))
                .onErrorResume(NoMatchException.class, e ->
                    Mono.just(ResponseEntity.status(404)
                        .header("X-Mock-Hit", "none")
                        .body(("{\"code\":404,\"msg\":\"未匹配到任何 Mock 期望\"}").getBytes(StandardCharsets.UTF_8))));
    }
}
```

> **技术栈**（v1.1 决策 D3=A）：mock-service 走 **Spring MVC + servlet stack**（`HttpServletRequest` + 阻塞式 MyBatis Plus + 现网通用的 `SessionUtils` / Sa-Token / Knife4j），与所有现网业务微服务一致。
>
> P1 视压测量级（≥5K QPS / 单实例）再考虑 spike WebFlux 改造。
>
> **下方代码骨架原写的是 `Mono<ResponseEntity<byte[]>>`，落地时全部替换为同步 `ResponseEntity<byte[]>` + `HttpServletRequest`**，本文为减少改动暂保留 reactive 写法，实施时以 servlet 为准。

### 6.2 完整匹配流程

```
请求进入 (/__mock/原路径 + Header X-Mock-* / X-Space-Id / X-Env-Id + Body)
    │
    ▼
[1] 解析路由元数据
    spaceId  = X-Space-Id（D4=A，前端 axios 注入；缺失返回 400）
    envId    = X-Env-Id  （D11，前端 axios / case 执行引擎注入；缺失返回 400）
    method   = HTTP method
    path     = request.uri.rawPath.substring("/__mock".length())  -- D5=A
    │
    ▼
[2] 三级开关检查（v1.2 D8）
    ├─ 查 tb_space.enable_mock 是否 ON   → OFF：跳到 [P] 穿透
    ├─ Radix Tree 找 tb_mock_api          → 不存在：跳到 [P] 穿透
    └─ 检查 tb_mock_api.enabled          → OFF：跳到 [P] 穿透
    │
    ▼
[3] 查 MockApi 的 Expectation 列表（已经按 priority desc 缓存）
    若全部 expectation.enabled=0 → 跳到 [P] 穿透
    │
    ▼
[4] 场景过滤
    若 X-Mock-Scenario 存在，先过滤 expectation.scenarioId = 该场景
    否则用接口的"默认场景"
    │
    ▼
[5] 强指定旁路（X-Mock-Expectation）
    若存在该 Header，直接跳到 [7]
    │
    ▼
[6] CEL 表达式过滤
    遍历 expectation，对每一条求值 `expectation.matchExpression`
    （表达式访问 request.headers / request.query / request.body / request.path / state.xxx）
    第一条 true 的命中；全部不命中 → 跳到 [P] 穿透
    │
    ▼
[7] 状态机检查（若 expectation.statefulKey 非空）
    去 Redis 拿当前 state，验证 fromState 匹配，命中则执行 toState 转移
    │
    ▼
[8] 响应组合（详见 §7）
    │
    ▼
[9] Chaos 注入（可选，详见 §8）
    │
    ▼
[10] 异步落日志（matched=1, passthrough=0）+ 返回
       响应头：X-Mock-Hit: expectation:<id>


────────── 穿透分支 [P]（v1.2 D10，详见 §4.5）──────────

[P1] MockProxyService 接管
       in: (envId, spaceId, originalRequest, missReason)
       missReason ∈ { space_disabled | api_not_found | api_disabled | no_match | all_expectations_disabled }
       │
       ▼
[P2] 调 ApiTestInnerClient.resolveBaseUrl(envId, path, apiInfoId?)
       Feign 调 api-test 模块（详见 §4.5 + §13.4 跨服务接口契约）
       返回 { baseUrl, hostMappings, defaultHeaders, connectTimeoutMs, responseTimeoutMs }
       │
       ▼
[P3] 构造转发请求
       target = baseUrl + originalPath + originalQuery
       method / body / queryParams 原样复制
       headers 按以下规则重组：
         ⚠️ strip 所有 X-Mock-* / X-Space-Id / X-Env-Id（防下游再被网关捕获→死循环）
         ✅ 透传客户端原 Header（含 Authorization / Cookie 等）
         ✅ append env.defaultHeaders
       │
       ▼
[P4] WebClient（servlet 下用 RestTemplate / OkHttp）发请求
       超时按 env.connectTimeoutMs / responseTimeoutMs
       │
       ├─ 真实后端 200/2xx/3xx/4xx：原样回给客户端
       │     响应头打 X-Mock-Hit: passthrough
       │              X-Mock-Passthrough-Reason: <missReason>
       │     落日志（matched=0, passthrough=1, miss_reason=<missReason>）
       │
       └─ 真实后端 5xx / 连接失败 / 超时：返回 502
             响应头 X-Mock-Hit: passthrough_failed
             落日志（matched=0, passthrough=0, miss_reason=<missReason>+upstream_error）
```

---

## 7. 响应组合器

### 7.1 响应类型

| 类型 | 阶段 | 字段 | 描述 | 示例 |
|---|---|---|---|---|
| `STATIC` | **P0** | `responseBody` | 直接返回 | `{"code":0}` |
| `TEMPLATE` | **P0** | `responseBody` (Pebble 模板) | Pebble 渲染，能取请求字段、调用 Faker、做循环判断 | `{"id":{{request.body.id}},"now":"{{date('yyyy-MM-dd')}}"}` |
| `PROXY` | **P0**（v1.2 提前）| 由 `X-Env-Id` 解析，无需配置 `proxyUrl` 字段 | 未命中时**自动**穿透，详见 §4.5；P2 录制模式复用此能力 | （穿透行为，不作为 expectation 的可选项） |
| `SCRIPT` | P1 | `scriptType`(JS/Groovy) + `scriptContent` | 沙箱执行，返回 JSON | `function(req){ return {id: req.body.id * 2}; }` |
| `FAKER` | P1 | `responseSchema` (JSON Schema) | 按 Schema 自动生成假数据 | `{"name":"@faker.name.fullName"}` |
| `OPENAPI_EXAMPLE` | P2 | `apiInfoId` | 从该接口的 OpenAPI 定义里取 example | — |

`MockExpectation` 表 `response_type` 字段在第一版只接受 `STATIC` / `TEMPLATE`，其它枚举值预留。

### 7.2 Pebble 模板示例

```
{
  "userId": {{ request.body.id }},
  "name": "{{ faker.name.fullName }}",
  "tokens": [
    {% for i in range(0, 3) %}
    {"seq": {{ i }}, "value": "{{ uuid() }}"}{% if not loop.last %},{% endif %}
    {% endfor %}
  ],
  "now": "{{ date('yyyy-MM-dd HH:mm:ss') }}"
}
```

Pebble 内置函数 + 自定义扩展（`uuid`、`faker.*`、`request.*`、`state.*`）。

### 7.3 GraalJS 脚本示例（P1）

```js
// 入参 request 包含 method, path, query, headers, cookies, body, state
// 返回 { status, headers, body }
function handle(request) {
  const userId = request.body.userId;
  if (userId < 100) {
    return { status: 403, body: { msg: 'forbidden' } };
  }
  return {
    status: 200,
    headers: { 'X-Source': 'mock-script' },
    body: {
      userId,
      tokens: Array.from({length: 3}, (_, i) => ({ seq: i, value: java.util.UUID.randomUUID().toString() }))
    }
  };
}
```

> **沙箱**：使用 GraalVM JS 的 `polyglot Context`，禁用 IO / 进程访问，限定 CPU 时间（`Context.Builder().option("js.timer-resolution-ns", "1000000")`），单次最多 5s。

### 7.4 Faker Schema 示例（P1）

```json
{
  "name": "@faker.name.fullName",
  "email": "@faker.internet.emailAddress",
  "age": "@faker.number.numberBetween(18,80)",
  "address": {
    "city": "@faker.address.cityName",
    "street": "@faker.address.streetAddress"
  },
  "tokens": "@array(3, @faker.lorem.word)"
}
```

`@faker.x.y` 占位符递归替换；`@array(n, expr)` 生成数组。

### 7.5 多响应（加权随机，P1）

`MockExpectation` 支持 N 个 `response`，按 `weight` 加权随机命中（用于 A/B 测试 Mock）：

```
expectation.responses = [
  { weight: 70, body: '{"status":"ok"}', statusCode: 200 },
  { weight: 20, body: '{"status":"degraded"}', statusCode: 200 },
  { weight: 10, body: '{"status":"down"}', statusCode: 500 }
]
```

→ 引入第四张表 `tb_mock_response`，详见 §10。

---

## 8. 高级特性（P1 / P2 阶段）

> 本章特性均**不在第一版（P0）交付**：场景在 P1，状态机 / 录制 / Chaos 在 P2。设计稿放在这里是为锁定数据模型与 Header 协议，避免 P0 落地时埋下不兼容的坑。

### 8.1 场景（Scenario，P1）

**模型**：一个场景是"该接口下若干 expectation 的命名分组"。
**作用**：用户在工作台一键切换 → 客户端 Header 带 `X-Mock-Scenario: xxx` 即可。

```
MockApi（POST /api/login）
  ├── scenario: default        ← 接口默认
  │     └── expectation_1: 登录成功
  ├── scenario: login_fail     ← 模拟登录失败
  │     ├── expectation_2: 用户不存在
  │     └── expectation_3: 密码错误
  └── scenario: rate_limited
        └── expectation_4: 429
```

工作台支持「**全空间一键切场景**」：所有接口的 `default` 场景一键切到 `login_fail`，便于模拟"整个登录链路全挂"的极端场景。

### 8.2 状态机（Stateful Mock，P2）

模拟"按调用次数返回不同响应"或"业务状态流转"：

```
expectation.statefulKey = "order_${request.body.orderId}"
expectation.fromState   = "PENDING"   // 必须当前状态为 PENDING 才能命中
expectation.toState     = "PAID"      // 命中后状态改为 PAID
expectation.responseBody = '{"status":"PAID"}'
```

**存储**：Redis Hash，key = `mock:state:{spaceId}:{statefulKey}`，TTL 24h（可配）。

**并发安全**：`查 state → 校验 fromState → 写 toState` 三步必须**原子**，否则两个并发请求会同时穿过 PENDING→PAID 的检查。实现走 Redis `EVAL` Lua 脚本：

```lua
-- KEYS[1] = key, ARGV[1] = fromState, ARGV[2] = toState, ARGV[3] = ttlSeconds
local cur = redis.call('GET', KEYS[1])
if cur == false or cur == ARGV[1] then
  redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
  return 1
end
return 0
```

**禁止**用客户端两步 GET+SET 实现，会有竞态。

**工作台支持**：列出当前所有 stateful key 的实时 state、支持手动重置。

### 8.3 录制回放（Record & Replay，P2）

**录制**：
1. 工作台进入接口 → 点击「开启录制」→ 设置真实后端 URL（如 `https://staging.api.com`）
2. 客户端 Header 加 `X-Mock-Record: true`
3. mock-service 接到请求 → 透传到真实后端 → 拿到响应 → 异步写入 `tb_mock_expectation` 一条新期望
4. 工作台显示"录制到 N 条" → 用户审阅、修改、保留

**回放**：录制完成后，去掉 `X-Mock-Record`，使用普通 `X-Mock-Enabled: true` 即可命中刚才录制的期望。

**实现关键点**：
- 录制时**条件自动归纳**：若两个请求的 query 不同但 body 相同，归纳为"按 query 命中条件"；可配置归纳策略（精确 / 模糊）。
- **敏感字段处理**：录制**存原值**（DB 字段加密，复用 storage 模块的加解密能力），**列表/详情展示时脱敏**（token / Authorization / 手机号 / 身份证用 `***` 替换）。
  > 早期方案是"录制时直接替换为占位符"——但回放时如果下游 API 校验 token 会直接 401/404，破坏录制语义。所以**存储与展示分离**：原始保留以便回放，UI 上脱敏避免泄露。

### 8.4 Chaos 故障注入（P2）

通过 Header `X-Mock-Chaos` 或 expectation 配置启用：

```
X-Mock-Chaos: latency=500-2000;error_rate=0.1;drop_field=token
```

| Chaos 类型 | 实现 |
|---|---|
| `latency` | 在响应前 `Mono.delay(...)`（**不能用 Thread.sleep**） |
| `error_rate` | 概率返回随机 5xx |
| `drop_field` | 渲染响应后从 JSON 删字段 |
| `rate_limit` | 接口级 Redis 计数器，超过阈值返回 429 |
| `chunked_slow` | 把响应分块慢速发送（模拟网络慢） |

---

## 9. DSL 与匹配引擎

### 9.1 路径索引（Radix Tree）

替换当前的"按 spaceId+method 全表扫 + 字符串 startsWith 匹配"的 O(n) 逻辑：

```
入参: (spaceId, method, path = "/api/user/123/orders")

索引结构（按 spaceId+method 分桶）：
  /api/user/{userId}/orders         → MockApi#42
  /api/user/{userId}/profile        → MockApi#43
  /api/order/{orderId}              → MockApi#44
  /api/order/list                   → MockApi#45  (静态优先于变量段)

查找复杂度: O(L)，L = 路径段数
```

实现选型：
- 自研 Radix Tree（参考 Spring `PathPattern` 思路）
- 或直接用 `org.springframework.web.util.pattern.PathPattern` + `PathPatternParser`（Spring 内置，已支持 `{var}`、`*`、`**` 通配）

> **决策**：用 `PathPattern` —— 复用 Spring 成熟实现，避免重造轮子。

### 9.2 表达式求值（CEL）

**为什么不用当前的 13 个枚举操作符**：表达力差、AND-only、跨字段组合不了。

**选型 CEL（Common Expression Language）**：
- Google 出品、JVM 官方实现 `org.projectnessie.cel:cel-core`
- 性能高（编译后缓存 AST）
- 表达力够：算术、逻辑、字符串、列表、Map、正则、时间
- 安全：纯函数、无副作用、可超时

**示例**：

```cel
// 命中条件
request.headers["X-User-Id"] in [1001, 1002]
  && request.body.amount > 100
  && request.query["region"].startsWith("cn-")
  && (request.body.tags.exists(t, t == "vip") || request.body.level >= 5)
```

**工作台两种编辑方式**：
- **新手**：表单填条件（位置 + 字段 + 操作符 + 值）→ 自动生成 CEL
- **进阶**：Monaco Editor 直接写 CEL，配语法提示

> **互转能力的边界**：表单 → CEL 一定可生成；CEL → 表单**仅支持基础形态**（`a == b && c > d` 这类纯 AND 的简单条件，且每个原子条件都对应到「字段 + 操作符 + 字面量」）。包含 `||` 混合、嵌套 `exists()` / `all()`、自定义函数、函数返回值再比较的表达式**不保证可反推回表单**——此时 UI 自动切到"高级模式：仅 CEL 编辑"并在表单按钮上提示"当前条件含高级语法，已切到 CEL 模式"。

### 9.3 IP 条件 / CIDR 匹配

支持单 IP / CIDR / 黑白名单：

```cel
request.clientIp in cidrRange("10.0.0.0/24") || request.clientIp == "127.0.0.1"
```

`cidrRange` 作为自定义 CEL 函数注册。`request.clientIp` 由 mock-service 从 `X-Forwarded-For` / `X-Real-IP` 解析。

---

## 10. 数据模型

### 10.1 库与 schema

**复用现有 `tp_interface` 库**（不新建独立库），表前缀 `tb_mock_*` 与现有 `tb_api_*` 自带命名隔离。

> 决策依据（v1.1 已确认）：
> - 现网 `api-test` 与 `api-test-execution` 已经是"两个微服务共用 `tp_interface`"的成熟模式，mock-service 沿用该模式
> - mock 与接口管理同业务域，`tb_mock_api.api_info_id` → `tb_api_info.id` 同库后可加外键约束、便于 join
> - 节省 P0 前置任务：不需要申请新库 / 新凭据 / 新 datasource / 在 `db_query.py` 加 DB_CREDS
> - 调用日志膨胀风险靠 7 天 TTL + 单表行数控制；写入端抽象 `MockCallLogRepository`，量级真起来再迁移到独立库 / ClickHouse
>
> **未来何时迁出**：① 单日调用日志 > 100 万；② mock 服务被外部团队接入需要独立 SLA；③ 备份/扩缩策略与 api-test 出现明显分歧。

### 10.2 表结构

#### 表 1：`tb_mock_api`（接口 → Mock 配置主表）

```sql
CREATE TABLE tb_mock_api (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键ID',
    space_id BIGINT NOT NULL COMMENT '空间ID',
    enterprise_id BIGINT NOT NULL COMMENT '企业ID',
    api_info_id BIGINT DEFAULT NULL COMMENT '关联 tb_api_info.id（同库可加 FK，ON DELETE SET NULL）',
    method VARCHAR(10) NOT NULL COMMENT 'HTTP 方法',
    path VARCHAR(500) NOT NULL COMMENT '原始路径，支持 {var} 占位符；超长部分不参与唯一索引（见下方索引设计）',
    enabled TINYINT DEFAULT 1 COMMENT '【接口级 mock 开关，v1.2 D8 第 2 层】1=ON，该接口的 mock 期望生效；0=OFF，匹配跳过该接口直接穿透',
    default_scenario_id BIGINT DEFAULT NULL COMMENT '默认场景ID',
    record_enabled TINYINT DEFAULT 0 COMMENT '是否录制中（P2）',
    create_user_id BIGINT,
    modify_user_id BIGINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted TINYINT DEFAULT 0,
    -- ⚠️ utf8mb4 下 VARCHAR(500) 索引 = 2000 字节，超过 InnoDB 默认 768/3072 字节 prefix 限制；
    --   建表前在 dev MariaDB 13307 dry-run 验证；落地方案二选一：
    --   (1) path 改 VARCHAR(192)（utf8mb4 768 字节内）—— 简单直接，要约束业务路径长度
    --   (2) 加冗余列 path_hash CHAR(32) GENERATED ALWAYS AS (MD5(path)) STORED，唯一索引建在 hash 上
    UNIQUE INDEX uk_space_method_path (space_id, method, path, deleted),
    INDEX idx_enterprise (enterprise_id, deleted),
    INDEX idx_api_info (api_info_id, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 接口配置表';
```

> **`path_pattern` 字段已移除**：原设计存"原始 path + Spring PathPattern 字符串"两份冗余；但 PathPattern 完全可由 path 推导（`PathPatternParser` 直接解析），存两份反而引入一致性风险。**只存 `path`，运行时缓存编译后的 `PathPattern` 对象**（启动时全量构建 + CRUD 后增量刷新）。

#### 表 2：`tb_mock_scenario`（场景）

```sql
CREATE TABLE tb_mock_scenario (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    space_id BIGINT NOT NULL,
    enterprise_id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL COMMENT '场景名称',
    code VARCHAR(50) NOT NULL COMMENT '场景 code，客户端 Header 用',
    description VARCHAR(500),
    scope ENUM('SPACE','API') DEFAULT 'API' COMMENT 'SPACE=空间级（跨接口）, API=接口级',
    api_id BIGINT DEFAULT NULL COMMENT 'scope=API 时关联的 tb_mock_api.id',
    is_default TINYINT DEFAULT 0,
    create_user_id BIGINT,
    modify_user_id BIGINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted TINYINT DEFAULT 0,
    UNIQUE INDEX uk_space_code (space_id, code, scope, api_id, deleted),
    INDEX idx_api (api_id, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 场景表';
```

#### 表 3：`tb_mock_expectation`（期望）

```sql
CREATE TABLE tb_mock_expectation (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    space_id BIGINT NOT NULL COMMENT '冗余字段（与 tb_mock_api.space_id 一致），运行时缓存按 space_id 分桶，避免 join',
    api_id BIGINT NOT NULL COMMENT '关联 tb_mock_api.id',
    scenario_id BIGINT NOT NULL COMMENT '关联 tb_mock_scenario.id',
    name VARCHAR(100) NOT NULL,
    enabled TINYINT DEFAULT 1,
    priority INT DEFAULT 0 COMMENT '优先级，数值越大越优先',
    match_expression TEXT COMMENT 'CEL 匹配表达式',
    match_form_json JSON COMMENT '工作台表单形式（用于回显，可与 match_expression 互转，互转边界见 §9.2）',

    -- Stateful
    stateful_key VARCHAR(200) DEFAULT NULL,
    from_state VARCHAR(50) DEFAULT NULL,
    to_state VARCHAR(50) DEFAULT NULL,

    -- 单响应（多响应见 tb_mock_response）
    response_type ENUM('STATIC','TEMPLATE','SCRIPT','FAKER','OPENAPI_EXAMPLE','MULTI') DEFAULT 'STATIC'
        COMMENT '响应类型；MULTI 表示从 tb_mock_response 加权随机；MULTI 不可嵌套 MULTI（tb_mock_response.response_type 不含 MULTI）；不含 PROXY——v1.2 D10 后 PROXY 是"未命中自动穿透"的全局行为，由 X-Env-Id 决定 base_url，不作为 expectation 的可选项',
    response_body MEDIUMTEXT,
    response_headers JSON COMMENT '格式锁定为数组：[{"name":"X-Foo","value":"bar"}]；不接受对象形式 {"k":"v"}（避免历史 P14 的兼容问题）',
    response_status_code INT DEFAULT 200,
    content_type VARCHAR(100) DEFAULT 'application/json',
    delay_ms INT DEFAULT 0,
    script_type ENUM('JS','GROOVY','PYTHON','BEANSHELL') DEFAULT NULL
        COMMENT '与 test-mng-api-test-execution 模块支持的脚本引擎对齐；P0 不实现，P1 起接 GraalJS / Groovy',

    -- 录制
    recorded_from VARCHAR(500) DEFAULT NULL COMMENT '录制来源 URL',
    recorded_at TIMESTAMP DEFAULT NULL,

    create_user_id BIGINT,
    modify_user_id BIGINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted TINYINT DEFAULT 0,
    INDEX idx_space_api (space_id, api_id, enabled, deleted),
    INDEX idx_api_scenario (api_id, scenario_id, enabled, deleted),
    INDEX idx_priority (api_id, priority DESC, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 期望表';
```

#### 表 4：`tb_mock_response`（多响应，加权随机）

```sql
CREATE TABLE tb_mock_response (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    expectation_id BIGINT NOT NULL,
    weight INT DEFAULT 100 COMMENT '加权随机的权重',
    response_type ENUM('STATIC','TEMPLATE','SCRIPT','FAKER') DEFAULT 'STATIC' COMMENT '不含 MULTI——MULTI 不可嵌套',
    response_body MEDIUMTEXT,
    response_headers JSON COMMENT '格式与 tb_mock_expectation.response_headers 保持一致：[{"name":"X-Foo","value":"bar"}]',
    response_status_code INT DEFAULT 200,
    content_type VARCHAR(100) DEFAULT 'application/json',
    delay_ms INT DEFAULT 0,
    sort_order INT DEFAULT 0,
    INDEX idx_expectation (expectation_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 多响应';
```

> 仅当 `tb_mock_expectation.response_type = 'MULTI'` 时生效。

#### 表 5：`tb_mock_chaos_rule`（Chaos 规则）

```sql
CREATE TABLE tb_mock_chaos_rule (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    space_id BIGINT NOT NULL,
    enterprise_id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    target_type ENUM('GLOBAL','API','EXPECTATION') NOT NULL,
    target_id BIGINT DEFAULT NULL,
    chaos_type ENUM('LATENCY','ERROR_RATE','DROP_FIELD','RATE_LIMIT','CHUNKED_SLOW') NOT NULL,
    config_json JSON NOT NULL COMMENT '具体参数，如 {"min":500,"max":2000} 或 {"rate":0.1,"status":500}',
    enabled TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_target (target_type, target_id, enabled)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Chaos 规则表';
```

#### 表 6：`tb_mock_call_log`（调用日志，第一版直接 MySQL 单表）

```sql
CREATE TABLE tb_mock_call_log (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    trace_id CHAR(32) NOT NULL,
    space_id BIGINT NOT NULL,
    enterprise_id BIGINT NOT NULL,
    env_id BIGINT DEFAULT NULL COMMENT '环境ID（v1.2，从 X-Env-Id 取，穿透时必填）',
    api_id BIGINT,
    expectation_id BIGINT,
    scenario_id BIGINT,
    case_id BIGINT DEFAULT NULL COMMENT '若调用来自 case 执行（X-Mock-Source: case），记录 case_id 便于审计',
    method VARCHAR(10),
    path VARCHAR(500),
    status_code INT,
    cost_ms INT,
    matched TINYINT COMMENT '1=mock 命中；0=未命中',
    passthrough TINYINT DEFAULT 0 COMMENT 'v1.2：1=已穿透到真实后端（含成功/失败）；0=mock 命中或彻底失败未穿透',
    miss_reason VARCHAR(64) DEFAULT NULL COMMENT '未命中原因：space_disabled / api_not_found / api_disabled / no_match / all_expectations_disabled / env_resolve_error / upstream_error',
    upstream_url VARCHAR(1000) DEFAULT NULL COMMENT 'v1.2：穿透时实际转发的真实 URL（含 query），便于排查',
    upstream_cost_ms INT DEFAULT NULL COMMENT 'v1.2：穿透时下游真实接口的耗时',
    request_headers MEDIUMTEXT,
    request_query MEDIUMTEXT,
    request_body MEDIUMTEXT,
    response_headers MEDIUMTEXT,
    response_body MEDIUMTEXT,
    chaos_applied VARCHAR(255) DEFAULT NULL,
    client_ip VARCHAR(64),
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_trace (trace_id),
    INDEX idx_space_time (space_id, create_time DESC),
    INDEX idx_api_time (api_id, create_time DESC),
    INDEX idx_passthrough (passthrough, create_time DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 调用日志（含穿透）';
```

> **保留期 7 天**，由独立定时任务按 `create_time` 清理；如 body 体积大，超阈值（如 1MB）截断并打标。
> 写入侧统一走 `MockCallLogRepository`，方便后续切到 ClickHouse / Kafka 时不动业务代码。

### 10.3 ER 图

```
tb_mock_api 1 ───── N tb_mock_scenario       (一个接口可有多个场景)
       │
       │ 1:N
       ▼
tb_mock_expectation ─── 1 tb_mock_scenario  (期望必须属于某个场景)
       │
       │ 1:N (仅 response_type=MULTI 时)
       ▼
tb_mock_response

tb_mock_chaos_rule  → target_type+target_id 软关联到 api / expectation

tb_mock_call_log       → 关联 api/expectation，但运行时不强约束
```

### 10.4 与现有 `tb_api_*` / `tb_space` 表的关系

> v1.1 库归属决策改为"复用 `tp_interface`"后，`tb_mock_*` 与 `tb_api_*` **同库共存**，可以加外键约束、可以 join。
> v1.2 D8 三级开关结构 + D9 case 引用接口期望，需要在现有表上**加 2 个字段**。

| 方向 | 关系 |
|---|---|
| `tb_mock_api.api_info_id` → `tb_api_info.id` | **同库可加外键** `FK_mock_api__api_info` ON DELETE SET NULL；便于"从接口详情跳到 Mock 配置" / 跨表 join 列表查询 |
| 接口创建时 → **延迟创建 mock_api** | 接口创建**不预创建** `tb_mock_api`；用户**第一次在接口详情页开启 Mock 开关**时 mock-service 才落库 |
| 接口删除时 | 利用外键 `ON DELETE SET NULL`：`tb_api_info` 删除后 `tb_mock_api.api_info_id` 自动置空（成为"游离 mock"，用户可手动删除或重新关联） |
| **`tb_space.enable_mock`**（新增字段）| **D8 第 1 层开关**：space 总开关，OFF 时该 space 下所有 mock 都不生效（即使带 X-Mock-Enabled 也直接穿透）；属于 `tp_system` / system 模块 |
| **`tb_api_case.enable_mock`**（新增字段，api-test 模块）| **D9 落地**：case 上的开关，ON 时执行引擎给请求加 `X-Mock-Enabled` Header；OFF 时 case 直接打真实接口；不影响接口期望本身 |

#### 10.4.1 现有表的字段新增 SQL

> 这两条 ALTER 不在 `sql/mock/mysql/` 下，而是分别加到对应模块的 migration 目录：

```sql
-- 系统模块（test-mng-system，库 tp_system）
-- 路径：test-mng-system/src/main/resources/db/migration/V<date>__add_enable_mock_to_space.sql
ALTER TABLE tb_space
    ADD COLUMN enable_mock TINYINT NOT NULL DEFAULT 0
    COMMENT 'space 级 Mock 总开关（v1.2 D8 第 1 层）：0=OFF / 1=ON' AFTER <某字段>;
```

```sql
-- API 测试模块（test-mng-api-test，库 tp_interface）
-- 路径：test-mng-api-test/src/main/resources/db/migration/V<date>__add_enable_mock_to_api_case.sql
ALTER TABLE tb_api_case
    ADD COLUMN enable_mock TINYINT NOT NULL DEFAULT 0
    COMMENT 'case 执行时是否走 mock（v1.2 D9）：0=OFF（直接打真实）/ 1=ON（执行引擎给请求加 X-Mock-Enabled Header）' AFTER <某字段>;
```

⚠️ **DDL 落地前**用 query-dev-db skill 确认 `tb_space` / `tb_api_case` 当前列结构再决定 `AFTER <某字段>` 放哪。

#### 10.4.2 跨模块责任划分

| 模块 | 持有 | 负责 |
|---|---|---|
| **system** | `tb_space.enable_mock` | space 设置页"Mock 总开关"的 CRUD；mock-service 通过 SystemInnerClient 查询 |
| **api-test** | `tb_api_case.enable_mock` + 环境配置（tb_environment_*） | case 编辑页 mock 开关；执行引擎按 enable_mock 决定是否加 Header；提供 InnerClient 给 mock-service 查环境（§4.5） |
| **mock-service**（新） | `tb_mock_api.enabled` + `tb_mock_expectation.enabled` | 接口/期望级开关；不直接持有 space.enable_mock 和 case.enable_mock，按需 RPC 查询 |

---

## 11. 配置存储与热更新

### 11.1 三层缓存结构

```
[Mock 服务实例 N]                       [Redis]                   [MySQL]
┌──────────────────┐    miss          ┌──────────────────┐  miss  ┌──────────────┐
│ 本地 Caffeine    │ ───────────────▶ │ Redis Hash       │ ─────▶ │ tp_interface │
│ - 全量规则索引   │                  │ - 热点期望        │        │ tb_mock_*    │
│ - PathPattern 树 │                  │ - 状态机          │        │              │
│ - 期望详情(LRU)  │                  │ - Chaos 规则      │        │              │
└──────────────────┘                  └──────────────────┘        └──────────────┘
        ▲                                      ▲                       │
        │ 订阅                                  │                       │
        │                                      │                       │
        └────── Redis pub/sub: mock:invalidate ◀───── 配置面 CRUD ─────┘
```

### 11.2 启动时全量加载

mock-service 启动时一次性查 `tb_mock_api` + `tb_mock_expectation`（按 `space_id, deleted=0`），构建：
1. 每个 `(spaceId, method)` 对应一棵 `PathPattern` 树
2. 每个 expectation 编译为 CEL `Program`（缓存 AST）
3. 全部塞 Caffeine

数据量预估（内部测试平台，按上限估）：
- 100 空间 × 50 接口 × 3 期望 ≈ 1.5 万 expectation
- 每条 expectation 内存 ~2KB → ~30MB
- → 单实例 JVM 堆 1-2GB 完全够用；后期量级真起来再水平扩展

### 11.3 热更新

**配置面 CRUD 完成后**：
1. 写 MySQL
2. 写 Redis（删 cache key）
3. 发 Redis pub/sub 消息：`PUBLISH mock:invalidate {"spaceId":42, "apiId":100, "type":"expectation_changed"}`
4. 所有 mock-service 实例订阅该 channel，收到后增量刷新本地 Caffeine

**对账兜底**：Redis pub/sub **不保证投递**——订阅者宕机/网络抖动期间消息丢失，新启动实例订阅前发布的消息也收不到。每个 mock-service 实例额外开**每 60s 全量对账任务**：

```
SELECT MAX(update_time) FROM tb_mock_api WHERE deleted=0;
SELECT MAX(update_time) FROM tb_mock_expectation WHERE deleted=0;
```

与本地 Caffeine 记录的 `lastSyncTime` 比对，发现新增量再增量加载；保证 pub/sub 失效时**最迟 60s** 配置仍能生效。

**最终一致性**：≤ 3 秒（pub/sub 走通时） / ≤ 60 秒（pub/sub 失效降级到对账）。

**回滚**：删 Caffeine 即可，下次请求自动从 MySQL 重建。

---

## 12. 可观测性

### 12.1 调用日志架构

```
mock-service
    │
    ▼  非阻塞 offer (有界 BlockingQueue, capacity=10000)
[内存队列]
    │
    ▼  定时调度（500 条 / 1s 触发，二者先到为准）
批量 INSERT
    │
    ▼
MySQL: tb_mock_call_log（DDL 见 §10.2 表 6）
```

关键点：
- **有界队列** + 拒绝策略 `discardOldest`：日志洪峰时优先丢老日志，保业务不被反压
- **应用 graceful shutdown** 时 drain 队列再退出
- **降级开关**：`mock.audit.enabled=false` 时全链路跳过日志，故障时一键关
- **TTL**：定时任务 7 天 / 30 天清理（按需配置），单表行数受控

### 12.2 后续演进路径（不在第一版做）

写入端抽象为 `MockCallLogRepository` 接口，触发以下任一条件时再切：

| 信号 | 切换方向 |
|---|---|
| 单表行数 > 5000 万 / 写入 P99 > 100ms | 按月分表，或切 ClickHouse |
| 出现削峰 / 多消费者（告警、计费、审计）需求 | 引入 Kafka topic 解耦 |
| 大范围聚合查询变慢（如全平台命中热力图） | 切 ClickHouse |

### 12.3 前端查询能力

工作台「调用日志」标签页：
- 列：时间 / 接口 / 命中规则 / 状态码 / 耗时 / 调用方 IP
- 过滤：时间范围 / 接口 / 状态 / 命中状态（命中/未命中）
- 详情抽屉：完整请求 + 响应、命中详情（CEL 求值过程）、Chaos 注入信息

### 12.4 Metrics

mock-service 暴露 Prometheus 指标：
- `mock_request_total{space, method, status, matched}`
- `mock_request_duration_seconds_bucket{...}`
- `mock_match_failure_total{reason}`
- `mock_cache_hit_ratio{layer}` — Caffeine / Redis 命中率
- `mock_script_execution_duration_seconds_bucket`

---

## 13. 管理端 API 设计

### 13.1 路径前缀

所有配置面 API 走网关路由 `/mock-service/**` → `test-mng-mock`。

### 13.2 核心接口

> v1.2 D7=B 完全分散式后：
> - 「Mock 中心独立菜单」对应的 API（场景批量切等"全局视图"接口）**全部下沉到接口/space 维度**
> - 接口 Mock Tab 直接调本表的接口；case 的 Mock 开关在 api-test 模块用 `tb_api_case.enable_mock` 字段，不通过 mock-service API
> - **space 总开关** 在 system 模块（`tb_space.enable_mock`），不在 mock-service

| 类别 | 阶段 | 路径 | 方法 | 说明 |
|---|---|---|---|---|
| **MockApi**（接口层）| P0 | `/mock-service/api/by-api-info` | POST | 根据 `apiInfoId` 查 mock 主表（接口 Mock Tab 进来时调用；不存在返回空） |
| | P0 | `/mock-service/api/create-or-enable` | POST | 第一次开 Mock 开关时**延迟创建** mock_api 主表（D9 配套）|
| | P0 | `/mock-service/api/toggle` | POST | 接口级 mock 开关（写 `tb_mock_api.enabled`）|
| | P0 | `/mock-service/api/{id}` | GET | 详情 |
| | P0 | `/mock-service/api/delete` | POST | 软删（用户主动清除该接口的 mock 配置）|
| | P2 | `/mock-service/api/from-openapi` | POST | 从 OpenAPI 一键导入期望 |
| **Expectation**（期望）| P0 | `/mock-service/expectation/list-by-api` | POST | 列出某接口下所有期望（接口 Mock Tab 主体内容）|
| | P0 | `/mock-service/expectation/create` | POST | 新建 |
| | P0 | `/mock-service/expectation/update` | POST | 更新 |
| | P0 | `/mock-service/expectation/delete` | POST | 删除 |
| | P0 | `/mock-service/expectation/toggle` | POST | 单条启用/禁用（截图右侧开关）|
| | P0 | `/mock-service/expectation/preview-response` | POST | 预览响应（不真正命中，渲染一次给前端看，截图眼睛图标）|
| | P0 | `/mock-service/expectation/validate-cel` | POST | 校验 CEL 表达式语法 |
| | P1 | `/mock-service/expectation/clone` | POST | 克隆到另一个场景 |
| **Scenario**（场景，接口维度）| P1 | `/mock-service/scenario/list-by-api` | POST | 该接口下的场景列表 |
| | P1 | `/mock-service/scenario/create` | POST | 创建（接口 Mock Tab 内的场景下拉）|
| | P1 | `/mock-service/scenario/update` | POST | 更新 |
| | P1 | `/mock-service/scenario/set-default` | POST | 设为该接口默认 |
| **CallLog**（调用日志，接口维度）| P1 | `/mock-service/call-log/list-by-api` | POST | 该接口的调用日志（接口 Mock Tab 内"日志"子 Tab）|
| | P1 | `/mock-service/call-log/list-by-space` | POST | space 级调用日志（space 设置 - Mock 子页）|
| | P1 | `/mock-service/call-log/{traceId}` | GET | 详情 |
| **Space**（space 级 Mock 配置）| P0 | `/system/space/toggle-mock` | POST | space 总开关（**system 模块提供**，不是 mock-service；写 `tb_space.enable_mock`）|
| | P1 | `/mock-service/space/stats` | POST | space 级统计（开了 mock 的接口数、命中率等，space 设置 - Mock 子页用）|
| **Record** | P2 | `/mock-service/record/start` | POST | 开始录制（接口 Mock Tab 内）|
| | P2 | `/mock-service/record/stop` | POST | 停止录制 |
| | P2 | `/mock-service/record/recorded-list` | POST | 列出本次录制结果 |
| | P2 | `/mock-service/record/save-as-expectation` | POST | 把录制结果转为期望 |
| **Chaos** | P2 | `/mock-service/chaos/list-by-api` | POST | 接口维度 Chaos 规则列表 |
| | P2 | `/mock-service/chaos/list-by-space` | POST | space 全局 Chaos 规则（space 设置）|
| | P2 | `/mock-service/chaos/create` | POST | 新增 |
| | P2 | `/mock-service/chaos/toggle` | POST | 启用/禁用 |
| **State** | P2 | `/mock-service/state/list` | POST | 状态机 key 列表（接口 Mock Tab 内）|
| | P2 | `/mock-service/state/reset` | POST | 重置某个 key 的 state |

### 13.3 DTO/VO 规范（遵循项目 memory）

所有 DTO/VO 字段必须带 `@Schema(description=..., example=..., requiredMode=...)`，参考：

```java
@Schema(description = "Mock 期望创建参数")
public class MockExpectationCreateDTO {
    @Schema(description = "关联接口 ID", example = "101", requiredMode = Schema.RequiredMode.REQUIRED)
    @NotNull
    private Long apiId;

    @Schema(description = "场景 ID", example = "5", requiredMode = Schema.RequiredMode.REQUIRED)
    @NotNull
    private Long scenarioId;

    @Schema(description = "期望名称", example = "登录失败-密码错误", requiredMode = Schema.RequiredMode.REQUIRED)
    @NotBlank
    @Size(max = 100)
    private String name;

    @Schema(description = "CEL 匹配表达式",
            example = "request.body.password != 'correct'",
            requiredMode = Schema.RequiredMode.REQUIRED)
    @NotBlank
    private String matchExpression;

    @Schema(description = "响应类型（v1.2：PROXY 已下线，由 X-Env-Id 全局穿透替代）",
            allowableValues = {"STATIC","TEMPLATE","SCRIPT","FAKER","OPENAPI_EXAMPLE","MULTI"},
            example = "STATIC")
    private String responseType;

    // ... 其余字段
}
```

### 13.4 跨服务接口契约（v1.2 新增）

> mock-service 通过 Feign 调用以下 InnerClient，不直接访问外部模块的库表。

#### 13.4.1 ApiTestInnerClient（mock-service → api-test）

**用途**：穿透时解析环境对应的 base_url（§4.5.2）。

```java
@FeignClient(name = "api-test-service")
public interface ApiTestInnerClient {

    @PostMapping("/environment/inner/resolve-base-url")
    JsonDataVO<EnvBaseUrlResolveVO> resolveBaseUrl(@RequestBody EnvBaseUrlResolveDTO dto);

    /** 查询接口元信息（mock_api 延迟创建时用）*/
    @PostMapping("/api-info/inner/get-by-id")
    JsonDataVO<ApiInfoInnerVO> getApiInfo(@RequestBody ApiInfoIdDTO dto);
}
```

**`EnvBaseUrlResolveDTO`**（mock-service 定义、api-test 共享）：
```java
@Schema(description = "环境 base_url 解析参数")
public class EnvBaseUrlResolveDTO {
    @Schema(description = "环境ID（来自 X-Env-Id Header）", example = "5", requiredMode = REQUIRED)
    @NotNull private Long envId;

    @Schema(description = "空间ID", example = "1024", requiredMode = REQUIRED)
    @NotNull private Long spaceId;

    @Schema(description = "接口路径（已 strip /__mock 前缀）", example = "/api/cart/remove/123",
            requiredMode = REQUIRED)
    @NotBlank private String path;

    @Schema(description = "HTTP 方法", example = "POST", requiredMode = REQUIRED)
    @NotBlank private String method;

    @Schema(description = "接口 ID（可选，用于按 directory_ids 匹配）", example = "2031006")
    private Long apiInfoId;
}
```

**`EnvBaseUrlResolveVO`**：
```java
@Schema(description = "环境解析结果")
public class EnvBaseUrlResolveVO {
    @Schema(description = "解析出的 base URL（命中的 environment_service_name.base_url）",
            example = "https://dev-api.example.com")
    private String baseUrl;

    @Schema(description = "host 映射（hosts_enabled=1 时返回；穿透时 DNS 改写）")
    private List<HostMapping> hostMappings;

    @Schema(description = "环境默认 Header（来自 environment_service_name.headers）")
    private List<NameValue> defaultHeaders;

    @Schema(description = "连接超时（毫秒）", example = "5000")
    private Integer connectTimeoutMs;

    @Schema(description = "响应超时（毫秒）", example = "30000")
    private Integer responseTimeoutMs;

    @Schema(description = "命中的服务配置 ID", example = "12")
    private Long matchedServiceConfigId;

    @Schema(description = "未命中时为 null；mock-service 应返回 404")
    private String hitDetail;
}
```

> **api-test 模块的责任**：复用现有 case 执行引擎里"按环境解析 URL"的逻辑（业务代码已经存在），抽出 `EnvironmentResolveService` 暴露给这个 InnerClient。

#### 13.4.2 SystemInnerClient（mock-service → system）

**用途**：查询 space.enable_mock（D8 第 1 层开关检查）。

```java
@FeignClient(name = "system-service")
public interface SystemInnerClient {

    @PostMapping("/space/inner/get-mock-enabled")
    JsonDataVO<Boolean> isSpaceMockEnabled(@RequestBody SpaceIdDTO dto);
}
```

**性能考虑**：space 总开关查询频率极高（每次 Mock 请求都要查），mock-service 在本地 Caffeine 缓存 `(spaceId → enable_mock)`，TTL 60s + Redis pub/sub 失效；不直接 RPC 调每次请求。

---

## 14. 前端改造（v1.2 完全分散式）

> v1.2 D7=B：**不新增独立菜单**。Mock 配置长在每个接口/case 详情页里，跨接口的全局视图（统计 / Chaos / 全局调用日志）放在 space 设置 - Mock 子页。

### 14.1 改动点总览

```
┌──────────────────────────────────────────────────────────────┐
│ 1. 接口详情页（已有页面，加 Mock Tab + 右上角开关）            │
│    src/views/api-module/.../ApiDetailLayout.vue（或类似）     │
│      ├─ 右上角：[Mock 开关 toggle]（v1.2）                    │
│      └─ Tab 栏：接口详情 / 用例列表 / 文档 / 【Mock】（已有/扩展）│
│           └─ Mock Tab 内容 = ApiMockTab.vue（重写）            │
├──────────────────────────────────────────────────────────────┤
│ 2. case 编辑页（已有页面，加 Mock 开关字段）                   │
│    src/views/case/.../CaseEditDialog.vue（或类似）            │
│      └─ 表单加一项：[启用 Mock] toggle（写 tb_api_case.enable_mock）│
├──────────────────────────────────────────────────────────────┤
│ 3. space 设置 - Mock 子页（新增 1 个 Tab）                     │
│    src/views/system/.../SpaceSettingDialog.vue（已有，加 Tab）│
│      └─ Mock 子 Tab：                                         │
│          ├─ space 总开关 toggle（写 tb_space.enable_mock）    │
│          ├─ 全局调用日志（list-by-space）                     │
│          ├─ 全局 Chaos 规则（P2）                             │
│          └─ space 级 mock 接口数 / 命中率统计                 │
├──────────────────────────────────────────────────────────────┤
│ 4. axios interceptor（src/api/index.ts 或 utils/request.ts）  │
│      ├─ 加 X-Space-Id（D4=A）                                │
│      ├─ 加 X-Env-Id（v1.2 D11）                              │
│      └─ 当 space.enable_mock=ON && api.enable_mock=ON 时       │
│        加 X-Mock-Enabled: true                                │
└──────────────────────────────────────────────────────────────┘

⚠️ 不再新增 /mock-center 一级菜单。authMenuList.json 不动。
```

### 14.2 接口详情页 Mock Tab 详细设计

> 参考用户截图样式（"Mock 地址" → 改为"如何调用"指引区，去掉"本地"列）。

```
┌─────────────────────────────────────────────────────────────────────┐
│ Remove From Cart                              [Mock 开关 ●] [设置 ⚙]│  ← 右上角加 Mock 开关
├─────────────────────────────────────────────────────────────────────┤
│ 接口详情 │ 用例列表(29) │ 文档 │ 【Mock】                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│ ▼ 如何调用                                                          │
│   原始 URL：DELETE  https://your-api.com/cart/remove/{product_id}   │
│   必备 Header：                                                     │
│     X-Mock-Enabled: true                                            │
│     X-Space-Id:    {{currentSpaceId}}                               │
│     X-Env-Id:      {{currentEnvId}}                                 │
│   [复制 cURL] [复制 Postman Collection]                             │
│                                                                     │
│ ▼ Mock 期望                                              [+ 新建期望]│
│   ┌───────────────┬──────────────────┬──────────┬──────┬────────┐  │
│   │ 名称           │ 条件              │ 创建者   │ 启用 │ 操作    │  │
│   ├───────────────┼──────────────────┼──────────┼──────┼────────┤  │
│   │ 用户1登录      │ query.name == 1  │ 管理员    │  ●  │ 👁 🗑   │  │
│   │ 用户2登录      │ query.name == 2  │ 管理员    │  ●  │ 👁 🗑   │  │
│   │ 登录失败-密码错误│ body.pwd != ok  │ 管理员    │  ○  │ 👁 🗑   │  │
│   └───────────────┴──────────────────┴──────────┴──────┴────────┘  │
│                                                                     │
│ ▼ 调用日志（最近 50 条，更多看 space 设置 - Mock）        [刷新 ⟳] │
│   时间        命中           状态码   耗时     调用方 IP             │
│   13:42:01    expectation:1  200     12ms     192.168.1.5          │
│   13:41:30    passthrough    200     320ms    192.168.1.5          │
│   13:41:25    expectation:2  200     8ms      192.168.1.5          │
└─────────────────────────────────────────────────────────────────────┘
```

**右上角 Mock 开关行为**：
- 第一次开 → 调 `POST /mock-service/api/create-or-enable`（延迟创建 mock_api 主表）
- 后续开关 → 调 `POST /mock-service/api/toggle`
- 关闭后该接口期望编辑区**仍可见**但灰显，提示用户"开关已关，期望不生效（请求会穿透到真实接口）"

**新建/编辑期望抽屉**（点 `+ 新建期望` 或某行 `编辑`）：
- 名称、场景下拉（P0 默认场景）、优先级
- 匹配条件：表单（位置 + 字段 + 操作符 + 值，多行 AND）↔ CEL 切换
- 响应：类型 Tab（STATIC / TEMPLATE，P1 加 SCRIPT/FAKER/MULTI）+ Status / Headers / Body 编辑
- 状态机（P2）/ Chaos（P2）字段折叠
- [预览] 按钮（调 `expectation/preview-response`，不真正命中）

### 14.3 case 编辑页改动

case 编辑表单加一项（位置参考现有 case 字段布局）：

```vue
<el-form-item label="启用 Mock">
  <el-switch v-model="form.enableMock" />
  <el-text class="ml-2" type="info" size="small">
    开启后该 case 执行时给请求加 X-Mock-Enabled Header；接口需先在 Mock Tab 配置好期望。
  </el-text>
</el-form-item>
```

写入 `tb_api_case.enable_mock`；执行引擎读取后给 HTTP 请求构造器加 Header。

### 14.4 space 设置 - Mock 子页

> 既然没有 Mock 中心，跨接口的"应用级"功能放这里。

```
space 设置弹窗
├─ 基础信息
├─ 成员管理
├─ ...
└─ 【Mock】← 新增 Tab（v1.2）
    ├─ 总开关：[启用 Mock 能力 ●]（写 tb_space.enable_mock）
    │           关闭后整个 space 下所有 mock 不生效
    ├─ 统计卡片：已配 Mock 接口数 / 7 天命中数 / 7 天穿透数
    ├─ 全局调用日志：按时间倒序，可按接口/状态过滤
    ├─ 全局 Chaos 规则（P2）：列表 + CRUD
    └─ Header 协议帮助：X-Mock-* / X-Space-Id / X-Env-Id 一览
```

### 14.5 axios interceptor 改动（关键）

`src/api/index.ts`（或对应入口）的 request interceptor：

```typescript
import { useUserStore } from '@/stores/modules/user'
import { useEnvStore } from '@/stores/modules/env'  // 假设有
import { useApiMockStore } from '@/stores/modules/apiMock'  // 见下

instance.interceptors.request.use((config) => {
  const userStore = useUserStore()
  const envStore = useEnvStore()
  const apiMockStore = useApiMockStore()

  // v1.1 D4=A：每个请求带 X-Space-Id
  if (userStore.currentSpaceId) {
    config.headers['X-Space-Id'] = String(userStore.currentSpaceId)
  }

  // v1.2 D11：每个请求带 X-Env-Id（mock-service 穿透时用）
  if (envStore.currentEnvId) {
    config.headers['X-Env-Id'] = String(envStore.currentEnvId)
  }

  // v1.2 D7+D8：判断当前请求是否要触发 mock
  // - space 总开关 ON
  // - 该接口（按 method+path 匹配）的 mock 开关 ON
  // 二者满足才加 X-Mock-Enabled: true
  if (apiMockStore.shouldMock(config.method, config.url)) {
    config.headers['X-Mock-Enabled'] = 'true'
  }

  return config
})
```

**`apiMockStore`**（新增 Pinia store）：
- 启动时 / space 切换时调 `/mock-service/api/list-enabled-paths`，拉回该 space 下所有"开了 mock 开关"的 (method, path) 列表
- `shouldMock(method, url)`：在内存里按 PathPattern 匹配；O(N) 遍历可接受（接口数一般不大）
- space.enable_mock 关闭时整个 store 清空，shouldMock 永远返回 false

### 14.6 API 模块改造

`src/api/modules/api-mock.ts` → 拆分重命名为：

```
src/api/modules/mock/
├── api.ts            # MockApi 增删改 + 开关
├── expectation.ts    # 期望增删改 + 开关 + preview + validate-cel
├── scenario.ts       # 场景（P1）
├── log.ts            # 调用日志（接口维度 + space 维度）
├── chaos.ts          # Chaos（P2）
├── record.ts         # 录制（P2）
└── state.ts          # 状态机（P2）
```

类型定义：`src/api/interface/mock/*.ts`。

> 旧 `src/api/modules/api-mock.ts` 在 P0 末尾删除（D6 不兼容）。

### 14.7 关键 UI 决策

| 项 | 决策 |
|---|---|
| Mock Tab 嵌入位置 | 接口详情页（已有 Tab 结构，加一个 Mock Tab）+ case 编辑表单（一个开关字段）|
| CEL 编辑器 | Monaco + 自定义语法高亮 + 自动补全（接口字段元数据）|
| 表单 ↔ CEL 互转 | 双向：表单填好自动生成 CEL；CEL 简单形态可反推表单（边界见 §9.2）|
| 复制 Mock 调用 | 「复制 cURL」按钮，自动带 X-Mock-Enabled / X-Space-Id / X-Env-Id |
| 期望列表"启用"开关 | 单条期望粒度（截图右侧开关），写 `tb_mock_expectation.enabled` |
| 空 mock 提示 | 接口 Mock Tab 第一次打开时显示空状态 + 引导文案"开启 Mock 开关并新建第一条期望" |
| 调用日志详情 | 抽屉式：上半 Request、下半 Response、底部"命中详情"（CEL 求值树 / 穿透 URL / 穿透耗时）|
| 穿透日志 vs mock 命中日志 | 视觉上区分：mock 命中=绿色 expectation:N，穿透=橙色 passthrough，穿透失败=红色 passthrough_failed |

---

## 15. 实施计划（分阶段交付）

**P0 前置（编码前必须完成）**
- [x] ✅ §0 D1-D11 决策已全部确认
- [ ] **DDL dry-run**：在 dev MariaDB 13307 验证 `tb_mock_api` 的 `(space_id, method, path)` 唯一索引；现状路径都不长就走 `path VARCHAR(192)`，否则 `path_hash CHAR(32)`
- [ ] `tb_space.enable_mock` 字段添加（**system 模块** migration，见 §10.4.1）
- [ ] `tb_api_case.enable_mock` 字段添加（**api-test 模块** migration，见 §10.4.1）
- [ ] **api-test 模块** 暴露 `EnvironmentResolveService` + `ApiTestInnerClient`（resolve-base-url 接口，§13.4.1）—— 复用现有 case 执行引擎里"按环境解析 URL"的逻辑

**P0（MVP）** — 第一版可用
- [ ] 新建 `test-mng-mock` Maven 模块（库直接复用 `tp_interface`，无需申请新库；datasource / Redis 配置参考 §17.5 Nacos 配置清单）
- [ ] **6 张表全建**（即使 P0 只用 3 张），避免 P1/P2 反复迁移；P0 不开放的功能在管理 API 层屏蔽
- [ ] Entity + Mapper + 基础 CRUD（管理面），Controller 用 `JsonDataVO<T>` / `PageDataVO<T>`，业务异常抛 `BizException` + `BizCodeEnum`
- [ ] `MockRoutingFilter`（Header 触发；**含 `/mock-service/` 与 `/__mock/` 前缀守卫**，避免循环改写）
- [ ] **网关 Nacos 路由配置**：`gateway-service-{profile}.properties` 加两条路由（§17.5.2）
- [ ] **Knife4j 聚合配置**：把 mock-service 加入 doc.html 聚合
- [ ] 数据面 Controller + 路径索引（`PathPattern`）+ Caffeine 缓存
- [ ] CEL 表达式接入 + 表单 ↔ CEL 互转（含 §9.2 互转边界）
- [ ] STATIC + TEMPLATE（Pebble）两种响应类型
- [ ] **`MockProxyService` 穿透实现**（v1.2 D10 提前到 P0）：调 `ApiTestInnerClient.resolveBaseUrl` + WebClient 转发 + strip X-Mock-* Header
- [ ] **`SystemInnerClient.isSpaceMockEnabled`**（D8 第 1 层开关查询，含 Caffeine 缓存）
- [ ] 单一场景模式（每个 mock_api 一个 default 场景，前端不暴露场景切换）
- [ ] **前端**：接口详情页加 Mock Tab + 右上角 Mock 开关（v1.2 截图样式）
- [ ] **前端**：case 编辑页加 enable_mock 开关字段
- [ ] **前端**：space 设置页加 Mock 子 Tab（总开关）
- [ ] **前端 axios interceptor**：从 store 读 currentSpaceId / currentEnvId / shouldMock，注入 `X-Space-Id` / `X-Env-Id` / `X-Mock-Enabled`
- [ ] **api-test 执行引擎**：执行 case 前读 `case.enable_mock`，true 时给请求加 `X-Mock-Enabled` / `X-Space-Id` / `X-Env-Id` Header
- [ ] **调用日志 P0 落盘**（v1.2：穿透日志要看，从 P1 提前）：含 passthrough 字段、upstream_url 等
- [ ] Prometheus 基础指标（含 `mock_passthrough_total`、`mock_upstream_duration_seconds_bucket`）
- [ ] 旧版 Mock 代码下线：删除 `test-mng-api-test/.../controller/ApiMockController.java` 等旧文件 + 前端旧 `api-mock.ts`（D6 已确认不兼容）

**P1（第二阶段）** — 高级特性
- [ ] 场景管理（创建、切换、批量切场景）
- [ ] SCRIPT (GraalJS) + FAKER 响应类型
- [ ] 多响应（加权随机）
- [ ] Redis pub/sub 热更新
- [ ] 前端调用日志页面增强（接口维度详情抽屉 + space 维度全局视图 + CEL 求值树）

**P2（第三阶段）** — 增强能力
- [ ] 录制回放
- [ ] 状态机（Stateful Mock）
- [ ] Chaos 故障注入
- [ ] OpenAPI 一键导入
- [ ] gRPC（如有需求）

**P3（持续优化）**
- [ ] 版本管理 / Git 同步
- [ ] WebSocket / MQTT
- [ ] A/B 灰度 Mock
- [ ] AI 生成期望

---

## 16. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| **CEL 学习成本高** | 中 | 中 | 表单 ↔ CEL 互转 + 完善的语法帮助和示例 |
| **Pebble / GraalJS 沙箱被绕过** | 低 | 高 | 严格的 Polyglot 配置 + CPU/内存超时 + 黑名单 + 安全审计 |
| **mock-service 故障 → 业务 Mock 全黑** | 中 | 高 | gateway CircuitBreaker + Fallback 路由 + 多实例部署 |
| **调用日志 MySQL 单表膨胀** | 中 | 中 | 7 天 TTL + 队列批量写；接口抽象后量级到顶再切分表 / ClickHouse |
| **Header 协议侵入第三方接口** | 低 | 低 | 强调 Header 仅在测试环境使用；生产网关可配置过滤 |
| **多空间规则冲突 / 误命中** | 中 | 中 | 强制 `spaceId` 隔离 + UnitTest 覆盖跨空间场景 |
| **CEL/Pebble 性能不达预期** | 低 | 中 | 编译后缓存 AST；压测 P99 < 50ms 否则降级到代码分支 |
| **穿透时下游响应大 / 慢导致 mock-service 资源耗尽**（v1.2）| 中 | 高 | 严格按环境配置的 connect/response timeout；body 转发用流式（避免全量加载到内存）；mock-service 多实例 + 限流 |
| **穿透时 strip Header 漏一个导致死循环**（v1.2）| 中 | 高 | 单测必须覆盖 strip 逻辑；MockProxyService 改用 allowlist 模式（透传白名单 Header）+ blocklist 兜底 |
| **`X-Env-Id` 缺失导致用户体验差**（v1.2）| 中 | 中 | 前端 axios 全局兜底（缺 envId 报错并提示用户先选环境）；mock-service 返回 400 + 明确错误信息 |
| **api-test 的 `EnvironmentResolveService` 解析逻辑变化破坏穿透**（v1.2）| 中 | 高 | InnerClient 契约 + 集成测试覆盖 ≥ 5 种环境路由匹配场景；api-test 改这块时需通知 mock-service owner |

---

## 17. 附录

### 17.1 完整 Header 协议总览

| Header | 默认 | 取值 | 谁解析 | 备注 |
|---|---|---|---|---|
| `X-Mock-Enabled` | false | `true` / `false` | gateway | 总开关，触发路由改写 |
| `X-Space-Id` | — | spaceId 数值 | mock-service | **必需**（v1.1 D4=A），前端 axios 注入 |
| **`X-Env-Id`** | — | envId 数值 | mock-service | **必需**（v1.2 D11），mock-service 穿透时调 api-test InnerClient 解析真实 URL |
| `X-Mock-Scenario` | (default 场景) | scenario.code | mock-service | 不存在场景时 fallback 到 default |
| `X-Mock-Expectation` | — | expectation.id | mock-service | 强指定，调试用 |
| `X-Mock-Delay` | — | 毫秒数 | mock-service | 临时叠加延迟 |
| `X-Mock-Status` | — | HTTP 状态码 | mock-service | 强制状态码 |
| `X-Mock-Record` | false | `true` / `false` | mock-service | 录制模式（P2）|
| `X-Mock-Chaos` | — | 形如 `latency=500;error=0.1` | mock-service | 临时故障注入（P2）|
| `X-Mock-Trace` | false | `true` / `false` | mock-service | 响应头带命中详情 |
| `X-Mock-Source` | `client` | `client` / `case` / `ui-auto` / ... | mock-service | 调用来源标识，记调用日志用（可选）|

**响应 Header（始终返回，方便前端调试）**：

| 响应 Header | 说明 |
|---|---|
| `X-Mock-Hit` | `expectation:<id>` / `passthrough` / `passthrough_failed` / `passthrough_no_route` |
| `X-Mock-Passthrough-Reason` | 仅 `X-Mock-Hit` 含 `passthrough` 时返回：`space_disabled` / `api_not_found` / `api_disabled` / `no_match` / `all_expectations_disabled` / `env_resolve_error` / `upstream_error` |
| `X-Mock-Cost-Ms` | mock-service 内部处理耗时（不含穿透下游耗时）|
| `X-Mock-Upstream-Cost-Ms` | 仅穿透时返回：下游真实接口的耗时 |

**响应 Header（仅 `X-Mock-Trace: true` 时额外返回）**：

| 响应 Header | 说明 |
|---|---|
| `X-Mock-Hit-Rule` | 命中的 CEL 表达式 |
| `X-Mock-State-After` | 状态机执行后的 state |
| `X-Mock-Upstream-Url` | 穿透时的真实目标 URL（脱敏处理后）|

### 17.2 WireMock vs 自研对比

| 维度 | WireMock | 自研 |
|---|---|---|
| 开发成本 | 低（直接集成） | 高 |
| 控制粒度 | 受框架限制 | 完全自主 |
| DSL | Stub Mappings (JSON) | CEL（更通用） |
| 状态机 | ✅ Scenario + State | 需自研 |
| 录制 | ✅ Record Mode | 需自研 |
| 模板 | Handlebars | Pebble |
| 脚本响应 | Plugin 机制（Java/Groovy） | GraalJS（直接接） |
| 性能 | 已知问题：大量规则时差 | 可针对性优化 |
| 可观测 | 弱 | 强（统一调用日志，前端可直查） |
| 学习成本（用户） | 高（要懂 Stub DSL） | 中（CEL + 表单） |

**结论**：建议**P0 自研内核**（避免被 WireMock DSL 锁定），但**部分能力借鉴 WireMock 的设计**（如 Scenario 概念、State 状态机模型）。如团队人手紧，可考虑 P0 直接嵌 WireMock 作为"响应引擎"，外层壳和管理面自研。

### 17.3 核心代码骨架（供 P0 启动时参考）

> **注**：v1.1 D3=A 已确认走 servlet stack，下方 `Mono<MatchedExpectation>` / `ServerWebExchange` 落地时替换为同步 `MatchedExpectation` + `HttpServletRequest`；`Schedulers.boundedElastic()` 直接去掉，普通 `@Service` 方法即可。骨架仅作流程参考。

`MockMatchService.java` 主流程（**v1.2 加入三级开关检查 + 抛 PassthroughException 触发穿透**）：

```java
@Service
@RequiredArgsConstructor
public class MockMatchService {

    private final MockRuleCache cache;
    private final CelEvaluator cel;
    private final MockStateMachineService stateMachine;
    private final SystemInnerClient systemClient;  // v1.2: 查 space.enable_mock

    public MatchedExpectation match(HttpServletRequest request) {
        // ===== Header 解析（v1.2 D4 + D5 + D11）=====
        Long spaceId = parseLongHeader(request, "X-Space-Id");  // 缺失返回 400
        Long envId   = parseLongHeader(request, "X-Env-Id");    // 缺失返回 400
        String method = request.getMethod();
        String fullPath = request.getRequestURI();
        String path = fullPath.startsWith("/__mock") ? fullPath.substring("/__mock".length()) : fullPath;

        // ===== 三级开关检查（v1.2 D8）=====
        // 第 1 层：space 总开关
        if (!systemClient.isSpaceMockEnabled(spaceId)) {
            throw new PassthroughException(MissReason.SPACE_DISABLED, envId, spaceId);
        }
        // 第 2 层：接口级开关
        List<MockApi> apis = cache.lookup(spaceId, method, path);
        if (apis.isEmpty()) {
            throw new PassthroughException(MissReason.API_NOT_FOUND, envId, spaceId);
        }
        MockApi api = apis.get(0);
        if (!api.getEnabled()) {
            throw new PassthroughException(MissReason.API_DISABLED, envId, spaceId, api.getId());
        }

        // ===== 期望匹配 =====
        String scenarioCode = headerOr(request, "X-Mock-Scenario", "default");
        String forcedExpectation = request.getHeader("X-Mock-Expectation");

        List<MockExpectation> expectations = cache.expectationsOf(apis, scenarioCode);
        // 第 3 层：所有期望都禁用？
        if (expectations.stream().noneMatch(MockExpectation::getEnabled)) {
            throw new PassthroughException(MissReason.ALL_EXPECTATIONS_DISABLED, envId, spaceId, api.getId());
        }
        if (forcedExpectation != null) {
            return new MatchedExpectation(cache.expectationById(Long.parseLong(forcedExpectation)),
                    MockRequestContext.from(request, path, apis));
        }

        // CEL 求值
        MockRequestContext ctx = MockRequestContext.from(request, path, apis);
        for (MockExpectation exp : expectations) {
            if (!exp.getEnabled()) continue;
            if (!cel.evaluate(exp.getMatchExpression(), ctx)) continue;
            if (!stateMachine.checkAndTransfer(exp, ctx)) continue;
            return new MatchedExpectation(exp, ctx);
        }
        throw new PassthroughException(MissReason.NO_MATCH, envId, spaceId, api.getId());
    }
}
```

`MockProxyService.java` 穿透实现（v1.2 D10 P0）：

```java
@Service
@RequiredArgsConstructor
@Slf4j
public class MockProxyService {

    private final ApiTestInnerClient apiTestClient;
    private final WebClient webClient;  // 或 RestTemplate（servlet 下推荐 RestTemplate / OkHttp）

    /**
     * 处理穿透：解析环境 base_url → 转发请求 → 返回响应
     */
    public ResponseEntity<byte[]> passthrough(HttpServletRequest request, PassthroughException ex) {
        // 1. 调 api-test InnerClient 解析环境
        EnvBaseUrlResolveDTO dto = EnvBaseUrlResolveDTO.builder()
                .envId(ex.getEnvId())
                .spaceId(ex.getSpaceId())
                .path(ex.getPath())
                .method(request.getMethod())
                .apiInfoId(ex.getApiInfoId())
                .build();
        JsonDataVO<EnvBaseUrlResolveVO> resp = apiTestClient.resolveBaseUrl(dto);
        if (resp == null || !resp.isSuccess() || resp.getData() == null) {
            return errorResponse(502, "passthrough_failed", "env_resolve_error");
        }
        EnvBaseUrlResolveVO env = resp.getData();
        if (env.getBaseUrl() == null) {
            return errorResponse(404, "passthrough_no_route", "no_env_match");
        }

        // 2. 重组请求转发
        String targetUrl = env.getBaseUrl() + ex.getPath()
                + (request.getQueryString() != null ? "?" + request.getQueryString() : "");
        HttpHeaders headers = stripMockHeaders(request);  // strip X-Mock-* / X-Space-Id / X-Env-Id
        env.getDefaultHeaders().forEach(h -> headers.add(h.getName(), h.getValue()));

        try {
            // 3. WebClient 转发（按 env 超时配置）
            ResponseEntity<byte[]> upstream = webClient.method(HttpMethod.valueOf(request.getMethod()))
                    .uri(targetUrl)
                    .headers(h -> h.addAll(headers))
                    .body(BodyInserters.fromValue(request.getInputStream().readAllBytes()))
                    .retrieve()
                    .toEntity(byte[].class)
                    .timeout(Duration.ofMillis(env.getResponseTimeoutMs()))
                    .block();

            // 4. 加穿透标记 Header
            HttpHeaders respHeaders = new HttpHeaders();
            respHeaders.addAll(upstream.getHeaders());
            respHeaders.add("X-Mock-Hit", "passthrough");
            respHeaders.add("X-Mock-Passthrough-Reason", ex.getReason().name().toLowerCase());

            return new ResponseEntity<>(upstream.getBody(), respHeaders, upstream.getStatusCode());

        } catch (Exception e) {
            log.warn("Passthrough upstream failed: target={}, err={}", targetUrl, e.getMessage());
            return errorResponse(502, "passthrough_failed", "upstream_error");
        }
    }

    private HttpHeaders stripMockHeaders(HttpServletRequest request) {
        HttpHeaders out = new HttpHeaders();
        Collections.list(request.getHeaderNames()).forEach(name -> {
            String lower = name.toLowerCase();
            if (lower.startsWith("x-mock-") || lower.equals("x-space-id") || lower.equals("x-env-id")) {
                return;  // 不透传，防死循环
            }
            out.put(name, Collections.list(request.getHeaders(name)));
        });
        return out;
    }
}
```

⚠️ 上述 `WebClient` 写法是示意；servlet 链路下推荐 `RestTemplate` / `OkHttp` 同步调用（与 D3=A 一致），Reactive 写法仅在 spike WebFlux 时启用。

`MockRuntimeController.java` 异常处理（穿透与命中分流）：

```java
@RestController
@RequestMapping("/__mock")
@RequiredArgsConstructor
public class MockRuntimeController {
    private final MockMatchService matchService;
    private final MockResponseBuilder responseBuilder;
    private final MockProxyService proxyService;
    private final MockCallLogger callLogger;

    @RequestMapping("/**")
    public ResponseEntity<byte[]> handle(HttpServletRequest request) {
        long startTime = System.currentTimeMillis();
        try {
            MatchedExpectation matched = matchService.match(request);
            ResponseEntity<byte[]> resp = responseBuilder.build(matched, request);
            callLogger.logHit(request, matched, resp, startTime);
            return resp;
        } catch (PassthroughException ex) {
            ResponseEntity<byte[]> resp = proxyService.passthrough(request, ex);
            callLogger.logPassthrough(request, ex, resp, startTime);
            return resp;
        }
    }
}
```

### 17.4 联调与测试用例骨架

**P0 必备单测**：

- [ ] CEL 表达式各种写法（基础、嵌套、跨字段、函数调用）
- [ ] 路径索引（精确、{var} 通配、多 {var}、空格 / 编码）
- [ ] 多空间隔离（A 空间规则不能命中 B 空间请求）
- [ ] Pebble 模板渲染（变量、循环、错误兜底）
- [ ] 调用日志（队列批量落盘、关闭开关时全链路无写入、shutdown drain）
- [ ] mock-service 故障 → gateway fallback 行为
- [ ] **穿透单测（v1.2 D10）**：
  - [ ] space.enable_mock=0 → 直接穿透
  - [ ] api.enabled=0 → 直接穿透
  - [ ] 所有 expectation.enabled=0 → 直接穿透
  - [ ] CEL 全部不命中 → 穿透
  - [ ] 穿透时正确 strip X-Mock-* / X-Space-Id / X-Env-Id Headers（防死循环）
  - [ ] 穿透时正确透传 Authorization / Cookie / Body
  - [ ] api-test InnerClient 调用失败 → 502 + passthrough_failed
  - [ ] env_id 不存在 → 400
  - [ ] env_id 有效但 path 在该环境无 service config → 404 + passthrough_no_route
  - [ ] 真实下游 5xx / 超时 → 502 + upstream_error

**P1 / P2 阶段补充**：

- [ ] GraalJS 沙箱（超时、内存超限、try break out）—— P1
- [ ] Faker Schema 渲染 —— P1
- [ ] Redis pub/sub 缓存一致性（CRUD 后 ≤ 3s 全实例生效）—— P1
- [ ] 多场景切换 / 批量切场景 —— P1
- [ ] 状态机（state 流转、Redis 故障 fallback）—— P2
- [ ] Chaos（延迟、错误率、丢字段）—— P2
- [ ] 录制（录到、归纳条件、脱敏）—— P2

**集成测试**：
- [ ] 完整链路：客户端 → gateway → mock-service → 返回
- [ ] 回归：业务流量加 `X-Mock-Enabled: true` 时是否影响原链路
- [ ] 压测：单实例 1000 QPS（P0 验收线）；后续视量级再压 10K QPS

### 17.5 Nacos 配置清单（开工时直接贴）

> 全部配置都放在 dev Nacos：
> - 控制台：<http://dev-nacos.imchenr1024.com/nacos>（账号 `nacos` / `8f2598cdeedc4234b80c32424a7bd117`）
> - Namespace：`5143d5aa-cce6-43f7-bf9b-e422aaf7667d`
> - Group：`DEFAULT_GROUP`（与现有所有服务一致；个人 dev 集群用的 `QIANWENBO_LOCAL_GROUP` 是 discovery group，不是 config group）
>
> 本地工程只放最小 `application.properties`（仅 import Nacos），所有业务配置项写在 Nacos 的 properties 文件里。

#### 17.5.1 `mock-service-dev.properties`（**新建**，dev Nacos）

> 端口 **18011**（参考：`api-test-execution-service` 用 18006；如冲突自行调整）。
> datasource / Redis 直接复用 `tp_interface` 与现有 dev Redis；密码已是公开 dev 信息（参见项目根 CLAUDE.md）。
> 模板项以现有 `api-test-service-dev.properties` 为准（个别 key 可能有版本差异）；本清单覆盖 mock-service 必需的所有项。

```properties
# ===== 服务基础 =====
server.port=18011
spring.application.name=mock-service

# ===== 数据源（复用 tp_interface 库，与 api-test-service / api-test-execution-service 一致）=====
spring.datasource.driver-class-name=com.mysql.cj.jdbc.Driver
spring.datasource.url=jdbc:mysql://dev-mariadb.imchenr1024.com:13307/tp_interface?autoReconnect=false&useUnicode=true&characterEncoding=UTF-8&characterSetResults=UTF-8&zeroDateTimeBehavior=convertToNull&useSSL=false&allowPublicKeyRetrieval=true
spring.datasource.username=tp_interface
spring.datasource.password=arGtWAWcRsGJbZAb
spring.datasource.hikari.maximum-pool-size=20
spring.datasource.hikari.minimum-idle=5
spring.datasource.hikari.connection-timeout=30000

# ===== Redis（团队 dev Redis，复用同一实例）=====
spring.data.redis.host=dev-redis.imchenr1024.com
spring.data.redis.port=16379
spring.data.redis.password=redis_5285Aw
spring.data.redis.timeout=3000ms
spring.data.redis.lettuce.pool.max-active=16
spring.data.redis.lettuce.pool.max-idle=8

# ===== MyBatis Plus =====
mybatis-plus.mapper-locations=classpath*:mapper/xml/*.xml
mybatis-plus.global-config.db-config.id-type=AUTO
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

# ===== Knife4j（注意：mock-service 自身的 OpenAPI 配置；网关聚合见 17.5.2）=====
knife4j.enable=true
knife4j.openapi.title=Mock 服务 API
knife4j.openapi.description=test-mng-mock 配置面 + 数据面（X-Mock-* Header 协议见 §17.1）
knife4j.openapi.version=v1.0

# ===== Mock 自定义配置 =====
# Caffeine ↔ DB 对账周期（秒），见 §11.3
mock.cache.reconcile-interval-seconds=60
# Redis pub/sub 频道（CRUD 后发增量刷新通知）
mock.cache.invalidate-channel=mock:invalidate
# 期望本地缓存条数上限
mock.cache.expectation-max-size=20000
# CEL 表达式编译后缓存大小
mock.cel.cache-size=2000
# Pebble 模板缓存大小
mock.pebble.cache-size=2000

# 调用日志开关（紧急情况一键关）
mock.audit.enabled=true
# 调用日志保留天数（详见 §10.2 表 6 + §12.1）
mock.audit.retention-days=7
# 调用日志异步队列容量（有界 BlockingQueue）
mock.audit.queue-capacity=10000
# 调用日志 batch flush：每 N 条或每 M 毫秒，二者先到为准
mock.audit.batch-size=500
mock.audit.flush-interval-ms=1000
# 单条 request/response body 最大保留长度（超长截断打标）
mock.audit.body-max-bytes=1048576

# 默认状态机 TTL（秒；见 §8.2）
mock.state.default-ttl-seconds=86400

# ===== 穿透配置（v1.2 D10，§4.5）=====
# 穿透时调 api-test InnerClient 解析 base_url 的超时（毫秒）
mock.proxy.resolve-timeout-ms=2000
# 穿透下游真实接口的默认超时（毫秒）；环境配置里的 connect/response timeout 优先
mock.proxy.default-connect-timeout-ms=5000
mock.proxy.default-response-timeout-ms=30000
# 穿透时是否记录详细调用日志（含 upstream_url / upstream_cost_ms）
mock.proxy.log-detail=true
# space.enable_mock 本地缓存 TTL（秒）；查询频次极高，必须缓存
mock.proxy.space-enabled-cache-ttl-seconds=60

# ===== OpenFeign 超时（与现有 system-service 一致）=====
spring.cloud.openfeign.client.config.default.connect-timeout=5000
spring.cloud.openfeign.client.config.default.read-timeout=20000

# ===== 日志 =====
logging.level.cloud.aisky=info
logging.level.cloud.aisky.engine.matcher=debug
```

#### 17.5.2 `gateway-service-dev.properties`（**增量**，dev Nacos）

> 在现有 `gateway-service-dev.properties` 基础上**追加**以下条目。`<N>` / `<M>` 替换为现有 routes 列表的下一个递增 index（去 Nacos 控制台看已有的 `spring.cloud.gateway.routes[X].id` 最大值 + 1）。

```properties
# ===== 新增路由 1：Mock 数据面（透明改写流量入口，由 MockRoutingFilter 切换 URI）=====
spring.cloud.gateway.routes[<N>].id=mock-runtime
spring.cloud.gateway.routes[<N>].uri=lb://mock-service
spring.cloud.gateway.routes[<N>].predicates[0]=Path=/__mock/**

# ===== 新增路由 2：Mock 管理面（前端工作台调用 /mock-service/api/page 等）=====
spring.cloud.gateway.routes[<M>].id=mock-admin
spring.cloud.gateway.routes[<M>].uri=lb://mock-service
spring.cloud.gateway.routes[<M>].predicates[0]=Path=/mock-service/**
spring.cloud.gateway.routes[<M>].filters[0]=StripPrefix=1
# 注：StripPrefix=1 把 /mock-service/api/page 转发为 mock-service 收到的 /api/page

# ===== Knife4j 网关聚合：把 mock-service 的 OpenAPI 文档纳入 doc.html =====
knife4j.gateway.routes[<K>].name=Mock 服务
knife4j.gateway.routes[<K>].service-name=mock-service
knife4j.gateway.routes[<K>].url=/mock-service/v3/api-docs
knife4j.gateway.routes[<K>].order=<K>
```

> ⚠️ `knife4j.gateway.*` 的具体 schema 视 `knife4j-gateway-spring-boot-starter` 版本而定（项目用的是 4.x）；如启动后 doc.html 看不到 mock-service，回 Nacos 比对其它服务（system / api-test）现有 `knife4j.gateway.routes[*]` 的 key 写法。

#### 17.5.3 mock-service 本地 `application.properties`（工程内）

> 与现有所有微服务一致，本地只导入 Nacos：

```properties
spring.application.name=mock-service
spring.config.import[0]=nacos:${spring.application.name}-${spring.profiles.active}.properties?group=DEFAULT_GROUP

# OpenFeign：避免下游不可达时长时间阻塞（毫秒；可被 Nacos 配置覆盖）
spring.cloud.openfeign.client.config.default.connect-timeout=5000
spring.cloud.openfeign.client.config.default.read-timeout=20000
```

#### 17.5.4 `MockRoutingFilter` 在 gateway 工程内（非 Nacos，但顺手记录）

> 详见 §5.2 的完整代码骨架。新建文件路径：
> `test-mng-gateway/src/main/java/cloud/aisky/filter/MockRoutingFilter.java`
> 不需要新增 maven 依赖（Spring Cloud Gateway / Lombok 都已就位）。

#### 17.5.5 启动顺序与本地验证

```bash
# 1. dev Nacos 控制台：新建 mock-service-dev.properties + 改 gateway-service-dev.properties
# 2. parent pom 加 modules、加 cel-core / pebble / caffeine 依赖
# 3. 在 tp_interface 库执行 sql/mock/mysql/20260507_init.sql 建 6 张表（先 dry-run）
# 4. ./script/start_test_mng_backend.sh   ← 启动脚本会自动带上 mock-service
# 5. 验证：
curl -i http://localhost:<gateway-port>/mock-service/api/by-api-info \
  -H "Content-Type: application/json" \
  -H "X-Space-Id: 1" -d '{"apiInfoId":2031006}'         # 管理面

# 数据面：mock 命中 / 穿透
curl -i http://localhost:<gateway-port>/api/login \
  -H "X-Mock-Enabled: true" \
  -H "X-Space-Id: 1" \
  -H "X-Env-Id: 5"                                       # mock 命中或穿透到 env=5 解析的真实地址

# Knife4j 聚合页：http://localhost:<gateway-port>/doc.html
```

**穿透自测（v1.2 D10）**：
```bash
# 1. space 总开关 OFF → 直接穿透
curl -X POST .../system/space/toggle-mock -d '{"spaceId":1,"enableMock":false}'
curl -i .../api/login -H "X-Mock-Enabled: true" -H "X-Space-Id: 1" -H "X-Env-Id: 5"
# 期待响应头：X-Mock-Hit: passthrough  X-Mock-Passthrough-Reason: space_disabled

# 2. space ON 但 api 没配 → 穿透
curl -X POST .../system/space/toggle-mock -d '{"spaceId":1,"enableMock":true}'
curl -i .../api/some-not-mocked -H "X-Mock-Enabled: true" -H "X-Space-Id: 1" -H "X-Env-Id: 5"
# 期待响应头：X-Mock-Hit: passthrough  X-Mock-Passthrough-Reason: api_not_found

# 3. mock 命中
curl -i .../api/login -H "X-Mock-Enabled: true" -H "X-Space-Id: 1" -H "X-Env-Id: 5" \
  -d '{"username":"A","password":"any"}'
# 期待响应头：X-Mock-Hit: expectation:<id>

# 4. 缺 X-Env-Id → 400
curl -i .../api/login -H "X-Mock-Enabled: true" -H "X-Space-Id: 1"
# 期待 HTTP 400 + {"code":400,"msg":"X-Env-Id Header missing"}
```

---

**文档版本**：v1.2
**最后更新**：2026-05-07
**作者**：qianwenbo（牵头），团队待补
**状态**：✅ 决策已对齐（D1-D11 + 架构 15 项）。v1.2 关键变更：完全分散式（D7=B 删除 Mock 中心菜单）+ 三级开关（D8）+ case 引用接口期望（D9）+ 未命中自动穿透（D10）+ 新增 `X-Env-Id` Header（D11）+ `PROXY` 提前到 P0。
**P0 前置任务**：parent pom 加依赖 / DDL dry-run / 前端 axios 加 `X-Space-Id` 和 `X-Env-Id` / `tb_space.enable_mock` 与 `tb_api_case.enable_mock` 字段 / api-test 暴露 `EnvironmentResolveService` InnerClient / Nacos 配置见 §17.5

---

## 决策记录

> 阻塞级决策见 §0（D1-D6）。本节记录架构层面其它决策项的最终结论，全部于 v1.1 确认。

| # | 决策项 | 选项 | 决策 ✅ |
|---|---|---|---|
| 1 | 库归属 | A) 独立库 `tp_mock` / B) 复用 `tp_interface`（与 api-test-execution 模式一致，表前缀 `tb_mock_*` 命名隔离） | **B** ✅（v1.1 修订）|
| 2 | 表达式引擎 | A) CEL（`cel-core`）/ B) JsonLogic / C) 现有 13 个枚举操作符 | **A** |
| 3 | 模板引擎 | A) Pebble / B) Velocity / C) Mustache / D) Handlebars | **A** |
| 4 | 调用日志存储 | A) MySQL 单表 + 7 天 TTL（写入抽象 `MockCallLogRepository`，量级到顶再切）/ B) 直接上 ClickHouse / C) 直接上 Kafka | **A** |
| 5 | 调用日志异步方案 | A) 有界 `BlockingQueue` + 定时批量 flush + shutdown drain / B) `@Async` 一条一插 / C) Kafka topic 解耦 | **A** |
| 6 | 缓存对账周期 | A) 60s / B) 30s / C) 不对账只靠 pub/sub | **A** |
| 7 | `MockRoutingFilter` order | A) order=10（在 `GatewayGlobalFilter` 之后，复用其注入的 X-User-Id / X-Enterprise-Id；X-Space-Id 由前端 axios 注入透传过来）/ B) order=-10（之前） | **A** |
| 8 | fallback 兜底实现 | A) P0 直接 503 / B) P0 就实现网关本地转发到真实业务 | **A** |
| 9 | 是否复用 WireMock 内核 | A) 自研（CEL + Pebble + Caffeine）/ B) 嵌 WireMock 作为响应引擎 | **A** |
| 10 | 多协议支持时机 | A) HTTP 一期，gRPC/WebSocket/MQTT 二三期 / B) 一期就上多协议 | **A** |
| 11 | 调用日志保留期 | A) 7 天 / B) 14 天 / C) 30 天 | **A** |
| 12 | `tb_mock_api.path` 索引方案 | A) `path VARCHAR(192)`（utf8mb4 768 字节内）/ B) 加 `path_hash CHAR(32)` 唯一索引建在 hash 上 | **A**（dry-run 不通过则 fallback 到 B） |
| 13 | `script_type` 枚举范围 | A) `JS / GROOVY` / B) `JS / GROOVY / PYTHON / BEANSHELL`（与 api-test-execution 引擎对齐） | **B** |
| 14 | 接口创建是否预创建 mock_api | A) 延迟创建（用户开启 Mock 时才插）/ B) 接口创建时同步预创建 | **A** |
| 15 | P0 是否一次建全 6 张表 | A) 一次建全（P0 不开放的功能在管理 API 层屏蔽）/ B) P0 只建 3 张，P1/P2 alter | **A** |
