# Mock 模块重构设计文档

> 把现有散落在 `test-mng-api-test` 模块里的 Mock 能力，重构为一个**独立的微服务 + 网关层接入**的、覆盖全平台的通用 Mock 能力。
>
> 关键诉求：客户端 **URL 不变**、用 **Header 标记**触发 Mock；规则配置独立管理；性能、扩展性、可观测性全面升级。

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
| G2 | **独立微服务**：脱离 `test-mng-api-test` | 新增 `test-mng-mock` 模块、独立库、独立部署 |
| G3 | **网关层接入**：流量分流在网关完成 | `test-mng-gateway` 增加 Mock 路由 Filter，命中 Header 的请求自动改写 routing |
| G4 | **DSL 升级**：规则表达力全面增强 | 支持 `AND/OR/NOT`、跨字段条件、JsonPath、CEL 表达式 |
| G5 | **多种响应模式**：静态 + 模板 + 脚本 + Faker + OpenAPI 范例 | 一条期望可声明响应类型 |
| G6 | **状态机 / 场景** | 支持 stateful mock（次数、状态流转）；场景一键切换 |
| G7 | **流量录制回放** | 透传真实接口 → 自动落库为期望，3 步上手 |
| G8 | **故障注入（Chaos）** | 延迟、错误率、丢字段、限流可配 |
| G9 | **配置热更新** | 规则变更 ≤ 3s 全实例生效（无需重启） |
| G10 | **可观测** | 每次调用落 ClickHouse；前端可查命中详情、原始请求、渲染响应、耗时 |
| G11 | **多租户隔离** | 规则按 `spaceId` / `enterpriseId` 隔离 |
| G12 | **平滑迁移** | 旧三表数据无损迁移；旧 `/mock/{spaceId}/...` URL 兼容期 ≥ 3 个月 |

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
├── test-mng-api-test/                        # ⬅ Mock 完整长在这里
│   ├── controller/ApiMockController.java     # CRUD + 运行时入口（同一个 Controller）
│   ├── service/ApiMockService(.Impl).java    # 业务逻辑 ~570 行
│   ├── util/MockRequestMatcher.java          # 匹配引擎
│   ├── util/MockTemplateProcessor.java       # 模板引擎
│   ├── entity/{ApiMock, ApiMockExpectation, ApiMockCondition}.java
│   └── mapper/{...}.java
└── sql/api-test/mysql/20260404.sql           # 三表 DDL + 历史数据初始化
```

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

### 2.5 现有可保留的资产

不是全部推倒重做，下面这些可以保留或迁移：

- ✅ **三表的核心字段**：`expectation` 的 `name / enabled / response_body / status_code / delay_ms / content_type` 设计合理，可直接迁。
- ✅ **接口与 Mock 自动绑定**：`ApiInfoServiceImpl` 创建接口时自动 insert `tb_api_mock` 的逻辑可保留（变成"创建接口同时声明它在 Mock 服务里的契约"）。
- ✅ **前端 `ApiMock.vue` Tab**：作为接口详情页的一个"快速 Mock"入口可保留；但完整的 Mock 管理工作台需要新建独立菜单。
- ✅ **前端 API 文件 `src/api/modules/api-mock.ts`**：路径前缀替换为 `/mock-service/...` 即可继续用。

---

## 3. 重构目标与范围

### 3.1 用户视角的核心使用流程（重构后）

#### 流程 A：**最快上手（无感切换）**
```
1. 打开「Mock 管理」工作台 → 选中接口 → 一键"开启 Mock"
2. 编辑响应（默认从 OpenAPI / 历史调用样本反推一份）
3. 客户端在请求 Header 加上：X-Mock-Enabled: true
4. 同样的请求 URL → 自动返回 Mock 响应
```

#### 流程 B：**多场景切换**
```
1. 在工作台为接口创建多个"场景"：默认 / 登录失败 / 服务限流 / 数据为空
2. 客户端 Header：X-Mock-Scenario: scene_login_fail
3. 命中该场景下的期望，未命中走默认场景
```

#### 流程 C：**录制真实流量为 Mock**
```
1. 工作台开启某接口"录制模式" → 客户端 Header: X-Mock-Record: true
2. 流量经过 Mock 服务 → 透传到真实后端 → 抓响应自动落库为期望
3. 录制完成后关闭录制，切回 Mock 模式 → 期望自动应用
```

#### 流程 D：**故障注入测试**
```
1. 客户端 Header：X-Mock-Enabled: true; X-Mock-Chaos: latency=2000,error=0.1
2. Mock 服务在原响应基础上：注入 2s 延迟、10% 概率返回 500
3. 用于测试客户端的容错与重试逻辑
```

### 3.2 关键设计原则

1. **关注点分离**：`gateway` 只做路由分流，`mock-service` 只做匹配与响应生成，不混杂。
2. **配置面 vs 数据面**：CRUD 走管理 API（低 QPS、强一致）、运行时走数据面（高 QPS、最终一致）。
3. **失败兜底**：mock-service 故障或匹配未命中时，必须能 fallback 回真实业务路由，不能因为 Mock 故障导致带 Header 的流量全黑。
4. **租户隔离**：所有规则、调用日志、状态机数据都按 `spaceId` + `enterpriseId` 隔离。
5. **平滑迁移**：旧路径 `/mock/{spaceId}/...` 在过渡期内**继续可用**，给客户端足够的迁移窗口。

### 3.3 范围

**第一期（MVP，本文档主要描述）**：
- 网关 Filter + `test-mng-mock` 微服务
- HTTP / HTTPS 协议
- DSL 升级（CEL 表达式）
- 多响应类型（静态 / 模板 / 脚本 / Faker）
- 场景管理
- 调用日志（ClickHouse）
- 配置热更新（Redis pub/sub）
- 前端：独立 Mock 工作台菜单

**第二期**：
- 录制回放
- 状态机（Stateful Mock）
- Chaos 故障注入
- OpenAPI 一键导入

**第三期**：
- gRPC / WebSocket / MQTT
- 版本管理 / Git 同步
- A/B 灰度

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
              │ │  ⑧ 异步审计 → Kafka            │ │
              │ └────────────────────────────────┘ │
              │ ┌────────────────────────────────┐ │
              │ │ Admin（配置面）                │ │
              │ │  CRUD / Scenario / 录制管理     │ │
              │ └────────────────────────────────┘ │
              └─────┬────────────┬─────────────┬───┘
                    │            │             │
                    ▼            ▼             ▼
              ┌─────────┐   ┌─────────┐   ┌─────────────┐
              │ MySQL   │   │ Redis   │   │ Kafka /     │
              │ tp_mock │   │ 热缓存+  │   │ ClickHouse  │
              │ (规则源)│   │ 状态机+  │   │ (调用日志)  │
              │         │   │ pub/sub │   │             │
              └─────────┘   └─────────┘   └─────────────┘
```

