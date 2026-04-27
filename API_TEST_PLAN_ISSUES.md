# 接口测试计划 — 代码审查发现的问题

> 评审日期：2026-04-25
> 评审范围：PR-1 到 PR-5 全部代码（后端 ~3900 行 / 前端 ~2250 行）
> 状态标记：✅ FIXED（本轮已修复） · ⏸ PENDING（等用户确认）

---

## 🔴 P0 — 严重 Bug

### P0-1. 异步执行与事务提交的竞态（数据可能完全丢失）  ✅ FIXED

**位置**：`test-mng-api-test-execution/src/main/java/cloud/aisky/service/impl/ApiTestPlanExecutionServiceImpl.java:71-155`

**问题**：`run()` 方法标了 `@Transactional`，事务在方法 return 之后才 commit。但方法内同步触发了 `planRunner.executeAsync(...)`：

```java
@Transactional(rollbackFor = Exception.class)
public Long run(Long planId, ...) {
    executionMapper.insert(execution);
    executionItemMapper.insert(ei);
    planRunner.executeAsync(execution.getId(), plan, runnerItems);  // ← 此时事务未提交
    return execution.getId();   // ← 事务在这之后才 commit
}
```

异步线程使用独立 DB 连接（独立事务），MySQL 默认 RR 隔离 → 看不到主事务未提交的 INSERT。后果：

- `markItemRunning(id)` UPDATE 影响 0 行
- `apiCaseExecutionService.execute` 跑完了 HTTP，结果落不进去
- `finalizeExecution` 的 SELECT 查不到 items → passed/failed/cancelled 全 0

实际是否触发取决于异步线程调度时序——大多数情况下异步线程在 commit 后才执行第一条 SQL，看起来"正常"，但是时序炸弹。

**修复**：使用 `TransactionSynchronizationManager.registerSynchronization` 在 `afterCommit` 触发异步。

---

### P0-2. 并行模式整体超时不等 futures，cancel 标志被过早清除  ✅ FIXED

**位置**：`test-mng-api-test-execution/src/main/java/cloud/aisky/scheduler/PlanRunner.java:228-276` 与 `:122`

**问题**：并行模式下若 `CompletableFuture.allOf(...).get(timeout)` 超时：

```java
} catch (TimeoutException te) {
    cancellationManager.cancel(executionId);
    broadcaster.broadcast(...);
    // ← 没有 await futures，直接返回！
}
```

随后 `executeInternal` 立刻进入 `finalizeExecution → generateTestReport`，最后 `executeAsync` 的 finally 清除 cancel 标志。但仍有 N 个 item 任务在 itemPool 里跑，它们后续 `isCancelled` 返回 false，会继续把 status 写到 execution_item，覆盖刚刚被 finalizeExecution 写入的 "cancelled"。

**修复**：超时后给 30 秒 grace period 等 futures 自然排空，仍未结束的则强 cancel future。

---

## 🟠 P1 — 高优先级

### P1-3. WebSocket 重连用过期的 executionId  ✅ FIXED

**位置**：`test-mng-web/src/views/case/detail/components/scene/ApiTestPlan.vue:1109-1121`

**问题**：

```ts
ws.onclose = event => {
  if (executing.value && event.code !== 1000 && reconnectAttempts < maxReconnectAttempts) {
    setTimeout(() => {
      if (executing.value && executionId.value)
        connectWebSocket(executionId.value, true);   // ← executionId 可能是别的计划的
    }, reconnectDelay);
  }
};
```

切换计划时旧 WS 的 onclose 异步触发 → 3 秒后 setTimeout 跑，`executionId.value` 已经是新计划的 → 错误地为新计划再开一个 WS。

**修复**：把 execId 关在闭包里，只在仍是同一个 execId 时才重连。

---

### P1-4. ApiTestPlanCronScheduler 启动期间可能与 @Scheduled 并发  ✅ FIXED

**位置**：`test-mng-api-test-execution/src/main/java/cloud/aisky/scheduler/ApiTestPlanCronScheduler.java:52-115`

**问题**：`@PostConstruct init()` 调 `reconcile()`，如果初次慢，60s 后 `@Scheduled` 也触发。两条线都修改 `registeredTasks` / `registeredCron`，可能导致同 planId 注册两次（旧 ScheduledFuture 没被 cancel 就被覆盖）。

