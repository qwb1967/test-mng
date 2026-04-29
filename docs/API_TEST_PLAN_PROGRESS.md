# 接口测试计划 — 实施进度

> 设计文档：[API_TEST_PLAN_DESIGN.md](./API_TEST_PLAN_DESIGN.md)
> 分支：`feature/api-test-plan`（前端、后端各一）
> 起始：2026-04-25

---

## 准备阶段

- [x] 后端仓库拉取最新 develop（已最新）
- [x] 前端仓库重置本地 develop 到 origin/develop
- [x] 在前端仓库创建分支 `feature/api-test-plan`
- [x] 在后端仓库创建分支 `feature/api-test-plan`
- [x] 设计文档同步用户已确认的产品决策（§1.4）+ 修正实际代码风格约定（§4.1.1）
- [x] 调研 `test-mng-api-test` / `test-mng-api-test-execution` 包结构、Flyway 版本号、`JsonDataVO`/`PageDataVO`/`BizException`/`PageBaseDTO` 共用类

---

## PR-1：后端骨架（DDL + Entity/Mapper/DTO/VO/Service/Controller 占位） ✅

### 数据库迁移
- [x] `test-mng-api-test/db/migration/V20260425__api_test_plan.sql`：`tb_api_test_plan` + `tb_api_test_plan_item`
- [x] `test-mng-api-test-execution/db/migration/V20260425__api_test_plan_execution.sql`：`tb_api_test_plan_execution` + `tb_api_test_plan_execution_item` + `tb_test_report` 加 4 列 + `tb_api_test_plan_execution.test_report_id` 内置

### Entity
- [x] `ApiTestPlan` (api-test)
- [x] `ApiTestPlanItem` (api-test)
- [x] `ApiTestPlanExecution` (api-test-execution)
- [x] `ApiTestPlanExecutionItem` (api-test-execution)

### Mapper
- [x] `ApiTestPlanMapper`
- [x] `ApiTestPlanItemMapper`
- [x] `ApiTestPlanExecutionMapper`
- [x] `ApiTestPlanExecutionItemMapper`

### DTO（按现有代码风格 `XxxRequestDTO/PageDTO/IdDTO`，非 CLAUDE.md 描述的 `CreateDTO`）
- [x] `ApiTestPlanCreateRequestDTO`
- [x] `ApiTestPlanUpdateRequestDTO`
- [x] `ApiTestPlanIdDTO`（详情/复制/删除复用）
- [x] `ApiTestPlanPageDTO`（继承 `PageBaseDTO`）
- [x] `ApiTestPlanItemImportDTO`（嵌套 `ItemRef`）
- [x] `ApiTestPlanItemReorderDTO`
- [x] `ApiTestPlanItemBatchEnvDTO`
- [x] `ApiTestPlanItemBatchRemoveDTO`
- [x] `ApiTestPlanItemIdDTO`
- [x] `ApiTestPlanItemEnvDTO`
- [x] `ApiTestPlanRunDTO`（执行侧）
- [x] `ApiTestPlanExecutionIdDTO`（执行侧）
- [x] `ApiTestPlanExecutionPageDTO`（执行侧）
- [x] `ApiTestPlanRunningByPlanDTO`（执行侧）
- ⏸ `GenerateCronDTO` → 移到 PR-2，与 AI Cron 公共模块一起做

### VO
- [x] `ApiTestPlanVO` / `ApiTestPlanDetailVO` / `ApiTestPlanItemVO` (api-test)
- [x] `ApiTestPlanExecutionVO` / `ApiTestPlanExecutionDetailVO` / `ApiTestPlanExecutionItemVO` (api-test-execution)

### Converter
- [x] **决策变更**：现有代码不引入独立 Converter 类，PR-2 在 ServiceImpl 中用 `BeanUtil.copyProperties` 或手写映射。本项标记为「方案确认完成」

### Service / ServiceImpl 占位
- [x] `ApiTestPlanService` 接口（13 个方法）
- [x] `ApiTestPlanServiceImpl` 占位（全部抛 `UnsupportedOperationException`，待 PR-2 实现）
- [x] `ApiTestPlanExecutionService` 接口（5 个方法）
- [x] `ApiTestPlanExecutionServiceImpl` 占位（全部抛 `UnsupportedOperationException`，待 PR-3 实现）