### 4.2 模块划分

新增 Maven 模块 `test-mng-mock`，结构按现有规范（参考 `test-mng-api-test`）：

```
test-mng-mock/
├── pom.xml
└── src/main/java/cloud/aisky/mock/
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
    │   │   ├── MockMatchService.java                # 匹配
    │   │   ├── MockResponseBuilder.java             # 响应组合
    │   │   ├── MockStateMachineService.java         # 状态机
    │   │   ├── MockChaosService.java                # 故障注入
    │   │   └── MockProxyService.java                # 录制 / 透传
    │   └── admin/                                   # 配置面服务
    │       ├── MockApiService.java
    │       ├── MockExpectationService.java
    │       └── MockScenarioService.java
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
    │   ├── MockCallLogger.java                      # 异步落 Kafka
    │   └── MockCallLog.java                         # ClickHouse 实体
    ├── entity/                                       # 同 api-test 命名规范
    ├── dto/
    ├── vo/
    ├── enums/
    │   ├── MockResponseTypeEnum.java                # STATIC / TEMPLATE / SCRIPT / FAKER / PROXY
    │   ├── MockMatchModeEnum.java                   # SCENARIO / EXPECTATION / RANDOM / WEIGHTED
    │   └── MockChaosTypeEnum.java                   # LATENCY / ERROR_RATE / DROP_FIELD / RATE_LIMIT
    ├── config/                                       # Sa-Token / WebClient / Caffeine / Kafka
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

---

## 5. 网关接入设计（MockRoutingFilter）

### 5.1 Header 协议

| Header | 是否必需 | 说明 | 示例 |
|---|---|---|---|
| `X-Mock-Enabled` | ✅ 总开关 | `true` / `false` 大小写不敏感；缺省 = false（不走 Mock） | `true` |
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
        // 保留原始路径，给 mock-service 做匹配用
        exchange.getAttributes().put("original-path", originalUri.getRawPath());

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
| **Header 名字** | `Mock-Enabled` | `X-Mock-Enabled` | ✅ `X-` 前缀 —— 业界惯例（虽然 RFC 6648 已不推荐，但 K8s/AWS/Apifox 都还在用） |
| **失败兜底** | mock-service 返回特殊状态码 → 网关重试到业务 | mock-service 5xx → 网关 fallback | ✅ 使用 Spring Cloud Gateway 的 `Retry` + 自定义 `FallbackFilter`，确保 mock-service 故障不影响业务 |

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

> 实现 `MockFallbackController` 在网关本地，根据原路径和方法回查 Nacos 服务发现表，再次发起到真实业务的 lb 调用；或者更简单的做法 —— 直接返回 `503 Mock Service Unavailable`，由客户端去掉 Mock Header 重试。

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

> **Reactive 选型**：mock-service 走 Spring WebFlux，统一 `Mono<ResponseEntity>`。原因：
> - 大量请求并发场景下，WebFlux 的 EventLoop 模型省线程
> - Spring Cloud Gateway 本身就是 WebFlux，链路一致
> - 模板渲染 / 脚本执行可以走 `Schedulers.boundedElastic()` 异步隔离，不阻塞 EventLoop

### 6.2 完整匹配流程

```
请求进入 (/__mock/原路径 + Header X-Mock-* + Body)
    │
    ▼
[1] 解析路由元数据
    spaceId  = X-Space-Id（gateway 注入，复用）
    method   = HTTP method
    path     = original-path（gateway 在 attribute 里存的原始路径）
    │
    ▼
[2] Radix Tree 索引查找
    输入：(spaceId, method, path)
    输出：候选 MockApi（一对多，路径可能有 {{var}} 通配）
    │
    ▼
[3] 查 MockApi 的 Expectation 列表（已经按 priority desc 缓存）
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
    第一条 true 的命中
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
[10] 异步落日志 + 返回
```

---

## 7. 响应组合器

### 7.1 响应类型

| 类型 | 字段 | 描述 | 示例 |
|---|---|---|---|
| `STATIC` | `responseBody` | 直接返回 | `{"code":0}` |
| `TEMPLATE` | `responseBody` (Pebble 模板) | Pebble 渲染，能取请求字段、调用 Faker、做循环判断 | `{"id":{{request.body.id}},"now":"{{date('yyyy-MM-dd')}}"}` |
| `SCRIPT` | `scriptType`(JS/Groovy) + `scriptContent` | 沙箱执行，返回 JSON | `function(req){ return {id: req.body.id * 2}; }` |
| `FAKER` | `responseSchema` (JSON Schema) | 按 Schema 自动生成假数据 | `{"name":"@faker.name.fullName"}` |
| `PROXY` | `proxyUrl` | 透传到真实接口（录制模式核心） | `https://real-api.com/users` |
| `OPENAPI_EXAMPLE` | `apiInfoId` | 从该接口的 OpenAPI 定义里取 example | — |