**修复**：`reconcile()` 加 `synchronized`。

---

### P1-5. PlanRunner 用 0L 作为 userId 调下游服务  ✅ FIXED

**位置**：`PlanRunner.java:337, 364`

```java
apiCaseExecutionService.execute(req, /* userId */ 0L);
scenarioExecutionService.create(req, /* userId */ 0L);
```

如果下游服务做了用户校验、写审计记录、或在外键引用 user 表，`0L` 会引发数据完整性问题或外键失败。

**修复**：从 execution 记录拿 `executorId`（手动触发时是真实用户，定时为 null），通过 `executeAsync` 参数传入 `PlanRunner`，再透传到下游。

---

### P1-6. PlanExecutionStartupRecovery 在多实例下会误杀其他实例的执行  ✅ FIXED

**位置**：`test-mng-api-test-execution/src/main/java/cloud/aisky/scheduler/PlanExecutionStartupRecovery.java`

**问题**：启动时无条件把所有 `running/pending` 标 cancelled。多实例部署 / 滚动升级时，新实例会误杀其他活实例的 executions。

**修复（本轮）**：加配置开关 `api-test-plan.startup-recovery.enabled` 默认 true，多实例部署时可关闭。
**长期**：需要 `executor_node_id` 或 `last_heartbeat_at` 字段 → ⏸ 单独排期。

---

## 🟡 P2 — 中等问题

### P2-7. 测试报告生成失败时 reportId 无法回填  ✅ FIXED

**位置**：`PlanRunner.java:generateTestReport`

**决策**：即时重试 1 次，再失败接受失败（仅记日志）。

**修复**：用循环 + 500ms 间隔重试一次，重试期间打 warn 日志，最终失败打 error。

---

### P2-8. finalizeExecution 用 LambdaUpdateWrapper 做 SELECT  ✅ FIXED

**位置**：`PlanRunner.java:537-540`

```java
List<ApiTestPlanExecutionItem> items = executionItemMapper.selectList(
    new LambdaUpdateWrapper<...>()  // ← 应该是 LambdaQueryWrapper
        .eq(...)
);
```

功能上能跑（两者都继承 `AbstractWrapper`），但语义错误。

**修复**：改成 `LambdaQueryWrapper`。

---

### P2-9. 定时调度计划无 items 时刷错误日志  ✅ FIXED

**位置**：`ApiTestPlanCronScheduler.triggerScheduled`

`run` 在 items 为空时抛 `BizException`，被 generic Exception 捕获后 log.error。每 60 秒一次定时调度，如果用户清空了某计划的 items，日志会被刷屏。

**修复**：单独捕获 `BizException` 改为 log.warn。

---

### P2-10. SceneReport 状态过滤对 TEST_PLAN 类型无效  ✅ FIXED

**位置**：`TestReportServiceImpl.createFromPlan`

**决策**：方案 A — 后端写入时把 execution.status（passed/failed/cancelled）映射成 `tr.status`（SUCCESS/FAILED/CANCELLED），与现有 SCENARIO/CASE 的状态值对齐，前端 filter 直接生效。

**修复**：
- passed → SUCCESS（命中 filter "成功"）
- failed → FAILED（命中 filter "失败"）
- cancelled → CANCELLED（filter "全部" 时可见）
- 其他 → COMPLETED（兜底）

---

### P2-11. importItems 没有数量上限  ❌ NOT NEEDED（结合用户问询）

**位置**：`ApiTestPlanServiceImpl.java:325-372`

**评估**：
- 前端导入弹窗一次性最多拉 200 条候选（`size:200`），用户即使全选也只 200 个 INSERT，可控
- 即使有人通过 API 直接调用，1000 次 INSERT 在 ms 级单库 InnoDB 里也是秒级完成
- `selectCount(scenario_id)` 的 N+1 在场景多步时会慢一点，但场景数本身不会很大

**结论**：不加硬上限，保留现状。如果后续真的出现 import 慢的反馈，再优化为批量 GROUP BY 查 stepCount。

---

### P2-12. 删除计划后执行历史的 plan_id 悬挂引用  ✅ ACCEPTED（现状）