### Controller 骨架
- [x] `ApiTestPlanController`（`/api-test-plan/**`，13 个端点）
- [x] `ApiTestPlanExecutionController`（`/api-test-plan-execution/**`，5 个端点）

### 编译验证
- [x] `mvn -pl test-mng-api-test -am compile` 通过
- [x] `mvn -pl test-mng-api-test-execution -am compile` 通过

---

## PR-2：CRUD + 条目管理 + 批量环境（依赖 PR-1） ✅
- [x] 计划 CRUD：`create / update / delete / copy / detail / page`
- [x] 关键字搜索 + 分页（按 `update_time desc` 排序，`itemCount` 批量回填避免 N+1）
- [x] 条目导入（API_CASE / SCENARIO 混合）：导入时校验源对象存在 + 名称快照 + 场景 stepCount 快照
- [x] 条目排序（`reorderItems` 按列表索引落库 sort_order）
- [x] 条目移除 / 批量移除（逻辑删除）
- [x] 单条 / 批量设置环境（用 `LambdaUpdateWrapper.set(...)` 显式支持 `null` 表示恢复源默认）
- [x] 在 `BizCodeEnum` 增加 6 个 924xxx 错误码（`APITEST_PLAN_NOT_EXIST` 等）
- ⏭ Feign 接入 → **决策变更**：`api-test-execution` 自带 ApiCase/TestScenario/Environment 的 Mapper（共享 MySQL），不需要 Feign，从清单移除
- ⏭ AI Cron 公共模块 → **决策变更**：后端实际未实现 Spring AI 集成（前端 `generateCronByAiApi` 调的接口当前是 404），作为**独立任务**后续单独排期，本轮不做

### 编译验证
- [x] `mvn -pl test-mng-api-test -am compile` 通过

---

## PR-3：执行引擎 + WebSocket（依赖 PR-2） ✅

### Stage 3.1：核心调度 ✅
- [x] `PlanRunner` 串行实现（失败继续，按 sort_order 顺序执行）
- [x] `PlanRunner` 并行实现 + 全局 Semaphore（可配 `api-test-plan.parallel-concurrency`，默认 5）
- [x] 取消机制：`PlanCancellationManager`（进程内 ConcurrentHashMap，单实例方案；多实例可换 Redis）
- [x] 单 item 超时：接口 90s、场景 = `stepCount × 90s` 动态计算
- [x] 整体超时：可配 `api-test-plan.overall-timeout-ms`，默认 2 小时
- [x] 同一计划允许多实例并发（不加锁，多个 execution 共存）
- [x] `ApiTestPlanExecutionServiceImpl` 完整实现 `run/stop/page/detail/getRunningByPlanId`

### Stage 3.2：WebSocket ✅
- [x] 添加 `spring-boot-starter-websocket` 依赖
- [x] `WebSocketConfig` 注册 `/api-test-plan-execution/ws/logs/**`
- [x] `PlanWebSocketHandler` 管理 session map，按 executionId 分组广播
- [x] `WebSocketPlanLogBroadcaster` (@Primary) 替换 Stub，将 PlanRunner 事件实时推送
- [x] 服务端定时心跳（25 秒）防代理超时断连；客户端 heartbeat 消息回响应
- [x] `@EnableScheduling` 加到 `ApiTestExecutionApplication`

### Stage 3.3：定时调度 ✅
- [x] `ApiTestPlanCronScheduler`：启动扫表注册 + 每 60s reconcile 处理配置变更
- [x] 触发时调用 `executionService.run(planId, null, "系统", "SCHEDULED")` 走和手动相同的路径
- [x] 跨模块通知（plan CRUD 在 api-test，调度在 api-test-execution）通过 60s 数据库轮询，可接受 60s 延迟

### Stage 3.4：启动恢复 ✅
- [x] `PlanExecutionStartupRecovery` 实现 `ApplicationRunner`，启动时扫 `status IN (running, pending)` → 置 `cancelled` 并写明「服务重启时检测到僵尸执行」

### 待联调 / 部署确认
- ⚠️ **Gateway WebSocket 升级**：网关配置在 Nacos 中（`gateway-service-${profile}.properties`），非本仓库代码。Spring Cloud Gateway 用 `lb://` URI 时通常自动支持 WebSocket，但**部署时需验证** `/api-test-execution/api-test-plan-execution/ws/logs/{id}` 能否升级到 WS