`MockExpectation` 表新增字段 `response_type` 区分。

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

### 7.3 GraalJS 脚本示例

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

### 7.4 Faker Schema 示例

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

### 7.5 多响应（加权随机）

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

## 8. 高级特性

### 8.1 场景（Scenario）

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

### 8.2 状态机（Stateful Mock）

模拟"按调用次数返回不同响应"或"业务状态流转"：

```
expectation.statefulKey = "order_${request.body.orderId}"
expectation.fromState   = "PENDING"   // 必须当前状态为 PENDING 才能命中
expectation.toState     = "PAID"      // 命中后状态改为 PAID
expectation.responseBody = '{"status":"PAID"}'
```

**存储**：Redis Hash，key = `mock:state:{spaceId}:{statefulKey}`，TTL 24h（可配）。

**工作台支持**：列出当前所有 stateful key 的实时 state、支持手动重置。

### 8.3 录制回放（Record & Replay）

**录制**：
1. 工作台进入接口 → 点击「开启录制」→ 设置真实后端 URL（如 `https://staging.api.com`）
2. 客户端 Header 加 `X-Mock-Record: true`
3. mock-service 接到请求 → 透传到真实后端 → 拿到响应 → 异步写入 `tb_mock_expectation` 一条新期望
4. 工作台显示"录制到 N 条" → 用户审阅、修改、保留

**回放**：录制完成后，去掉 `X-Mock-Record`，使用普通 `X-Mock-Enabled: true` 即可命中刚才录制的期望。

**实现关键点**：
- 录制时**条件自动归纳**：若两个请求的 query 不同但 body 相同，归纳为"按 query 命中条件"；可配置归纳策略（精确 / 模糊）。
- 录制时**敏感字段脱敏**：自动替换 token / Authorization / 手机号 / 身份证为占位符。

### 8.4 Chaos 故障注入

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

兼容旧数据：`tb_api_mock_condition` 迁移时，把每行翻译为一段 CEL，多条 AND 拼接。

### 9.3 IP 条件（修复现有缺陷）

支持单 IP / CIDR / 黑白名单：

```cel
request.clientIp in cidrRange("10.0.0.0/24") || request.clientIp == "127.0.0.1"
```

`cidrRange` 作为自定义 CEL 函数注册。`request.clientIp` 由 mock-service 从 `X-Forwarded-For` / `X-Real-IP` 解析。

---

## 10. 数据模型

### 10.1 库与 schema

新建独立库 `tp_mock`，账号 `tp_mock`，与 `tp_interface` 物理分离。

> 决策依据：
> - Mock 是独立模块，独立扩缩、独立备份
> - 调用日志量大，与业务库混用会影响业务库性能
> - 与现有库一致的命名风格（`tp_*`）

### 10.2 表结构

#### 表 1：`tb_mock_api`（接口 → Mock 配置主表）

```sql
CREATE TABLE tb_mock_api (
    id BIGINT AUTO_INCREMENT PRIMARY KEY COMMENT '主键ID',
    space_id BIGINT NOT NULL COMMENT '空间ID',
    enterprise_id BIGINT NOT NULL COMMENT '企业ID',
    api_info_id BIGINT DEFAULT NULL COMMENT '关联 tp_interface.tb_api_info.id（可选）',
    method VARCHAR(10) NOT NULL COMMENT 'HTTP 方法',
    path VARCHAR(500) NOT NULL COMMENT '原始路径，支持 {var} 占位符',
    path_pattern VARCHAR(500) NOT NULL COMMENT '索引用的 Spring PathPattern 字符串',
    enabled TINYINT DEFAULT 1 COMMENT '是否启用',
    default_scenario_id BIGINT DEFAULT NULL COMMENT '默认场景ID',
    proxy_url VARCHAR(500) DEFAULT NULL COMMENT '透传/录制时的真实后端 URL',
    record_enabled TINYINT DEFAULT 0 COMMENT '是否录制中',
    create_user_id BIGINT,
    modify_user_id BIGINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted TINYINT DEFAULT 0,
    UNIQUE INDEX uk_space_method_path (space_id, method, path, deleted),
    INDEX idx_enterprise (enterprise_id, deleted),
    INDEX idx_api_info (api_info_id, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 接口配置表';
```

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
    api_id BIGINT NOT NULL COMMENT '关联 tb_mock_api.id',
    scenario_id BIGINT NOT NULL COMMENT '关联 tb_mock_scenario.id',
    name VARCHAR(100) NOT NULL,
    enabled TINYINT DEFAULT 1,
    priority INT DEFAULT 0 COMMENT '优先级，数值越大越优先',
    match_expression TEXT COMMENT 'CEL 匹配表达式',
    match_form_json JSON COMMENT '工作台表单形式（用于回显，可与 match_expression 互转）',

    -- Stateful
    stateful_key VARCHAR(200) DEFAULT NULL,
    from_state VARCHAR(50) DEFAULT NULL,
    to_state VARCHAR(50) DEFAULT NULL,

    -- 单响应（多响应见 tb_mock_response）
    response_type ENUM('STATIC','TEMPLATE','SCRIPT','FAKER','PROXY','OPENAPI_EXAMPLE','MULTI') DEFAULT 'STATIC',
    response_body MEDIUMTEXT,
    response_headers JSON,
    response_status_code INT DEFAULT 200,
    content_type VARCHAR(100) DEFAULT 'application/json',
    delay_ms INT DEFAULT 0,
    script_type ENUM('JS','GROOVY') DEFAULT NULL,

    -- 录制
    recorded_from VARCHAR(500) DEFAULT NULL COMMENT '录制来源 URL',
    recorded_at TIMESTAMP DEFAULT NULL,

    create_user_id BIGINT,
    modify_user_id BIGINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted TINYINT DEFAULT 0,
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
    response_type ENUM('STATIC','TEMPLATE','SCRIPT','FAKER') DEFAULT 'STATIC',
    response_body MEDIUMTEXT,
    response_headers JSON,
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