**位置**：`ApiTestPlanServiceImpl.delete()`

**评估**：
- `tb_api_test_plan_execution.plan_name` 已经在执行触发时做了快照
- `tb_test_report.test_plan_name` 也是快照，删 plan 不影响报告展示
- 计划列表 API 用 `@TableLogic` 软删过滤，删除的 plan 不出现在 `currentPlan`，前端 `v-if="currentPlan"` 已经显示空状态
- 唯一边界场景：plan 删除时仍有 running execution → 执行会自然完成；前端看不到这个 plan 也访问不到执行（已隔离）

**结论**：现状可接受，无需代码改动。已在 `PlanExecutionStartupRecovery` 注释中说明多实例风险，无新增问题。

---

## 🟢 P3 — 改进建议

### P3-13. 硬编码线程池大小  ✅ FIXED

**位置**：`PlanRunner.init()`

固定 `planPool=20` / `itemPool=40`，应该走配置。

**修复**：增加 `api-test-plan.plan-pool-size` / `api-test-plan.item-pool-size` 配置项。

---

### P3-14. WebSocket 协议消息格式无版本号  ⏸ DEFERRED

**决策**：先不加。现在加属于 premature optimization；真要演进时（比如后端改字段格式）再加 v 字段，前后端一起升级。

---

### P3-15. 拖拽排序的 sortablejs 与 el-table 的 DOM 同步问题  ⏸ DEFERRED

**决策**：现状能跑（与 UI 测试计划同结构），最后再考虑是否迁移 vuedraggable。

---

### P3-16. cron-parser v5 import 用法已确认正确  N/A

`cron-parser` v5+ 把 `parseExpression` 重命名为 `parse`。当前 `import parser from "cron-parser"; parser.parse(...)` 是正确的。无需修复。

---

### P3-17. selectReportPage 的 hasShareLink 子查询性能  ✅ FIXED

**位置**：`TestReportMapper.xml:selectReportPage`

**修复**：从按行 `EXISTS` 子查询改成一次性聚合 `LEFT JOIN (SELECT report_id, COUNT(*) GROUP BY report_id) sl_active`。N 行查询合并为 1 次扫描。

---

### P3-18. 默认 Cron `"0 9 * * *"` 写死在前端  ✅ FIXED

**位置**：`ApiTestPlan.vue:1372`

提取为常量。

---

## 修复进度汇总

| 编号 | 优先级 | 问题简述 | 状态 |
|------|--------|---------|------|
| P0-1 | 🔴 | 事务/异步竞态 | ✅ |
| P0-2 | 🔴 | 并行超时不等 futures | ✅ |
| P1-3 | 🟠 | WebSocket 重连用过期 execId | ✅ |
| P1-4 | 🟠 | CronScheduler init/scheduled 并发 | ✅ |
| P1-5 | 🟠 | PlanRunner 用 0L 作为 userId | ✅ |
| P1-6 | 🟠 | StartupRecovery 多实例风险 | ✅ |
| P2-7 | 🟡 | 报告生成失败无重试 | ✅（重试 1 次） |
| P2-8 | 🟡 | LambdaUpdateWrapper 误用 | ✅ |
| P2-9 | 🟡 | 定时调度空 items 刷错误日志 | ✅ |
| P2-10 | 🟡 | TEST_PLAN 状态筛选无效 | ✅（写入时映射） |
| P2-11 | 🟡 | importItems 无数量上限 | ❌ NOT NEEDED |
| P2-12 | 🟡 | 删除计划悬挂引用 | ✅ ACCEPTED |
| P3-13 | 🟢 | 硬编码线程池大小 | ✅ |
| P3-14 | 🟢 | WS 协议无版本号 | ⏸ DEFERRED |
| P3-15 | 🟢 | sortablejs vs el-table | ⏸ DEFERRED |
| P3-16 | 🟢 | cron-parser 用法 | N/A |
| P3-17 | 🟢 | hasShareLink 子查询 | ✅ |
| P3-18 | 🟢 | 默认 Cron 写死 | ✅ |

**已修复**：13 项 · **不需要 / 接受现状**：2 项 · **延后**：2 项 · **N/A**：1 项