### 编译验证
- [x] `mvn -pl test-mng-api-test-execution -am compile` 通过

---

## PR-4：前端（依赖 PR-2/3 接口稳定） ✅
- [x] `src/api/interface/apiTestPlan.ts`（namespace ApiTestPlan：PlanItem/PlanDetail/PlanItemRow/CreateBody/UpdateBody/ItemImportBody/ItemReorderBody/ItemBatchEnvBody/ExecutionRecord/ExecutionDetail 等）
- [x] `src/api/modules/apiTestPlan.ts`（19 个 API：CRUD/条目管理/批量环境/执行/状态查询）
- [x] `src/stores/modules/apiTestPlanExecution.ts`（与 UI 测试计划同结构，独立 key 空间）
- [x] `src/views/case/detail/components/scene/ApiTestPlan.vue`（参考 UiTestPlan 改造；复用 CommonPlanList / CommonDialog / MessageBox / getEnvironmentListApi / getApiCaseListByServiceIdApi / getSceneListPageApi / getEnterpriseMembersApi）
- [x] `SceneIndex.vue` 新增 `api-test-plan` tab，并将「新建计划」按钮放在头部 `top-toolbar-actions`（条件渲染）
- ⏭ `case/detail/index.vue` 顶部按钮 → **决策变更**：按钮放在 `SceneIndex.vue` 头部更合理（视觉上与二级 tab 一行，无需跨组件协调），不再需要修改 `index.vue`
- [x] 拖拽排序：`sortablejs` 直接挂在 `<el-table>` 的 tbody，并行模式下禁用
- [x] 批量设置环境：与单条复用同一个弹窗（`envDialogMode: single | batch`），支持清空选择恢复源默认
- [x] 执行模式 radio（SERIAL / PARALLEL），切换即落库；并行模式下提示「顺序无意义」
- [x] 导入弹窗：`<el-radio-group>` 切换单接口 / 场景，分别调 `getApiCaseListByServiceIdApi` / `getSceneListPageApi`，已加入条目自动过滤
- [x] WebSocket：`/api-test-execution/api-test-plan-execution/ws/logs/{id}`，处理 test_begin/item_begin/item_end/log/progress/heartbeat/complete/cancelled/error 共 9 种消息，含断线重连（最多 6 次）

### 类型校验
- [x] `pnpm type:check`（vue-tsc --noEmit）0 错误

---

## PR-5：测试报告集成（依赖 PR-3 完成） ✅

### 后端
- [x] `TestReport` 实体 + `TestReportListVO` + `TestReportDetailVO` + `TestReportListDTO` 增加 `triggerType` / `testPlanId` / `testPlanName` / `testPlanExecutionId` 4 个字段
- [x] `TestReportDetailVO` 增加 `planExecutionMode` + `planItems`（仅 reportType=TEST_PLAN 时填充）
- [x] 新增 `TestReportPlanItemVO`（详情下钻：itemType / refName / status / subExecutionId / subReportType / errorMessage）
- [x] 新增 `TestReportCreateFromPlanDTO`
- [x] `TestReportService.createFromPlan` 实现（幂等 + detail JSON 含 subExecutionId）
- [x] `TestReportController` 新增 `POST /test-report/create/plan`
- [x] `buildDetailVO` 按 reportType 分流解析 detail JSON（TEST_PLAN 解析为 plan items）
- [x] list 查询：Mapper signature + XML 新增 `triggerType` / `testPlanId` 两个 WHERE 条件，SELECT 列加 4 个新字段
- [x] `PlanRunner.executeInternal` 收尾后调 `testReportService.createFromPlan`，并把 reportId 回填到 `tb_api_test_plan_execution.test_report_id`（生成失败仅记日志，不影响主流程）