#### 表 6：`tb_mock_call_log_meta`（调用日志元数据，MySQL 仅存索引）

```sql
CREATE TABLE tb_mock_call_log_meta (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    trace_id CHAR(32) NOT NULL,
    space_id BIGINT NOT NULL,
    enterprise_id BIGINT NOT NULL,
    api_id BIGINT,
    expectation_id BIGINT,
    scenario_id BIGINT,
    method VARCHAR(10),
    path VARCHAR(500),
    status_code INT,
    cost_ms INT,
    matched TINYINT,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_trace (trace_id),
    INDEX idx_space_time (space_id, create_time DESC),
    INDEX idx_api_time (api_id, create_time DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Mock 调用日志（元数据）';
```

> **完整请求/响应体不存 MySQL，存 ClickHouse**（见 §11）。MySQL 这张表只作为前端列表查询的索引用。

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

tb_mock_call_log_meta  → 关联 api/expectation，但运行时不强约束
```

### 10.4 与现有 `tp_interface` 的关系

| 方向 | 关系 |
|---|---|
| `tb_mock_api.api_info_id` → `tp_interface.tb_api_info.id` | 软关联，便于"从接口详情跳到 Mock 配置" |
| 接口创建时同时插一行 `tb_mock_api` | 跨服务调用：`api-test` → `mock` 的内部 RPC |
| 接口删除时同时软删 `tb_mock_api` | 同上 |

**关键**：Mock 模块**不依赖** `tp_interface`，关联只是软的。即使没有 `api_info_id`，用户也能在 Mock 工作台直接创建接口。

---

## 11. 配置存储与热更新

### 11.1 三层缓存结构

```
[Mock 服务实例 N]                       [Redis]                   [MySQL]
┌──────────────────┐    miss          ┌──────────────────┐  miss  ┌──────────┐
│ 本地 Caffeine    │ ───────────────▶ │ Redis Hash       │ ─────▶ │ tp_mock  │
│ - 全量规则索引   │                  │ - 热点期望        │        │          │
│ - PathPattern 树 │                  │ - 状态机          │        │          │
│ - 期望详情(LRU)  │                  │ - Chaos 规则      │        │          │
└──────────────────┘                  └──────────────────┘        └──────────┘
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

数据量预估：
- 假设 1000 个空间、每个空间 100 个接口、每个接口 5 个期望 = 50 万 expectation
- 每个 expectation 内存 ~2KB → 约 1GB
- → JVM 堆 4-8GB 即可，水平扩展 3-5 个实例

### 11.3 热更新

**配置面 CRUD 完成后**：
1. 写 MySQL
2. 写 Redis（删 cache key）
3. 发 Redis pub/sub 消息：`PUBLISH mock:invalidate {"spaceId":42, "apiId":100, "type":"expectation_changed"}`
4. 所有 mock-service 实例订阅该 channel，收到后增量刷新本地 Caffeine

**最终一致性**：≤ 3 秒全实例生效。

**回滚**：删 Caffeine 即可，下次请求自动从 MySQL 重建。

---

## 12. 可观测性

### 12.1 调用日志架构

```
mock-service (异步发送)
    │
    ▼
Kafka topic: mock-call-log
    │
    ├──▶  ClickHouse  (mock_call_log)         — 全字段日志，前端查询用
    │
    └──▶  tb_mock_call_log_meta (MySQL)        — 元数据索引
```

### 12.2 ClickHouse 表

```sql
CREATE TABLE mock_call_log (
    trace_id String,
    space_id UInt64,
    enterprise_id UInt64,
    api_id UInt64,
    expectation_id UInt64,
    scenario_id UInt64,
    method LowCardinality(String),
    path String,
    request_headers String,                  -- JSON
    request_query String,                    -- JSON
    request_body String,
    matched UInt8,
    miss_reason LowCardinality(String),
    response_type LowCardinality(String),
    response_status UInt16,
    response_headers String,
    response_body String,
    cost_ms UInt32,
    chaos_applied String,
    create_time DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(create_time)
ORDER BY (space_id, create_time, api_id)
TTL create_time + INTERVAL 30 DAY;
```

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

| 类别 | 路径 | 方法 | 说明 |
|---|---|---|---|
| **MockApi** | `/mock-service/api/page` | POST | 分页查询 |
| | `/mock-service/api/create` | POST | 创建（关联或不关联接口） |
| | `/mock-service/api/update` | POST | 更新 |
| | `/mock-service/api/delete` | POST | 软删 |
| | `/mock-service/api/{id}` | GET | 详情 |
| | `/mock-service/api/toggle` | POST | 启用/禁用 |
| | `/mock-service/api/from-openapi` | POST | 从 OpenAPI 一键导入 |
| **Scenario** | `/mock-service/scenario/page` | POST | 场景列表 |
| | `/mock-service/scenario/create` | POST | 创建 |
| | `/mock-service/scenario/update` | POST | 更新 |
| | `/mock-service/scenario/set-default` | POST | 设为默认 |
| | `/mock-service/scenario/batch-switch` | POST | 全空间一键切场景 |
| **Expectation** | `/mock-service/expectation/page` | POST | 期望列表 |
| | `/mock-service/expectation/create` | POST | 新建 |
| | `/mock-service/expectation/update` | POST | 更新 |
| | `/mock-service/expectation/delete` | POST | 删除 |
| | `/mock-service/expectation/clone` | POST | 克隆到另一个场景 |
| | `/mock-service/expectation/preview-response` | POST | 预览响应（不真正命中，渲染一次给前端看） |
| | `/mock-service/expectation/validate-cel` | POST | 校验 CEL 表达式语法 |
| **Record** | `/mock-service/record/start` | POST | 开始录制 |
| | `/mock-service/record/stop` | POST | 停止录制 |
| | `/mock-service/record/recorded-list` | POST | 列出本次录制结果 |
| | `/mock-service/record/save-as-expectation` | POST | 把录制结果转为期望 |
| **Chaos** | `/mock-service/chaos/list` | POST | Chaos 规则列表 |
| | `/mock-service/chaos/create` | POST | 新增 |
| | `/mock-service/chaos/toggle` | POST | 启用/禁用 |
| **CallLog** | `/mock-service/call-log/page` | POST | 调用日志分页 |
| | `/mock-service/call-log/{traceId}` | GET | 详情 |
| **State** | `/mock-service/state/list` | POST | 当前状态机所有 key |
| | `/mock-service/state/reset` | POST | 重置某个 key 的 state |

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

    @Schema(description = "响应类型",
            allowableValues = {"STATIC","TEMPLATE","SCRIPT","FAKER","PROXY","OPENAPI_EXAMPLE","MULTI"},
            example = "STATIC")
    private String responseType;

    // ... 其余字段
}
```

---

## 14. 前端改造

### 14.1 路由 & 菜单

新增一级菜单「Mock 中心」，路由 `/mock-center`。

`src/assets/json/authMenuList.json` 增加一条：

```json
{
  "path": "/mock-center",
  "name": "MockCenter",
  "component": "/mock-center/index/index",
  "redirect": "/mock-center/index",
  "meta": {
    "icon": "Connection",
    "title": "Mock 中心",
    "isLink": "",
    "isHide": false,
    "isFull": false,
    "isAffix": false,
    "isKeepAlive": true
  },
  "children": [
    {
      "path": "/mock-center/index",
      "name": "MockCenterIndex",
      "component": "/mock-center/index/index",
      "meta": { "title": "接口管理", "isHide": false, "isKeepAlive": true }
    },
    {
      "path": "/mock-center/scenario",
      "name": "MockScenario",
      "component": "/mock-center/scenario/index",
      "meta": { "title": "场景管理", "isKeepAlive": true }
    },
    {
      "path": "/mock-center/record",
      "name": "MockRecord",
      "component": "/mock-center/record/index",
      "meta": { "title": "录制工作台", "isKeepAlive": true }
    },
    {
      "path": "/mock-center/chaos",
      "name": "MockChaos",
      "component": "/mock-center/chaos/index",
      "meta": { "title": "Chaos 规则", "isKeepAlive": true }
    },
    {
      "path": "/mock-center/log",
      "name": "MockLog",
      "component": "/mock-center/log/index",
      "meta": { "title": "调用日志", "isKeepAlive": true }
    }
  ]
}
```

### 14.2 文件结构

```
test-mng-web/src/views/mock-center/
├── index/
│   ├── index.vue                      # Mock 接口列表 + 详情双栏
│   └── components/
│       ├── ApiTreeOrTable.vue
│       ├── ApiCreateDialog.vue
│       ├── ScenarioSwitcher.vue       # 顶部场景切换
│       └── EnableSwitch.vue
├── expectation/
│   ├── ExpectationListPanel.vue       # 期望列表（详情右侧）
│   ├── ExpectationEditDrawer.vue      # 编辑抽屉
│   ├── MatchExpressionEditor.vue      # CEL 编辑器（Monaco + 表单切换）
│   ├── ResponseEditor.vue             # 响应编辑器（多类型 Tabs）
│   ├── PebbleHelp.vue                 # Pebble 语法帮助
│   ├── ScriptSandbox.vue              # 脚本编辑 + 运行测试
│   └── PreviewResponseDialog.vue      # 预览渲染结果
├── scenario/
│   ├── index.vue
│   ├── ScenarioListTable.vue
│   └── BatchSwitchDialog.vue
├── record/
│   ├── index.vue                      # 录制工作台
│   ├── RecordControlPanel.vue         # 开始/停止录制按钮 + 状态
│   └── RecordedTrafficTable.vue       # 已录制流量列表
├── chaos/
│   ├── index.vue
│   ├── ChaosCreateDialog.vue
│   └── ChaosTargetPicker.vue
├── log/
│   ├── index.vue
│   ├── CallLogTable.vue
│   ├── CallLogFilter.vue
│   └── CallLogDetailDrawer.vue        # 完整请求响应 + 命中详情
└── components/
    ├── MockUrlCopyButton.vue           # 复制带 Header 的 cURL
    └── HeaderProtocolHelp.vue          # X-Mock-* Header 协议帮助