### 前端
- [x] `Scene.TestReportListVO` / `TestReportDetailVO` / `TestReportListDTO` 类型扩展 4 个新字段
- [x] 新增 `Scene.TestReportPlanItemVO` 类型
- [x] `SceneReport.vue` 加「报告类型」+「触发方式」筛选下拉（替代原硬编码 `reportType=SCENARIO` 与 `triggerType=MANUAL`）
- [x] `SceneReport.vue` 列表新增「类型」+「所属计划」列；触发方式 tag 含 SCHEDULED / TEST_PLAN
- [x] `SceneReport.vue` URL `?testPlanId=xxx` → mount 时自动填入过滤
- [x] `TestReportDetailDialog.vue` 加 TEST_PLAN 渲染分支：执行模式 tag + 条目表（序号/名称/类型/环境/状态/HTTP 码/耗时/错误信息），其他类型保持原有 stepExecutions 渲染
- [x] `getStatusType` 增加 PASSED / CANCELLED 映射；新增 `getPlanItemStatusLabel`
- ⏭ 详情下钻按钮 → **首版不做**：API_CASE 因 PlanRunner 设 `saveHistory=false` 没有底层 ApiCaseExecution 记录，无法直接下钻；SCENARIO 有 subExecutionId 但需要先调 createFromScenario 生成 sub-report，体验复杂度高。当前以 errorMessage 内联展示满足主诉求，后续增强单独排期
- ⏭ ApiTestPlan 跳报告页的链接 → **首版不做**：tab 切换不改 URL，需要打通跨 tab 状态。当前 `?testPlanId=xxx` 只支持手动 URL 拼接

### 部署提醒
- ⚠️ `tb_test_report` ALTER 在 `V20260425__api_test_plan_execution.sql` 里已经写好，部署时随 Flyway 一并执行

### 校验
- [x] `mvn -pl test-mng-api-test-execution -am compile` 通过
- [x] `pnpm type:check` 0 错误

---

## 验证 / 联调
- [ ] 后端单元测试（PlanRunner 串 / 并 / 取消 / 失败 / 超时）
- [ ] 前后端联调（CRUD + 执行 + WebSocket + 报告）
- [ ] UI/UX 自查（参照 UI 设计规范 CLAUDE.md）

---

## 进度更新约定
- 完成一项就把 `[ ]` 改成 `[x]`
- 遇到阻塞或决策变化时，在对应 PR 段落底部加「⚠️ 阻塞 / 备注」一行说明
- 该文档与 `API_TEST_PLAN_DESIGN.md` 同步演进

---

## 阻塞 / 备注
（暂无）

---

## 代码审查 + 修复（2026-04-25）

详见 [API_TEST_PLAN_ISSUES.md](./API_TEST_PLAN_ISSUES.md)。

**本轮已修复（10 项）**：
- P0-1 异步执行与事务提交竞态（用 TransactionSynchronizationManager.afterCommit）
- P0-2 并行模式整体超时不等 futures（加 30s grace period + 强 cancel）
- P1-3 WebSocket 重连用过期 executionId（闭包捕获 execId）
- P1-4 CronScheduler init/scheduled 并发（reconcile 加 synchronized）
- P1-5 PlanRunner 用 0L 作为 userId（透传 executor_id 到下游）
- P1-6 StartupRecovery 多实例风险（加 enabled 配置开关）
- P2-8 finalizeExecution 用 LambdaUpdateWrapper 做 SELECT（改 LambdaQueryWrapper）
- P2-9 定时调度计划无 items 时刷错误日志（BizException → log.warn）
- P3-13 硬编码线程池大小（plan-pool-size / item-pool-size 可配）
- P3-18 默认 Cron 写死前端（提取 DEFAULT_CRON_EXPRESSION 常量）

**待用户确认（7 项）**：P2-7 / P2-10 / P2-11 / P2-12 / P3-14 / P3-15 / P3-17

### 校验
- [x] `mvn -pl test-mng-api-test-execution -am compile` 通过
- [x] `pnpm type:check` 通过

---

## 前端拆分（2026-04-25）

`ApiTestPlan.vue` 1636 行 → 5 个文件：

| 文件 | 行数 | 职责 |
|------|------|------|
| `views/case/detail/components/scene/ApiTestPlan.vue` | 1271 | 主组件 |
| `views/case/detail/components/scene/ApiTestPlanFormDialog.vue` | 150 | 新建/编辑计划 |
| `views/case/detail/components/scene/ApiTestPlanImportDialog.vue` | 190 | 导入条目 |
| `views/case/detail/components/scene/ApiTestPlanEnvDialog.vue` | 113 | 单条/批量环境 |
| `hooks/useApiTestPlanWebSocket.ts` | 172 | WebSocket 状态 composable |

主文件减少 22%；保留 cron section / 条目表 / 重命名弹窗 inline（强耦合，硬拆代价高）。

`pnpm type:check` 通过，无 TS 错误。