```

### 14.3 接口详情页快速 Mock Tab（保留）

原 `src/views/api-module/components/ApiMock.vue` **保留并简化**，只暴露：
- 当前接口的"启用 Mock 总开关"
- 默认场景的期望列表（精简）
- 「在 Mock 中心打开」按钮 → 跳转到 `/mock-center?apiId=xxx`

完整管理操作引导用户进 Mock 中心。

### 14.4 API 模块改造

`src/api/modules/api-mock.ts` → 拆分重命名为：

```
src/api/modules/mock/
├── api.ts            # MockApi CRUD
├── scenario.ts       # 场景
├── expectation.ts    # 期望
├── record.ts         # 录制
├── chaos.ts          # Chaos
├── log.ts            # 调用日志
└── state.ts          # 状态机
```

类型定义：`src/api/interface/mock/*.ts`。

### 14.5 关键 UI 决策

| 项 | 决策 |
|---|---|
| 列表布局 | 左侧接口树（按目录）+ 右侧期望列表，类似当前 API 测试 |
| CEL 编辑器 | Monaco + 自定义语法高亮 + 自动补全（接口字段元数据） |
| 表单 ↔ CEL 互转 | 保留双向：表单填好自动生成 CEL，写 CEL 也能反推表单（无法解析时提示"高级模式仅 CEL 编辑"） |
| 复制 Mock URL | 提供「复制 cURL」按钮，自动带上所需 Header |
| 全空间场景切换 | 顶部下拉，切完后弹确认框列出影响的接口数 |
| 调用日志详情 | 抽屉式，左半 Request、右半 Response，下方"命中详情"区域显示 CEL 求值树 |

---

## 15. 数据迁移策略

### 15.1 迁移内容

旧 → 新对照：

| 旧表（`tp_interface`） | 新表（`tp_mock`） | 字段映射 |
|---|---|---|
| `tb_api_mock` | `tb_mock_api` | `api_info_id, space_id, method, mock_url(path)` |
| — | `tb_mock_scenario` | 自动为每个 mock_api 创建一个 `default` 场景 |
| `tb_api_mock_expectation` | `tb_mock_expectation` | 全字段 + `scenario_id = default 场景 id` + `response_type = STATIC` |
| `tb_api_mock_condition` | `tb_mock_expectation.match_expression` (CEL 串) | 多条 AND 拼为 CEL |

### 15.2 迁移 SQL 草案

```sql
-- 阶段 1：创建新库新表（执行 §10 的所有 DDL）
USE tp_mock;
-- ... 略

-- 阶段 2：迁移 tb_api_mock → tb_mock_api
INSERT INTO tp_mock.tb_mock_api
  (id, space_id, enterprise_id, api_info_id, method, path, path_pattern, enabled, ...)
SELECT
    m.id,
    m.space_id,
    /* enterpriseId: 从 tp_system.tb_space 反查 */
    (SELECT s.enterprise_id FROM tp_system.tb_space s WHERE s.id = m.space_id),
    m.api_info_id,
    m.method,
    /* path: 去掉 /mock/{spaceId}/ 前缀，去掉 ?apiId=xxx */
    SUBSTRING_INDEX(REPLACE(m.mock_url, CONCAT('/mock/', m.space_id), ''), '?', 1),
    /* path_pattern: 把 {{var}} 转 {var} */
    REPLACE(REPLACE(SUBSTRING_INDEX(REPLACE(m.mock_url, CONCAT('/mock/', m.space_id), ''), '?', 1), '{{', '{'), '}}', '}'),
    1, ...
FROM tp_interface.tb_api_mock m
WHERE m.deleted = 0;

-- 阶段 3：每个 mock_api 自动创建 default 场景
INSERT INTO tp_mock.tb_mock_scenario (space_id, enterprise_id, name, code, scope, api_id, is_default, ...)
SELECT space_id, enterprise_id, '默认', 'default', 'API', id, 1, ...
FROM tp_mock.tb_mock_api;

-- 阶段 4：迁移 expectation
INSERT INTO tp_mock.tb_mock_expectation
  (id, api_id, scenario_id, name, enabled, priority, match_expression, response_type, response_body, response_headers, response_status_code, content_type, delay_ms, ...)
SELECT
    e.id,
    e.mock_id, /* 旧 mock_id == 新 api_id */
    (SELECT s.id FROM tp_mock.tb_mock_scenario s WHERE s.api_id = e.mock_id AND s.code='default'),
    e.name,
    e.enabled,
    e.priority,
    /* match_expression: 从 condition 翻译 */
    cel_from_conditions(e.id),  /* 存储过程 */
    'STATIC',
    e.response_body, e.response_headers, e.status_code, e.content_type, e.delay_ms,
    ...
FROM tp_interface.tb_api_mock_expectation e
WHERE e.deleted = 0;

-- 阶段 5：旧表保留，加 deleted_by_migration 字段标记，3 个月后下线
ALTER TABLE tp_interface.tb_api_mock ADD COLUMN migrated_at TIMESTAMP DEFAULT NULL;
UPDATE tp_interface.tb_api_mock SET migrated_at = NOW();
```

`cel_from_conditions(expectation_id)` 是一段存储过程或 Java 工具类，输入旧条件列表，输出形如 `request.headers["X-User-Id"] == "1001" && request.body.amount > 100` 的 CEL 字符串。

### 15.3 兼容期 URL 双写

迁移完成后，仍要让旧 URL `/mock/{spaceId}/...` 工作 ≥ 3 个月：

```
方案 A: 在 test-mng-mock 里加一个特殊 Controller 映射 /mock/{spaceId}/**
        → 内部转发到 /__mock/* 路径

方案 B: 在 gateway 加一条 Route 把 /mock/* 转发到 mock-service，
        通过额外 Header 标记是兼容路径
```

✅ **选 B**，gateway 路由配置加一条：

```yaml
- id: legacy-mock-route
  uri: lb://test-mng-mock
  predicates:
    - Path=/mock/**
  filters:
    - AddRequestHeader=X-Mock-Legacy, true
    - RewritePath=/mock/(?<spaceId>\d+)/(?<rest>.*), /__mock/$\{rest}
    - AddRequestHeader=X-Space-Id, ${spaceId}    # 假如 gateway DSL 支持
```

mock-service 看到 `X-Mock-Legacy: true` 时，把 `X-Space-Id` 当成 `spaceId` 用（绕开正常的 token 解析路径）。

### 15.4 监控旧 URL 调用量

ClickHouse 加 `legacy_url` 字段，前端能看"还有多少客户端在用旧 URL"，作为下线决策依据。

---

## 16. 实施计划

### 16.1 分阶段交付

**P0（MVP，4 周）** — 上线即可替代当前 Mock 全部能力
- [ ] 新建 `test-mng-mock` Maven 模块、新库 `tp_mock`、Nacos 配置
- [ ] 6 张表 DDL + Entity + Mapper + 基础 CRUD（管理面）
- [ ] `MockRoutingFilter` + 兼容路径 legacy route
- [ ] 数据面 Controller + 路径索引（`PathPattern`）+ Caffeine 缓存
- [ ] CEL 表达式接入 + 表单 ↔ CEL 互转
- [ ] STATIC + TEMPLATE（Pebble）两种响应类型
- [ ] 单一场景模式（每个 mock_api 一个 default 场景，前端不暴露场景切换）
- [ ] 数据迁移脚本 + 旧 URL 兼容
- [ ] 前端独立菜单 + 期望编辑（无场景切换）
- [ ] 接口详情页保留简化版 Mock Tab
- [ ] Prometheus 基础指标

**P1（第二阶段，3 周）** — 高级特性
- [ ] 场景管理（创建、切换、批量切场景）
- [ ] SCRIPT (GraalJS) + FAKER 响应类型
- [ ] 多响应（加权随机）
- [ ] Redis pub/sub 热更新
- [ ] 调用日志（Kafka + ClickHouse）
- [ ] 前端调用日志页面

**P2（第三阶段，3 周）** — 增强能力
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

### 16.2 工作量估算

| 阶段 | 后端 (人日) | 前端 (人日) | 测试 (人日) | 合计 |
|---|---|---|---|---|
| P0 | 25 | 15 | 8 | **48** |
| P1 | 18 | 10 | 6 | **34** |
| P2 | 22 | 12 | 8 | **42** |
| **合计** | **65** | **37** | **22** | **124 人日** |

按 2 后端 + 1 前端 + 0.5 测试，**P0 = 4 周；P1 + P2 = 6 周**。

### 16.3 关键里程碑

| 里程碑 | 时间 | 检验标准 |
|---|---|---|
| M1 - 数据面跑通 | 第 2 周末 | curl 带 Header 能命中静态 Mock |
| M2 - P0 上线 | 第 4 周末 | 旧 Mock 流量 100% 兼容；新 Header 协议可用 |
| M3 - 场景 + 日志 | 第 7 周末 | 多场景切换 OK；调用日志可查 |
| M4 - 录制 + Chaos | 第 10 周末 | 录制 → 回放完整链路可用 |
| M5 - 旧表下线 | M2 + 3 个月 | 旧 URL 调用量 < 1%，下线 `tb_api_mock*` |

---

## 17. 风险与对策

| 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|
| **CEL 学习成本高** | 中 | 中 | 表单 ↔ CEL 互转 + 完善的语法帮助和示例 |
| **Pebble / GraalJS 沙箱被绕过** | 低 | 高 | 严格的 Polyglot 配置 + CPU/内存超时 + 黑名单 + 安全审计 |
| **mock-service 故障 → 业务 Mock 全黑** | 中 | 高 | gateway CircuitBreaker + Fallback 路由 + 多实例部署 |
| **旧 URL 客户端拒绝迁移** | 高 | 中 | 旧 URL 兼容期 ≥ 3 个月 + 调用日志可视化推动迁移 |
| **数据迁移 CEL 翻译不正确** | 中 | 中 | 迁移前后做"行为对比"自动化测试：相同请求两边比响应 |
| **ClickHouse 运维负担** | 中 | 中 | 第一期可降级用 MySQL（按月分表）；后续视量级再上 CK |
| **Header 协议侵入第三方接口** | 低 | 低 | 强调 Header 仅在测试环境使用；生产网关可配置过滤 |
| **多空间规则冲突 / 误命中** | 中 | 中 | 强制 `spaceId` 隔离 + UnitTest 覆盖跨空间场景 |
| **CEL/Pebble 性能不达预期** | 低 | 中 | 编译后缓存 AST；压测 P99 < 50ms 否则降级到代码分支 |

---

## 18. 附录

### 18.1 完整 Header 协议总览

| Header | 默认 | 取值 | 谁解析 | 备注 |
|---|---|---|---|---|
| `X-Mock-Enabled` | false | `true` / `false` | gateway | 总开关 |
| `X-Mock-Scenario` | (default 场景) | scenario.code | mock-service | 不存在场景时 fallback 到 default |
| `X-Mock-Expectation` | — | expectation.id | mock-service | 强指定，调试用 |
| `X-Mock-Delay` | — | 毫秒数 | mock-service | 临时叠加延迟 |
| `X-Mock-Status` | — | HTTP 状态码 | mock-service | 强制状态码 |
| `X-Mock-Record` | false | `true` / `false` | mock-service | 录制模式 |
| `X-Mock-Chaos` | — | 形如 `latency=500;error=0.1` | mock-service | 临时故障注入 |
| `X-Mock-Trace` | false | `true` / `false` | mock-service | 响应头带命中详情 |
| `X-Mock-Tenant` | (token 注入) | spaceId | mock-service | 极少数情况手动覆盖 |

响应 Header（仅 `X-Mock-Trace: true` 时）：

| 响应 Header | 说明 |
|---|---|
| `X-Mock-Hit` | `expectation:123` / `none` |
| `X-Mock-Hit-Rule` | 命中的 CEL 表达式 |
| `X-Mock-Cost-Ms` | 处理耗时 |
| `X-Mock-State-After` | 状态机执行后的 state |

### 18.2 WireMock vs 自研对比

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
| 可观测 | 弱 | 强（直接对接 ClickHouse） |
| 学习成本（用户） | 高（要懂 Stub DSL） | 中（CEL + 表单） |

**结论**：建议**P0 自研内核**（避免被 WireMock DSL 锁定），但**部分能力借鉴 WireMock 的设计**（如 Scenario 概念、State 状态机模型）。如团队人手紧，可考虑 P0 直接嵌 WireMock 作为"响应引擎"，外层壳和管理面自研。

### 18.3 与其他业界产品的差异

| 产品 | 集成方式 | 特点 | 我们的相似度 |
|---|---|---|---|
| **Apifox 云 Mock** | Header 切换 | 商用、与接口管理一体 | 高（核心思路一致） |
| **Postman Mock Server** | 独立 Mock URL | SaaS 化、订阅制 | 中（我们 URL 透明优于他们） |
| **MockServer (jamesdbloom)** | 独立部署 | Java SDK 强、规则灵活 | 中 |
| **WireMock** | 库 / 独立部署 | 状态机 / 录制成熟 | 高（功能侧借鉴） |
| **Apifox / Yapi 私有部署** | 同 Apifox 云 | 国内主流 | 高 |
| **Higress mock 插件** | Envoy WASM | 网关原生、性能极致 | 低（我们 Spring Cloud Gateway） |

### 18.4 核心代码骨架（供 P0 启动时参考）

`MockMatchService.java` 主流程：

```java
@Service
@RequiredArgsConstructor
public class MockMatchService {

    private final MockRuleCache cache;
    private final CelEvaluator cel;
    private final MockStateMachineService stateMachine;

    public Mono<MatchedExpectation> match(ServerWebExchange exchange) {
        Long spaceId = parseSpaceId(exchange);
        String method = exchange.getRequest().getMethodValue();
        String path = (String) exchange.getAttributes().get("original-path");

        return Mono.fromCallable(() -> {
                // 1. 路径索引查找
                List<MockApi> apis = cache.lookup(spaceId, method, path);
                if (apis.isEmpty()) throw new NoMatchException("no api");

                // 2. 取期望（已按 priority 排序，且按 scenario 过滤）
                String scenarioCode = headerOr(exchange, "X-Mock-Scenario", "default");
                String forcedExpectation = exchange.getRequest().getHeaders().getFirst("X-Mock-Expectation");

                List<MockExpectation> expectations = cache.expectationsOf(apis, scenarioCode);

                if (forcedExpectation != null) {
                    return cache.expectationById(Long.parseLong(forcedExpectation));
                }

                // 3. CEL 表达式过滤
                MockRequestContext ctx = MockRequestContext.from(exchange, path, apis);
                for (MockExpectation exp : expectations) {
                    if (!cel.evaluate(exp.getMatchExpression(), ctx)) continue;
                    if (!stateMachine.checkAndTransfer(exp, ctx)) continue;
                    return new MatchedExpectation(exp, ctx);
                }
                throw new NoMatchException("no expectation matched");
            })
            .subscribeOn(Schedulers.boundedElastic());
    }
}
```

### 18.5 联调与测试用例骨架

后端单元测试需要覆盖的关键场景：

- [ ] CEL 表达式各种写法（基础、嵌套、跨字段、函数调用）
- [ ] 路径索引（精确、{var} 通配、多 {var}、空格 / 编码）
- [ ] 多空间隔离（A 空间规则不能命中 B 空间请求）
- [ ] 旧路径兼容（`/mock/{spaceId}/...` 走兼容路径仍命中）
- [ ] Pebble 模板渲染（变量、循环、faker、错误兜底）
- [ ] GraalJS 沙箱（超时、内存超限、try break out）
- [ ] 状态机（state 流转、Redis 故障 fallback）
- [ ] Chaos（延迟、错误率、丢字段）
- [ ] 录制（录到、归纳条件、脱敏）
- [ ] 调用日志（异步落盘不丢、ClickHouse 写入）
- [ ] 缓存一致性（CRUD 后 ≤ 3s 全实例生效）
- [ ] mock-service 故障 → gateway fallback 行为

集成测试场景：
- [ ] 完整链路：客户端 → gateway → mock-service → 返回
- [ ] 回归：所有当前业务流量加 `X-Mock-Enabled: true` 后，匹配率 / 响应时间 / 一致性
- [ ] 压测：单实例 1000 QPS、10K QPS（看水平扩展）

---

**文档版本**：v1.0
**最后更新**：2026-05-06
**作者**：qianwenbo（牵头），团队待补
**状态**：📝 设计稿，待评审

---

## 待评审的关键决策

> 实施前需要团队对齐的决策项，按优先级排序：

1. **是否拆独立库 `tp_mock`** vs 复用 `tp_interface`：本文倾向独立库
2. **CEL vs JsonLogic vs 现有枚举操作符**：本文选 CEL
3. **Pebble vs Velocity vs Mustache** 模板引擎：本文选 Pebble
4. **是否引入 ClickHouse**：本文倾向引入；MVP 期可先 MySQL 分表
5. **是否引入 Kafka**：调用日志异步用，第一期可先用 Spring 的 `@Async` + 直写 MySQL
6. **`MockRoutingFilter` 顺序**：order=10（在 `GatewayGlobalFilter` 之后），需团队确认
7. **是否复用 WireMock 内核**：本文 P0 倾向自研，可讨论
8. **多协议支持时机**：HTTP 一期、其它协议二期/三期，可讨论
