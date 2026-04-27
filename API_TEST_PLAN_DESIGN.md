# 接口测试计划（API Test Plan）功能设计文档

> 参考 UI 测试计划（`test-mng-web/src/views/case/detail/components/UiTestPlan.vue` + `test-mng-service/test-mng-ui-auto` 下的计划相关后端）实现一套面向"单接口 + 场景"的测试计划能力。

---

## 1. 背景与目标

### 1.1 背景
- 当前已有 UI 测试计划：支持计划 CRUD、用例导入、定时执行、WebSocket 实时日志、跨计划状态持久化等。
- 接口侧已有完整的「单接口」和「场景」管理与执行能力：
  - 单接口执行：`POST /api-test-execution/api-case-execution/execute`（同步）
  - 场景执行：`POST /api-test-execution/scenario-execution/create`（异步，返回 executionId，客户端轮询 `/scenario-execution/detail`）
- 缺少一个"批量编排 + 定时 + 串并行调度"的高层容器。

### 1.2 目标
产出一个与 UI 测试计划对等、但面向接口场景的"接口测试计划"模块：
1. 计划 CRUD + 搜索 + 右键菜单（重命名/执行/编辑/删除）
2. 导入"单接口"和"场景"两类对象到同一个计划
3. **串行 / 并行**执行模式切换；并行上限 **5** 个并发
4. **拖拽排序**（串行时按顺序执行）
5. **批量设置执行环境**（多选 + 一次性覆盖）
6. 定时执行（Cron + AI 生成）
7. WebSocket 实时日志 + 执行状态跨计划保持
8. 执行历史（测试报告后续另行设计，本文档预留表结构）

### 1.3 非目标
- YAML 预览（本模块不做）
- 执行报告可视化（后续补充）
- 与 Jenkins / 外部 CI 集成（后续）

### 1.4 已确认的关键决策
> 在 §4 / §5 实现细节前先汇总，避免回查。

| 决策项 | 选择 |
|---|---|
| 并行并发上限 | **全局共享** Semaphore(5)，可配置 |
| 串行模式失败处理 | **失败继续**（不短路），后续可加 `fail_fast` |
| 同一计划并发执行 | **允许多实例同时跑**（不加锁，每次执行独立 executionId） |
| 权限校验 | **不做权限校验**，任何登录用户都可 CRUD/执行 |
| 定时执行的执行人显示 | `system` / `系统调度`（executor_id=null, executor_name="系统"） |
| 计划整体超时 | **2 小时** hard timeout（可配置） |
| 单 item 超时 | 接口 = **90s**（沿用现有）<br>场景 = **步数 × 90s** （以场景包含的接口数动态计算） |
| AI Cron 服务 | **抽到 `test-mng-common`**（公共模块），UI/API 测试计划共用 |
| 定时任务存储 | **复用** `tb_scenario_schedule_task` 表，加 `task_type` 字段区分 `SCENARIO` / `TEST_PLAN`；`tb_api_test_plan` **不**内嵌 cron 字段 |
| 定时任务列表入口 | 「测试报告」tab 后已有的「定时任务」tab，统一展示两类，加「类型」列 |

---

## 2. 信息架构与入口

### 2.1 Tab 位置
文件：`test-mng-web/src/views/case/detail/components/scene/SceneIndex.vue`

当前 `navTabs` 定义（约 L113–118）：
```ts
const navTabs = [
  { label: "单接口", value: "api-test" },
  { label: "场景", value: "scene" },
  { label: "测试报告", value: "report" },
  { label: "定时任务", value: "schedule-task" }
];
```

调整为：
```ts
const navTabs = [
  { label: "单接口", value: "api-test" },
  { label: "场景", value: "scene" },
  { label: "接口测试计划", value: "api-test-plan" },   // ← 新增
  { label: "测试报告", value: "report" },
  { label: "定时任务", value: "schedule-task" }
];
```

### 2.2 顶部「新建计划」按钮
参照 UI 测试计划在 `test-mng-web/src/views/case/detail/index.vue` 中的做法（L124–125）：根据当前激活的二级 tab 条件渲染。新增接口测试计划的按钮渲染：
```vue
<template v-else-if="currentApiNavTab === 'api-test-plan'">
  <el-button
    type="primary"
    class="case-detail-page__primary-btn"
    @click="handleCreateApiTestPlan"
  >
    新建计划
  </el-button>
</template>
```
该按钮仅在"接口测试计划"tab 激活时显示，且**不并列搜索框**（搜索能力已内置在 `CommonPlanList` 里）。父页面通过 `ref` 调用子组件暴露的 `openCreatePlanDialog()` 方法打开新建弹窗（与 UI 计划同构）。

---

## 3. 前端设计

### 3.1 新增文件

| 路径 | 作用 |
|---|---|
| `src/views/case/detail/components/scene/ApiTestPlan.vue` | 接口测试计划主组件（参考 `UiTestPlan.vue` 直接复制裁剪） |
| `src/views/case/detail/components/scene/ApiTestPlanScheduleTaskDialog.vue` | 测试计划定时任务弹窗（去掉环境字段；**只在「定时任务」tab 行编辑时使用**——计划详情面板用内联 section，不调本弹窗） |
| `src/api/interface/apiTestPlan.ts` | 类型定义命名空间 `ApiTestPlan`；**注意**：`PlanItem` / `UpdateBody` 中的 `cronEnabled` / `cronExpression` 字段需要**移除**（cron 已迁到 schedule_task） |
| `src/api/interface/apiTestPlanScheduleTask.ts` | 测试计划定时任务类型定义 |
| `src/api/modules/apiTestPlan.ts` | 计划 CRUD/条目/执行 API 调用封装 |
| `src/api/modules/apiTestPlanScheduleTask.ts` | 测试计划定时任务 CRUD 调用封装 |
| `src/stores/modules/apiTestPlanExecution.ts` | 执行状态 Store（与 `testPlanExecution.ts` 结构一致） |

> 「负责人下拉框」（带头像 + 企业名 tag）已抽成全局组件 `src/components/MemberSelect/index.vue`，UI/接口测试计划共用，**不属于本模块新增**。新建/编辑计划弹窗里直接写：
> ```vue
> <MemberSelect v-model="planForm.maintainerId" :accounts="accountList" :enterprise-name="enterpriseName" @change="m => syncMaintainerName(m)" />
> ```
> 不传 `accounts` 时组件按当前企业自动拉取成员列表；`change` 事件回传选中的 `Auth.Account`，可直接用来回写 `maintainerName`，免去父组件再 `find()`。

### 3.2 修改文件

| 路径 | 变更点 |
|---|---|
| `src/views/case/detail/components/scene/SceneIndex.vue` | `navTabs` 新增一项；引入并 `v-show` 渲染 `ApiTestPlan` 组件 |
| `src/views/case/detail/index.vue` | 顶部工具栏条件渲染"新建计划"按钮；通过 ref 调用子组件打开弹窗 |

### 3.3 页面布局（与 UI 测试计划同构）

```
┌──────────────────────────────────────────────────────────────┐
│ [顶部页面 header]                 ……          [新建计划] ← tab=api-test-plan 时显示
├────────────────┬─────────────────────────────────────────────┤
│ 左侧计划列表   │ 右侧详情                                    │
│                │ ┌─ 标题栏：计划名 / 执行·编辑·复制·删除 ─┐│
│ ┌搜索框─────┐  │ ├─ 基本信息（描述、负责人、时间）─────────┤│
│ │ 计划名 A   │  │ ├─ 执行模式（● 串行  ○ 并行 最大 5）─────┤│
│ │ 计划名 B ◀ │  │ ├─ 定时执行（switch + cron 输入 + AI 生成）─┤│
│ │ …         │  │ │   ↑ 与 UI 测试计划同构（cronstrue 中文预览 + 下5次）│
│ │ …         │  │ ├─ 条目列表（单接口 + 场景，拖拽）──────┤│
│ └───────────┘  │ │   [批量设置环境] [批量移除] [导入条目]│
│ （右键菜单：   │ │   ┌─┬─┬──────┬─────┬──────┬─────┬──┐│
│   执行/重命名/ │ │   │☐│≡│ 名称 │类型 │环境  │来源 │操作│
│   编辑/删除）  │ │   └─┴─┴──────┴─────┴──────┴─────┴──┘│
│                │ ├─ 执行状态（tag + 实时日志）─────────────┤│
└────────────────┴──────────────────────────────────────────────┘
```

### 3.4 关键交互

#### 3.4.1 条目列表（核心差异）
条目有两种类型（`item_type`）：
- `API_CASE`：单接口用例（对应 `ApiCase.id`）
- `SCENARIO`：场景（对应 `TestScenario.id`）

列结构：
| 列 | 说明 |
|---|---|
| 多选 checkbox | 批量操作使用 |
| 拖拽把手 `≡` | `vuedraggable` 实现，仅在串行模式下启用（并行模式下图标置灰+tooltip） |
| 名称 | `API_CASE` 显示 `apiName` + method badge；`SCENARIO` 显示场景名 |
| 类型 | `<el-tag>` 区分接口/场景 |
| 执行环境 | 显示覆盖环境名；为空时以灰色显示「默认（源环境名）」 |
| 来源默认环境 | 只读，提示真实来源 env（方便对比） |
| 操作 | 单条移除 / 单条设置环境 |

**拖拽实现**：项目已在 `package.json` 中引入 `vuedraggable@^4.1.0` + `sortablejs@^1.15.2`。用 `<draggable>` 包裹 `<el-table>` 的 rows 或直接使用 `<el-table>` 的 `row-key` + 外部 `Sortable` 实例监听 `onEnd`，拖拽结束调用 `reorderItemsApi`（见 §4.2）。

#### 3.4.2 批量设置环境
1. 选中多行（顶部 checkbox 支持全选）。
2. 出现"批量设置环境"按钮（`v-if="selectedItems.length > 0"`）。
3. 点击后弹出 `CommonDialog`：
   - `<el-select>` 拉取当前 caseLibrary 下的环境列表（复用 `getEnvironmentListApi`，已有接口）
   - 额外选项：**"恢复为源默认环境"**（后端将 `environment_id` 置为 NULL）
4. 确认后调用 `batchSetItemEnvironmentApi(planId, itemIds, environmentId | null)`。

#### 3.4.3 执行模式开关
- 位于"基本信息"下方的独立 section：
  ```
  执行模式：  [●串行 ○并行]   ℹ 并行最多 5 个同时执行
  ```
- `<el-radio-group>` 绑定 `currentPlan.executionMode`（`SERIAL` / `PARALLEL`）。
- 切换时直接调 `updateApiTestPlanApi` 落库。
- 并行模式下禁用拖拽把手，并隐藏拖拽列的 tooltip 改为"并行模式下顺序无意义"。

#### 3.4.4 导入弹窗
与 UI 测试计划类似，但有两类来源。实现方案：
- 弹窗顶部 `<el-radio-group>` 切换「来源：单接口 / 场景」
- 根据选择分别调用：
  - 单接口：`getApiCaseListByServiceIdApi`（`/api-test/api-case/listBySpaceId`，已存在）
  - 场景：`getSceneListPageApi`（`/api-test/test-scenario/list`，已存在）
- 表格多选，底部显示"已选 N 个"
- 确认时调 `importItemsApi(planId, items: { itemType, refId, refName }[])`

> 也可做两个 tab 并列导入，但一次性导入一类更简单，工作量更低。

#### 3.4.5 执行模式与实时日志
复用 UI 测试计划的 WebSocket 协议（§4.5），前端日志渲染逻辑可完全复用 `UiTestPlan.vue` 的 `onmessage` 分支（`step_begin` / `step_end` / `log` / `progress` / `heartbeat` / `complete` / `cancelled` / `error`）。

差异点：
- 步骤标题不再有 `ai-runYaml` 精简逻辑，改为原样显示每个 item 的名称。
- 多了一个 `item_begin` / `item_end` 聚合层（后端发送），以便前端区分"当前执行第几个 item"。

### 3.5 Store 形态
`src/stores/modules/apiTestPlanExecution.ts`，结构与 `testPlanExecution.ts` 完全一致，仅 key 空间独立（避免串台）：
```ts
interface ApiPlanExecutionState {
  executing: boolean;
  executionId: string;
  executionStatus: string;   // "" | "running" | "passed" | "failed" | "cancelled"
  executionLogs: string[];
  planId: string;
  planName: string;
}
// Map<planId, state>
```

### 3.6 「定时任务」tab 的统一改造

#### 3.6.1 现状
- 现有「定时任务」tab 在 `SceneIndex.vue` 已存在，宿主组件是 `SceneScheduleTask.vue`
- 当前只调 `getScenarioScheduleTaskListApi`，列表只展示场景定时

#### 3.6.2 改造点
- `SceneScheduleTask.vue`（**保留文件名**避免大改）调用的接口不变（`/scenario-schedule-task/list`），但**不再传 `taskType`**，由后端返回所有类型
- 表格新增「类型」列（紧跟"任务名称"右侧）：
  ```vue
  <el-table-column label="类型" width="100">
    <template #default="{ row }">
      <el-tag :type="row.taskType === 'TEST_PLAN' ? 'warning' : 'info'">
        {{ row.taskType === 'TEST_PLAN' ? '测试计划' : '场景' }}
      </el-tag>
    </template>
  </el-table-column>
  ```
- 操作列分支：
  | 操作 | SCENARIO | TEST_PLAN |
  |---|---|---|
  | 详情 | 现有 `ScheduleTaskDialog`（场景版） | 新增 `ApiTestPlanScheduleTaskDialog`（去掉环境字段，把场景选择器换成计划选择器） |
  | 立即执行 | 现有接口 | 同接口（后端已分发） |
  | 启停切换 | 现有接口 | 同接口 |
  | 删除 | 现有接口 | 同接口（语义=删除该定时任务记录，**不影响计划本身**） |

#### 3.6.3 计划页面的定时任务入口（**对齐 UI 测试计划：内联 cron 配置**）

**关键决策**：与 `UiTestPlan.vue` UI/交互保持完全一致——**内联**定时配置 section（不是弹窗按钮），每个 plan 走 1:1 模型。

```
┌─ 定时执行 ─────────────────────────────────────────────┐
│ [● 启用定时执行]                                       │
│ ┌─────────────┐ [保存] 或 [描述输入框] [AI 生成 ⓘ]   │
│ │ 0 9 * * *   │                                        │
│ └─────────────┘                                        │
│ 执行规则：每天上午 9:00（cronstrue 中文）             │
│ 接下来 5 次执行时间： [...] [...] [...]                │
│ 常用示例（点击填写）： [每天9:00] [工作日9:00] ...    │
│ ⓘ 格式：分钟 小时 日 月 星期                           │
└────────────────────────────────────────────────────────┘
```

**实现要点**（`ApiTestPlan.vue`）：
- 切换 plan 时调 `listApiTestPlanScheduleTasksByPlanApi(planId, current=1, size=1)`，取首条作 `currentScheduleTask` 填表单
- **启停切换**：
  - 开启：若 `currentScheduleTask` 存在 → `toggleScenarioScheduleTaskStatusApi(id, true)`；否则 → `createApiTestPlanScheduleTaskApi(...)`（默认 cron `0 9 * * *`）
  - 关闭：`toggleScenarioScheduleTaskStatusApi(id, false)`，**保留任务记录**（用户再次启用时复用）
- **保存**：有记录则 update，无则 create；不主动改启停
- **AI 生成**：`generateCronByAiApi(enterpriseId, description)`（直接复用 `@/api/modules/uiTestPlan` 中已有的 endpoint，跨模块通用）
- **下 5 次执行时间**：前端用 `cron-parser` 计算；**表达式中文描述**：用 `cronstrue/i18n` 渲染

**1:1 vs 多对一权衡**：表层支持一个 plan 多条 schedule task，但**计划详情面板内联只展示 / 编辑最新一条**。如果用户通过其他途径（API、未来扩展）创建多条，只能在「定时任务」tab 看到全部、用 `ApiTestPlanScheduleTaskDialog` 编辑。这保持了 UI 与 UiTestPlan 一致的简化心智模型。

#### 3.6.4 新增 / 修改文件清单

| 路径 | 改动 |
|---|---|
| `src/api/interface/scene-schedule-task.ts` | VO/DTO 加 `taskType?: "SCENARIO" \| "TEST_PLAN"` 字段；list DTO 加可选 `taskType` 过滤 |
| `src/api/interface/apiTestPlanScheduleTask.ts` | **新增** TS 命名空间 |
| `src/api/modules/apiTestPlanScheduleTask.ts` | **新增** create/update/detail/list-by-plan 调用封装 |
| `src/views/case/detail/components/scene/SceneScheduleTask.vue` | 加类型列；操作列根据 taskType 分支打开不同弹窗 |
| `src/views/case/detail/components/scene/ScheduleTaskDialog.vue` | list 调用加 `taskType: "SCENARIO"` 过滤（防共表跨类型 ID 误匹配） |
| `src/views/case/detail/components/scene/ApiTestPlanScheduleTaskDialog.vue` | **新增**（仅供「定时任务」tab 行编辑使用，不在计划详情面板使用） |
| `src/views/case/detail/components/scene/ApiTestPlan.vue` | 内联 cron section（switch / cron 输入 / AI 生成 / 示例 / 预览 / 下 5 次），与 UiTestPlan.vue 1:1 一致 |

---

## 4. 后端设计

### 4.1 模块归属
遵循接口测试现有分层：
- **CRUD / 元数据管理** → `test-mng-api-test`
  - 包结构按**现有扁平约定**（不分子模块前缀）：
    - `cloud.aisky.controller.ApiTestPlanController`
    - `cloud.aisky.service.ApiTestPlanService` + `cloud.aisky.service.impl.ApiTestPlanServiceImpl`
    - `cloud.aisky.mapper.ApiTestPlanMapper`（同名共 4 个）
    - `cloud.aisky.entity.ApiTestPlan`（同名共 4 个）
    - `cloud.aisky.dto.ApiTestPlanXxxDTO`
    - `cloud.aisky.vo.ApiTestPlanXxxVO`
- **执行引擎** → `test-mng-api-test-execution`
  - 同样扁平包结构，`cloud.aisky.{controller|service|...}.ApiTestPlanExecution*`
  - 调度逻辑、并发控制、WebSocket 日志出口都放这里
  - 通过 **内部调用** 已有的 `ApiCaseExecutionService` 和 `ScenarioExecutionService`（同模块），或通过 **Feign** 调用 `test-mng-api-test` 拉取元数据

> 路由前缀参照现有：`/api-test/**` → `test-mng-api-test`，`/api-test-execution/**` → `test-mng-api-test-execution`。

#### 4.1.1 现有代码风格速查（与 CLAUDE.md 描述存在偏差，以代码为准）
| 维度 | 实际约定 |
|---|---|
| 响应包装 | `JsonDataVO<T>`（`new JsonDataVO<T>().buildSuccess(data)` / `.buildError(msg)`），**不是** `Result<T>` |
| 分页响应 | `PageDataVO<T>`（含 `pageNum/pageSize/total/list`，构造器接 MyBatis Plus `Page`） |
| 分页请求 | `extends PageBaseDTO`（含 `current/size` 字段） |
| 业务异常 | `BizException(Integer code, String msg)` 或 `BizException(BizCodeEnum)`，**不是** `BusinessException` |
| HTTP method | 一律 `@PostMapping`，包括查询和删除 |
| 依赖注入 | 字段 `@Autowired`（虽然 CLAUDE.md 说用 `@RequiredArgsConstructor`，但现有代码全部用 `@Autowired`，保持一致即可） |
| Controller 注解 | 类级 `@Validated` + `@Tag` + `@RequestMapping("/xxx")`；方法级 `@Operation(summary)` + `@Validated @RequestBody` |
| DTO 命名 | `XxxCreateRequestDTO` / `XxxUpdateRequestDTO` / `XxxIdDTO` / `XxxPageDTO`（不是 `CreateDTO/UpdateDTO/QueryDTO`） |
| VO 命名 | `XxxVO` / `XxxDetailVO` |
| 字段 Schema | 全部 DTO/VO 字段用 `@Schema(description="...")`（用户 memory 强制） |
| Mapper | `@Mapper interface XxxMapper extends BaseMapper<Xxx>` |
| 当前用户 | `SessionUtils.getCurrentUserId()` |
| Converter | **不存在统一 Converter 类约定**，现有代码在 ServiceImpl 里用 `BeanUtil.copyProperties` 或手工 set。我们沿用此风格，不引入新的 Converter 类 |

### 4.2 API 端点清单
所有路径均挂在网关 `/api-test` 或 `/api-test-execution` 前缀下。

#### 4.2.1 计划 CRUD（`test-mng-api-test`）
| Method + Path | 说明 |
|---|---|
| `GET /api-test/v1/test-plans?enterpriseId&caseLibraryId&keyword&page&size` | 列表（支持关键字搜索） |
| `POST /api-test/v1/test-plans` | 新建 |
| `POST /api-test/v1/test-plans/{planId}` | 更新（含 executionMode、parallelLimit、maintainerId 等；**不含 cron**，cron 由 §4.2.4 管理） |
| `DELETE /api-test/v1/test-plans/{planId}` | 删除 |
| `POST /api-test/v1/test-plans/{planId}/copy` | 复制（含所有 item，不含执行历史与定时任务） |

#### 4.2.2 条目管理（`test-mng-api-test`）
| Method + Path | 说明 |
|---|---|
| `GET /api-test/v1/test-plans/{planId}/items` | 条目列表（联表拼装名称、默认环境） |
| `POST /api-test/v1/test-plans/{planId}/items/import` | 导入（body: `[{itemType, refId, refName}]`） |
| `DELETE /api-test/v1/test-plans/{planId}/items/{itemId}` | 移除单条 |
| `POST /api-test/v1/test-plans/{planId}/items/batch-remove` | 批量移除 |
| `POST /api-test/v1/test-plans/{planId}/items/reorder` | 拖拽排序（body: `[itemId]` 顺序） |
| `POST /api-test/v1/test-plans/{planId}/items/{itemId}/environment` | 单条设置环境 |
| `POST /api-test/v1/test-plans/{planId}/items/batch-env` | 批量设置环境（body: `{itemIds, environmentId \| null}`） |

#### 4.2.3 定时任务（`test-mng-api-test-execution`，与场景定时同服务）
新增一组只属于"测试计划"的定时 CRUD（底层共用 `tb_scenario_schedule_task` 表，写入时 `task_type='TEST_PLAN'`）：

| Method + Path | 说明 |
|---|---|
| `POST /api-test-plan-schedule-task/create` | 新建测试计划定时任务（body: `{spaceId, planId, taskName, cronExpression}`） |
| `POST /api-test-plan-schedule-task/update` | 更新（body: `{id, taskName?, planId?, cronExpression?}`） |
| `POST /api-test-plan-schedule-task/detail` | 详情 |
| `POST /api-test-plan-schedule-task/list` | 按 plan 列出该计划下所有定时（`{spaceId, planId, current, size}`） |

**复用**现有场景定时接口（已可在统一 `task_type` 维度操作，新加 `taskType` 入参兼容旧调用）：

| Method + Path | 说明 |
|---|---|
| `POST /scenario-schedule-task/list` | **改造** 新增可选 `taskType` 入参（不传=全部，传`SCENARIO`/`TEST_PLAN`过滤）；VO 增加 `taskType` 字段 |
| `POST /scenario-schedule-task/toggle` | 启停（**完全复用**，操作语义一致） |
| `POST /scenario-schedule-task/execute-now` | 立即执行（**完全复用**，内部 `ScheduleTaskExecutor.doExecute` 已加 `task_type` 分支） |
| `POST /scenario-schedule-task/delete` | 删除定时（**完全复用**） |
| `POST /scenario-schedule-task/generate-cron` | AI 生成 cron（复用已有 AI 服务，UI/场景/测试计划共用） |

> 「定时任务」tab 的统一列表接口直接用 `POST /scenario-schedule-task/list`（不传 taskType），不另起 `unified-list` 接口。

#### 4.2.4 执行控制（`test-mng-api-test-execution`）
| Method + Path | 说明 |
|---|---|
| `POST /api-test-execution/v1/test-plans/{planId}/run` | 触发执行，返回 `executionId` |
| `POST /api-test-execution/v1/test-plans/executions/{executionId}/stop` | 停止 |
| `GET /api-test-execution/v1/test-plans/{planId}/executions?page&size` | 执行历史 |
| `GET /api-test-execution/v1/test-plans/executions/{executionId}` | 执行详情 |
| `GET /api-test-execution/v1/test-plans/{planId}/running-execution` | 当前是否有执行（前端恢复态 / 定时调度接管） |
| **WebSocket** `/api-test-execution/v1/ws/logs/{executionId}` | 实时日志流 |

### 4.3 服务分层（典型）
```
ApiTestPlanController
  └─ ApiTestPlanService (interface)
       └─ ApiTestPlanServiceImpl
            ├─ ApiTestPlanMapper (BaseMapper<ApiTestPlan>)
            ├─ ApiTestPlanItemMapper
            ├─ ApiTestPlanConverter (Entity ↔ DTO/VO)
            └─ Feign: ApiTestExecutionClient (触发执行)

ApiTestPlanExecutionController   (test-mng-api-test-execution)
  └─ ApiTestPlanExecutionService
       ├─ ApiTestPlanExecutionMapper
       ├─ ApiTestPlanExecutionItemMapper
       ├─ PlanRunner (核心调度 - 见 §4.4)
       ├─ ApiCaseExecutionService  (已有，执行单接口)
       ├─ ScenarioExecutionService (已有，执行场景)
       └─ LogBroadcaster (WebSocket 推送)
```

Controller 统一返回 `Result<T>` / `PageResult<T>`，业务异常抛 `BusinessException`（遵循 `CLAUDE.md` 约定）。DTO/VO 字段全部加 `@Schema`（见用户 memory `feedback_dto_vo_schema.md`）。

### 4.4 执行引擎：`PlanRunner`

#### 4.4.1 入口流程
```
run(planId, userId, userName):
  1. 加载 plan + items（按 sort_order 升序）
  2. 若无 items → 抛 BizException
  3. （不检查是否已有 running，允许多实例并发执行）
  4. 插入 tb_api_test_plan_execution，status=running
  5. 针对每个 item 插入 tb_api_test_plan_execution_item，status=pending
  6. 提交到 ExecutorService 异步跑，立即返回 executionId
  7. 异步线程：按 plan.executionMode 选择 serial() / parallel() 分支
  8. 结束后 UPDATE execution.status + finished_at + 汇总 passed/failed
```

#### 4.4.2 串行
```java
for (PlanItem item : items) {
  if (isCancelled(execId)) break;
  executeItem(item, execId);   // 同步阻塞，直到该 item 完成
}
```
- 默认"失败继续"，单 item 失败不会短路整个 plan（与行业惯例一致，后续可在 plan 表加 `fail_fast` 开关扩展）。

#### 4.4.3 并行 + 并发上限 5
```java
// Bean 单例，全局共享
ExecutorService planItemPool = Executors.newFixedThreadPool(20);
Semaphore concurrency = new Semaphore(5);   // 也可以 per-plan 独立

List<CompletableFuture<Void>> futures = items.stream()
  .map(item -> CompletableFuture.runAsync(() -> {
      concurrency.acquire();
      try {
        if (isCancelled(execId)) return;
        executeItem(item, execId);
      } finally {
        concurrency.release();
      }
  }, planItemPool))
  .toList();
CompletableFuture.allOf(futures.toArray(new CompletableFuture[0])).join();
```

**关键设计点**：
- 信号量 `Semaphore(5)` 控制**全局**接口测试计划并发度（所有计划共享），避免多个 plan 并发导致雪崩。如果需要每个 plan 独立 5 并发，则用 `new Semaphore(5)` 存在 per-execId 的 Map 中。本设计**默认全局共享**（更安全），放到 `application.yml` 配置项里可调：
  ```yaml
  api-test-plan:
    parallel-concurrency: 5
  ```
- `planItemPool` 容量 20，避免在一个 plan 巨大时占满 web 容器线程。

#### 4.4.4 单 item 执行
```java
void executeItem(PlanItem item, String execId) {
  updateItemStatus(item.id, "running");
  broadcast(execId, "item_begin", {index, name, itemType});

  Long envId = coalesce(item.environmentId,  // 覆盖优先
                        resolveSourceEnvId(item));  // 回退源默认

  // 单 item 超时计算（关键设计）
  long itemTimeoutMs = (item.itemType == API_CASE)
      ? 90_000L                                          // 单接口固定 90s
      : 90_000L * countSteps(item.refId);                // 场景按其包含的接口数 × 90s

  ItemResult result;
  try {
    if (item.itemType == API_CASE) {
      ApiCaseExecutionRequestDTO req = new ApiCaseExecutionRequestDTO();
      req.setCaseId(item.refId);
      req.setEnvironmentId(envId);
      req.setSaveHistory(false);   // 由 plan 自己记录
      ApiCaseTestResultVO r = apiCaseExecutionService.execute(req);
      result = mapFromApi(r);
    } else {
      ScenarioExecutionCreateDTO req = new ScenarioExecutionCreateDTO();
      req.setScenarioId(item.refId);
      req.setEnvironmentId(envId);
      String scExecId = scenarioExecutionService.create(req);
      // 阻塞轮询场景完成，超时按场景步数动态计算
      ScenarioExecutionVO r = pollScenarioUntilFinished(scExecId, itemTimeoutMs);
      result = mapFromScenario(r);
    }
    updateItemResult(item.id, "passed"/"failed", result);
  } catch (TimeoutException te) {
    updateItemResult(item.id, "failed", "执行超时（" + itemTimeoutMs + "ms）");
  } catch (Exception ex) {
    updateItemResult(item.id, "failed", errorResult(ex));
  }
  broadcast(execId, "item_end", {index, status, durationMs});
}
```

> **场景步数获取**：通过 Feign 调 `test-mng-api-test` 的 `tb_test_scenario_step` 查询，或在导入 item 时把步数 snapshot 到 `tb_api_test_plan_item.step_count`（更高效，避免运行时查询）。建议后者。

#### 4.4.5 停止
停止 = 在 Redis 里写一个取消标志 `api_plan_cancel:{executionId} = 1`，有效期 30 分钟。
- 未开始的 item：直接置为 `cancelled`
- 正在跑的 item：
  - 接口：同步执行，会跑完当前 HTTP 调用（时间短）
  - 场景：调用 `scenarioExecutionService.cancel(scExecId)`（若已有），或等其自己结束
- 结束后 execution.status = `cancelled`

### 4.5 WebSocket 协议
路径：`ws[s]://{host}/api-test-execution/v1/ws/logs/{executionId}`

消息格式（与 UI 测试计划保持一致，便于前端复用渲染代码）：
```json
{"type":"item_begin",   "data":{"index":0,"name":"登录接口","itemType":"API_CASE"}}
{"type":"step_begin",   "data":{"step_index":0,"title":"POST /login"}}
{"type":"log",          "data":{"level":"info","message":"环境=dev"}}
{"type":"step_end",     "data":{"status":"passed","duration_ms":120,"title":"POST /login"}}
{"type":"item_end",     "data":{"index":0,"status":"passed","duration_ms":135}}
{"type":"progress",     "data":{"message":"2/10 已完成"}}
{"type":"heartbeat",    "data":{}}
{"type":"complete",     "data":{"status":"passed","totalItems":10,"passed":9,"failed":1}}
{"type":"cancelled",    "data":{}}
{"type":"error",        "data":{"error":"..."}}
```

服务端实现用 Spring WebSocket（`@Controller` + `TextWebSocketHandler`），维护 `Map<executionId, Set<WebSocketSession>>`，broadcast 时遍历推送。心跳：服务端每 25s 发 `heartbeat`，客户端回相同消息保活。

### 4.6 定时调度

**关键决策：复用现有 `tb_scenario_schedule_task` 表 + 加 `task_type` 区分**，不在 `tb_api_test_plan` 内嵌 cron 字段。理由：
1. 表整套代码已经在 `test-mng-api-test-execution`（与 PlanRunner 同服务，本地方法调用，无需 Feign）
2. `ScenarioScheduleScheduler` + `ScheduleTaskExecutor` + Redisson 分布式锁机制已经成熟，加一个 type 分支即可
3. 字段 `last_execute_time` / `next_execute_time` / `last_execute_status` / `last_execution_id` 表里都有，不需要给 plan 表加冗余
4. 表层支持 1:N（一个 plan 多条定时），但**前端 UI 维持 1:1**（与 UiTestPlan 一致），见 §3.6.3

#### 4.6.1 表扩展（详见 §5.5）
```sql
ALTER TABLE tb_scenario_schedule_task
  ADD COLUMN task_type VARCHAR(16) NOT NULL DEFAULT 'SCENARIO'
       COMMENT '任务类型: SCENARIO=场景定时, TEST_PLAN=测试计划定时' AFTER id,
  ADD KEY idx_task_type_space (task_type, space_id);
```

字段语义复用：
- `scenario_id` → `SCENARIO` 时存场景 id；`TEST_PLAN` 时**存计划 id**（字段名误导，但不改名以避免大面积影响）
- `scenario_name` → 场景名 / 计划名快照
- `environment_id` → `SCENARIO` 时存环境；`TEST_PLAN` 时为 NULL（环境在 item 级覆盖，plan 级没有）
- 其余字段（cron_expression / task_status / last_execute_* / next_execute_* / create_user_* / time）完全通用

#### 4.6.2 调度器扩展
- `ScenarioScheduleScheduler.init()` 启动加载逻辑不变（按 `task_status=1 AND deleted=0` 扫全表，包含两类）
- `addTask` / `removeTask` 不变（操作泛型 task）
- **`ScheduleTaskExecutor.doExecute(taskId)` 加 type 分支**：
  ```java
  switch (task.getTaskType()) {
      case "SCENARIO" -> {
          ScenarioExecutionCreateDTO dto = ...;
          executionId = scenarioExecutionService.create(dto, userId, enterpriseId);
      }
      case "TEST_PLAN" -> {
          // 跑测试计划：scenarioId 字段实际存的是 planId
          executionId = planRunner.run(task.getScenarioId(), userId, enterpriseId, "SCHEDULED");
      }
  }
  ```
- 分布式锁、last/next 字段回写、错误处理逻辑完全复用

#### 4.6.3 CRUD API
- **toggle / delete / executeNow**：完全复用现有 scenario 接口（操作语义无差异，两类型都允许）。`executeNow` 内部已经走 `ScheduleTaskExecutor`，type 分支已支持。
- **list 接口改造**：现有 `/scenario-schedule-task/list` 加可选入参 `taskType`（不传 = 全部），VO 新增 `taskType` 字段返回。
- **create / update 拆开新增**：因入参差异（场景需 `environmentId` + `scenarioId`，测试计划需 `planId`，没有环境），新增 `ApiTestPlanScheduleTaskController` 提供 create / update / detail / list-by-plan 接口，**底层共用** `ScenarioScheduleTaskMapper`，写入时 `set task_type='TEST_PLAN'`。

#### 4.6.3.1 共表防误操作（重要）
两类 service 的 `update` / `getDetail` 在 load 实体时**必须校验 `task_type`**，否则跨类型 ID 会静默写脏数据：

```java
// ApiTestPlanScheduleTaskServiceImpl.loadTaskOrThrow
if (!TASK_TYPE.equals(entity.getTaskType())) {
    throw new BizException(BizCodeEnum.SCHEDULE_TASK_NOT_EXIST);
}
```
对称地，`ScenarioScheduleTaskServiceImpl.loadScenarioTaskOrThrow` 拒绝 `taskType` 非 `SCENARIO` 的行（兼容历史 `taskType=null` 视为 SCENARIO）。
`delete` / `toggleStatus` 故意保留不分类型（两种类型在「定时任务」tab 行级操作上需要统一接口）。

前端 `ScheduleTaskDialog.vue` 的 list 调用也必须传 `taskType: "SCENARIO"`，避免 `scenarioId` 与 `planId` 数值碰撞造成的跨类型误匹配。

#### 4.6.4 AI 生成 Cron
**抽到 `test-mng-common` 公共模块**，UI 测试计划与 API 测试计划共用。
- 公共类位置：`cloud.aisky.service.CronAiGenerator`（接口）+ `cloud.aisky.service.impl.CronAiGeneratorImpl`
- 入参：自然语言描述（如"每天早上9点"）+ 当前用户/企业上下文
- 出参：`{ cronExpression, cronDescription }`
- 实现细节：复用现有 prompt 封装 + Spring AI 调用
- UI 端：将 `test-mng-ui-auto` 中现有的 `generateCronByAi` 改为调用 common 接口（迁移工作量小，建议本次顺手做）

---

## 5. 数据库设计

> 表前缀沿用 `tb_`（与 `tb_api_case`、`tb_test_scenario` 一致），Schema 放在 `test-mng-api-test` 的 `src/main/resources/db/migration/` 下（Flyway 规范文件名 `V{version}__api_test_plan.sql`）。

### 5.1 `tb_api_test_plan` — 计划主表
```sql
CREATE TABLE tb_api_test_plan (
  id              BIGINT        NOT NULL COMMENT '主键（雪花）',
  enterprise_id   VARCHAR(64)   NOT NULL COMMENT '企业ID',
  case_library_id VARCHAR(64)   NOT NULL COMMENT '用例库ID（spaceId）',
  plan_name       VARCHAR(128)  NOT NULL COMMENT '计划名称',
  description     VARCHAR(500)  DEFAULT NULL COMMENT '描述',
  maintainer_id   VARCHAR(64)   DEFAULT NULL COMMENT '负责人ID',
  maintainer_name VARCHAR(128)  DEFAULT NULL COMMENT '负责人名称（冗余便于展示）',
  execution_mode  VARCHAR(16)   NOT NULL DEFAULT 'SERIAL'
                  COMMENT '执行模式: SERIAL | PARALLEL',
  parallel_limit  INT           NOT NULL DEFAULT 5
                  COMMENT '并行上限（PARALLEL 模式生效，默认 5）',
  create_user_id  BIGINT        DEFAULT NULL,
  modify_user_id  BIGINT        DEFAULT NULL,
  create_time     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                  ON UPDATE CURRENT_TIMESTAMP,
  deleted         TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '逻辑删除',
  PRIMARY KEY (id),
  KEY idx_library_deleted (case_library_id, deleted),
  KEY idx_enterprise_deleted (enterprise_id, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='接口测试计划';

-- 注：定时执行（cron）相关字段不放在本表，统一复用 tb_scenario_schedule_task（详见 §4.6 / §5.5）
```

### 5.2 `tb_api_test_plan_item` — 计划条目
存放"单接口 + 场景"混合列表。

```sql
CREATE TABLE tb_api_test_plan_item (
  id             BIGINT        NOT NULL COMMENT '主键',
  plan_id        BIGINT        NOT NULL COMMENT '所属计划ID',
  item_type      VARCHAR(16)   NOT NULL COMMENT '类型: API_CASE | SCENARIO',
  ref_id         BIGINT        NOT NULL COMMENT '引用的 api_case.id 或 test_scenario.id',
  ref_name       VARCHAR(255)  DEFAULT NULL COMMENT '冗余名称（导入时快照，避免源删除后显示异常）',
  step_count     INT           NOT NULL DEFAULT 1
                 COMMENT '场景步数快照（API_CASE 恒为 1；SCENARIO 为接口数，用于动态计算超时 = step_count × 90s）',
  environment_id BIGINT        DEFAULT NULL
                 COMMENT '覆盖环境ID（NULL 表示沿用源对象默认环境）',
  sort_order     INT           NOT NULL DEFAULT 0 COMMENT '顺序（串行模式按此执行）',
  create_time    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  update_time    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP
                 ON UPDATE CURRENT_TIMESTAMP,
  deleted        TINYINT(1)    NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_plan_sort (plan_id, sort_order),
  KEY idx_plan_type_ref (plan_id, item_type, ref_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='接口测试计划条目（单接口+场景）';
```

设计权衡：
- **单表混合** vs 双表（api_case_item + scenario_item）：单表因为字段高度同构（类型判别 + 引用 id），查询 + 排序 + 批量设置环境都更简单，代价是 `ref_id` 不能加 FK 约束，但业务层面可以接受。
- 去重约束：同一个计划里不限制同一 ref 重复加入（用户可能故意跑同一个 case 两次不同环境），不建唯一索引。

### 5.3 `tb_api_test_plan_execution` — 执行主表
```sql
CREATE TABLE tb_api_test_plan_execution (
  id              BIGINT        NOT NULL COMMENT '主键 = 前端的 executionId',
  plan_id         BIGINT        NOT NULL,
  plan_name       VARCHAR(128)  NOT NULL COMMENT '快照',
  execution_mode  VARCHAR(16)   NOT NULL COMMENT '快照：SERIAL/PARALLEL',
  trigger_type    VARCHAR(16)   NOT NULL DEFAULT 'MANUAL'
                  COMMENT 'MANUAL | SCHEDULED | API',
  executor_id     VARCHAR(64)   DEFAULT NULL,
  executor_name   VARCHAR(128)  DEFAULT NULL,
  status          VARCHAR(16)   NOT NULL DEFAULT 'pending'
                  COMMENT 'pending | running | passed | failed | cancelled',
  total_items     INT           NOT NULL DEFAULT 0,
  passed_items    INT           NOT NULL DEFAULT 0,
  failed_items    INT           NOT NULL DEFAULT 0,
  cancelled_items INT           NOT NULL DEFAULT 0,
  started_at      DATETIME      DEFAULT NULL,
  finished_at     DATETIME      DEFAULT NULL,
  duration_ms     BIGINT        DEFAULT NULL,
  console_output  MEDIUMTEXT    DEFAULT NULL COMMENT '精简日志快照（可选）',
  create_time     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_plan_started (plan_id, started_at),
  KEY idx_status (status) COMMENT '查询 running/pending 用于恢复'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='接口测试计划执行记录';
```

### 5.4 `tb_api_test_plan_execution_item` — 执行条目结果
为后续测试报告模块预留；本期实际写入，但前端可先不展示。

```sql
CREATE TABLE tb_api_test_plan_execution_item (
  id                BIGINT        NOT NULL,
  execution_id      BIGINT        NOT NULL COMMENT '关联 execution.id',
  plan_item_id      BIGINT        NOT NULL COMMENT '关联 plan_item.id（快照时刻）',
  item_type         VARCHAR(16)   NOT NULL,
  ref_id            BIGINT        NOT NULL,
  ref_name          VARCHAR(255)  DEFAULT NULL,
  environment_id    BIGINT        DEFAULT NULL COMMENT '实际使用的环境',
  environment_name  VARCHAR(128)  DEFAULT NULL,
  sort_order        INT           NOT NULL DEFAULT 0,
  status            VARCHAR(16)   NOT NULL DEFAULT 'pending'
                    COMMENT 'pending | running | passed | failed | cancelled | skipped',
  duration_ms       BIGINT        DEFAULT NULL,
  status_code       INT           DEFAULT NULL COMMENT '若为 API_CASE',
  assertion_result  TINYINT(1)    DEFAULT NULL,
  error_message     VARCHAR(1000) DEFAULT NULL,
  sub_execution_id  VARCHAR(64)   DEFAULT NULL
                    COMMENT '若为 SCENARIO，指向底层 scenario execution 的 id，便于查详情',
  started_at        DATETIME      DEFAULT NULL,
  finished_at       DATETIME      DEFAULT NULL,
  PRIMARY KEY (id),
  KEY idx_execution_sort (execution_id, sort_order)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='接口测试计划执行条目结果';
```

### 5.5 `tb_scenario_schedule_task` — 复用扩展（**不新建表**）
为承载测试计划的定时任务，对**现有**的 `tb_scenario_schedule_task`（位于 `test-mng-api-test-execution`）做最小扩展。完整迁移文件：`test-mng-api-test/src/main/resources/db/migration/V20260427__schedule_task_unification.sql`

```sql
-- 1. 加 task_type 列 + 索引
ALTER TABLE tb_scenario_schedule_task
  ADD COLUMN task_type VARCHAR(16) NOT NULL DEFAULT 'SCENARIO'
       COMMENT '任务类型: SCENARIO=场景定时, TEST_PLAN=测试计划定时' AFTER id,
  ADD INDEX idx_task_type_space (task_type, space_id);

-- 2. environment_id 从 NOT NULL 改为 NULL-able（TEST_PLAN 类型时为 NULL）
ALTER TABLE tb_scenario_schedule_task
  MODIFY COLUMN environment_id BIGINT DEFAULT NULL
       COMMENT '关联环境ID（TEST_PLAN 类型时为 NULL）';

-- 3. 把 tb_api_test_plan 已有的 cron 配置迁移到 schedule_task（task_type='TEST_PLAN'）
INSERT INTO tb_scenario_schedule_task (id, task_type, space_id, task_name, scenario_id,
       environment_id, cron_expression, task_status, ...)
SELECT id, 'TEST_PLAN', space_id, CONCAT(plan_name, ' - 定时任务'), id,
       NULL, cron_expression, 1, ...
FROM tb_api_test_plan WHERE cron_enabled = 1 AND deleted = 0;

-- 4. 删除 tb_api_test_plan 的 cron_enabled / cron_expression 字段及索引
ALTER TABLE tb_api_test_plan
  DROP INDEX idx_cron_enabled,
  DROP COLUMN cron_expression,
  DROP COLUMN cron_enabled;
```

**字段语义复用对照表**：

| 字段 | `task_type=SCENARIO` | `task_type=TEST_PLAN` |
|---|---|---|
| `scenario_id` | 场景 id | **计划 id**（字段名误导但不改名，避免大面积影响；DAO 层用 getter 包装语义） |
| `scenario_name` | 场景名 | 计划名（快照） |
| `task_name` | 任务名 | 任务名 |
| `environment_id` | 环境 id | **NULL**（环境在 plan 的 item 级覆盖，plan 级无统一环境） |
| `cron_expression` | 通用 | 通用 |
| `task_status` | 1/0 | 1/0 |
| `last_execute_time` / `next_execute_time` / `last_execute_status` / `last_execution_id` | 通用 | 通用 |
| `space_id` / `enterprise_id` / `create_user_*` / `*_time` / `deleted` | 通用 | 通用 |

**好处**：
- 无需新建表；无需给 `tb_api_test_plan` 加任何 cron 字段
- 调度器（`ScenarioScheduleScheduler` / `ScheduleTaskExecutor`）+ Redisson 分布式锁逻辑全部复用，只在 `doExecute` 加 `switch(task_type)` 分支
- 表结构上一对多（一个 plan 可挂多条定时），但**前端 UI 1:1**（计划详情面板对齐 UiTestPlan，详见 §3.6.3）

**为什么不改字段名**：`tb_scenario_schedule_task` 现已被场景定时任务大量代码使用，改名涉及 entity / mapper / DTO / VO / controller / 前端 API + interface 一连串重命名。出于改动半径考虑，仅加一列、不改名；新代码（`ApiTestPlanScheduleTaskController`）通过包装层把 `scenarioId` 字段语义还原为 `planId`，对前端隐藏底层共表事实。

### 5.6 索引策略
- 列表查询最常见：按 `(case_library_id, deleted)` + keyword LIKE → 前两个覆盖到，keyword 全表扫也能接受（每个 library 计划数量不会太大）
- 条目按 plan 查询 + 排序：`(plan_id, sort_order)`
- 启动恢复扫描：`(status = 'running')` 的执行记录 → `idx_status`
- 定时任务启动加载：`task_status=1 AND deleted=0` → 复用 `tb_scenario_schedule_task` 已有索引；按类型筛查走 `idx_task_type_space`

### 5.7 外键与软删策略
- **不建物理外键**（符合项目现有约定，避免分库分表阻塞）
- 所有表都带 `deleted TINYINT`（`@TableLogic`），`create_time / update_time` 自动填充
- `plan` 删除时级联软删其 `item`（业务层做，一个事务内两次 update）
- `execution` 不随 plan 删除而删（保留历史）

---

## 6. 与 UI 测试计划的差异汇总

| 维度 | UI 测试计划 | 接口测试计划 |
|---|---|---|
| 导入对象 | UI 用例（单一类型） | 单接口 + 场景（混合，`item_type` 区分） |
| 执行模式 | 串行（midscene YAML） | **串行 / 并行**（用户可选） |
| 并发控制 | 无 | 并行最多 5 |
| 排序 | `sortOrder` 字段（未充分利用） | **拖拽排序**，串行时实际生效 |
| 环境覆盖 | 每条目 `environment_id` | 每条目 `environment_id` + **批量设置** |
| YAML 预览 | 有 | 无 |
| 执行引擎 | Python midscene 子进程 + YAML | 复用 Java 原生 `ApiCaseExecutionService` / `ScenarioExecutionService` |
| WebSocket | `/ui-test/api/v1/ws/logs/{id}` | `/api-test-execution/v1/ws/logs/{id}`（协议相同，多 `item_*` 事件） |
| 报告 | 执行历史列表 | 同左 + 本期预留 `execution_item` 表供后续报告使用 |
| 定时调度（存储） | cron 内嵌 plan 表 + 独立调度器 | **复用** `tb_scenario_schedule_task` 表（加 `task_type` 字段）；与场景定时共用调度器/Redis 锁/列表入口 |
| 定时调度（UI） | 内联 cron section（switch + 输入 + AI 生成 + 示例 + 预览 + 下 5 次） | **完全对齐**：内联 cron section 复用同款 UX；底层切换为 schedule_task 接口（1:1 模型） |

---

## 7. 实施计划（建议分 6 个 PR）

### PR-1：数据库 + 后端骨架
- Flyway 迁移：本文档 §5.1–§5.4 共 4 张新表
- `tb_scenario_schedule_task` 扩列：加 `task_type` + `idx_task_type_space`（§5.5）
- Entity / Mapper / Converter 脚手架
- Controller 空实现 + Knife4j 接口描述

### PR-2：CRUD + 导入/排序/环境
- 计划 CRUD、条目导入、批量操作
- Feign 获取 ApiCase / Scenario 名称与默认环境

### PR-3：执行引擎 + WebSocket
- `PlanRunner`（串行 + 并行 + 取消）
- WebSocket handler + heartbeat
- 与已有 `ApiCaseExecutionService`、`ScenarioExecutionService` 的对接
- 服务启动时扫 `status=running` 的 execution → 置 `cancelled`（防服务器 crash 留下僵尸记录）

### PR-4：定时任务（共用表）
- `ApiTestPlanScheduleTaskController` + create/update/list/detail（写入 `tb_scenario_schedule_task` 时 `task_type='TEST_PLAN'`）
- `ScheduleTaskExecutor.doExecute` 加 `task_type` 分支：`TEST_PLAN` 调 `PlanRunner.run(...)`
- 现有 `/scenario-schedule-task/list` 接口加可选 `taskType` 入参 + VO 增加 `taskType` 字段返回
- 验证 `ScenarioScheduleScheduler.init()` 启动加载兼容（不需要改，按 `task_status=1 AND deleted=0` 扫所有类型）

### PR-5：前端
- `ApiTestPlan.vue` + store + api module
- `SceneIndex.vue` 新增 tab
- `case/detail/index.vue` 顶部按钮条件渲染
- 拖拽排序、批量设置环境 UI
- **内联 cron section（§3.6.3）**：`ApiTestPlan.vue` 计划详情面板的"定时执行" section 与 UiTestPlan 完全 1:1 一致；底层接 `apiTestPlanScheduleTask` API
- **「定时任务」tab 改造（§3.6）**：`SceneScheduleTask.vue` 加类型列、操作列分支；新增 `ApiTestPlanScheduleTaskDialog.vue`（仅供「定时任务」tab 行编辑）；`ScheduleTaskDialog.vue` list 调用加 `taskType: "SCENARIO"` 过滤

> **前端实现提示**：直接复制 `UiTestPlan.vue` 改名，大量代码（CommonPlanList、右键菜单、WebSocket、状态持久化、**整段 cron section 模板/CSS**）可以 1:1 保留，主要工作集中在：
> 1. 删掉 YAML 预览相关代码
> 2. cron 后端调用从 `updateUiTestPlanApi(cronEnabled/cronExpression)` 改为 `apiTestPlanScheduleTask` 接口（详见 §3.6.3 实现要点）
> 3. 增加"执行模式"section
> 4. 条目列表改为两类来源 + 拖拽 + 批量设置环境

### PR-6：测试报告集成（详见 §10）
- `tb_test_report` 扩列：`trigger_type` / `test_plan_id` / `test_plan_name` / `test_plan_execution_id`
- `tb_api_test_plan_execution` 加 `test_report_id` 反向引用
- `TestReportController` 新增 `/create/plan` 内部接口
- `PlanRunner` 收尾时调用，把 plan 执行落成一条 `reportType=TEST_PLAN` 的报告
- 前端 `SceneReport.vue` 新增 `triggerType` / `reportType` 筛选 + "所属计划"列
- `TestReportDetailDialog.vue` 拆分 3 个子组件，新增 `TEST_PLAN` 渲染分支 + 条目下钻
- URL 参数 `?testPlanId=xxx` 支持从计划页跳转报告页自动过滤

---

## 8. 风险与后续

### 8.1 风险点
| 风险 | 影响 | 缓解 |
|---|---|---|
| 场景执行是异步的，轮询等待可能拖慢 plan 整体时长 | 执行慢 | 设置轮询间隔 2s + 单场景超时 = 步数 × 90s（动态）；超时直接标 failed |
| 全局 Semaphore(5) 在多租户下可能被大 plan 独占 | 公平性 | 后期可切成 per-enterprise 信号量，或引入优先级队列 |
| 拖拽排序在并行模式下对用户有误导 | UX | UI 上禁用拖拽把手 + tooltip 提示 |
| 源 ApiCase/Scenario 被删除后，plan_item 成为孤儿 | 执行失败 | 执行前检查源是否存在，不存在则该 item 置 `skipped` 并提示 |
| WebSocket 在网关穿透需要额外配置 | 无法连接 | Gateway 的 `/api-test-execution/v1/ws/**` 显式配置 WebSocket 升级 |

### 8.2 后续扩展（本文档不覆盖）
- 测试报告模块（聚合 `tb_api_test_plan_execution_item`，展示接口详情、断言、变量提取、响应体差异）
- 失败重试（item 级别 `retry_count`）
- 失败快速停止（`fail_fast` 开关）
- 通知（飞书 / 企业微信执行结果推送）
- 与 CI/CD 集成（HTTP 触发 + 查询结果 API）

---

## 9. 附录

### 9.1 命名空间速查
- 前端：`ApiTestPlan.*`（类型）、`@/api/modules/apiTestPlan`、`@/stores/modules/apiTestPlanExecution`
- 后端 package：
  - `cloud.aisky.apitest.plan.*`（CRUD 在 `test-mng-api-test`）
  - `cloud.aisky.apitestexec.plan.*`（执行在 `test-mng-api-test-execution`）
- 数据库表：`tb_api_test_plan`、`tb_api_test_plan_item`、`tb_api_test_plan_execution`、`tb_api_test_plan_execution_item`
- 前端路由前缀：`/api-test/v1/test-plans/*`、`/api-test-execution/v1/test-plans/*`、`/api-test-execution/v1/ws/logs/{id}`

### 9.2 关键参考文件
- `test-mng-web/src/views/case/detail/components/UiTestPlan.vue` — 主参考
- `test-mng-web/src/views/case/detail/components/scene/SceneIndex.vue` — tab 宿主
- `test-mng-web/src/views/case/detail/index.vue` — 页面头部按钮宿主
- `test-mng-service/test-mng-api-test-execution/src/main/java/cloud/aisky/controller/ApiCaseExecutionController.java` — 单接口执行复用
- `test-mng-service/test-mng-api-test-execution/src/main/java/cloud/aisky/controller/ScenarioExecutionController.java` — 场景执行复用
- `test-mng-service/test-mng-api-test-execution/src/main/java/cloud/aisky/config/ScheduleExecutorConfig.java` — 定时线程池复用

---

## 10. 测试报告集成

> 决定：**复用现有 `tb_test_report` 表与 `SceneReport.vue` 列表页**，不新建独立的测试计划报告表/页面。在 `reportType` 上加一个新枚举值 `TEST_PLAN`，并在表上补两列以追溯计划来源。

### 10.1 现状摸底
- 报告统一表：`tb_test_report`（在 `test-mng-api-test-execution`），通过 `reportType: SCENARIO | CASE` 区分
- 列表页：`test-mng-web/src/views/case/detail/components/scene/SceneReport.vue`
- 详情对话框：`test-mng-web/src/views/case/detail/components/scene/TestReportDetailDialog.vue`
- 后端控制器：`TestReportController`，已有：
  - `POST /test-report/create/scenario`
  - `POST /test-report/create/case`
  - `POST /test-report/list`（已支持 `reportType` 过滤）
  - `POST /test-report/detail`
  - `POST /test-report/delete`
  - `POST /test-report/export/pdf`
- **缺**：`triggerType` 字段（前端 `SceneReport.vue` 第 263 行硬编码 `triggerType: "MANUAL"`），缺与测试计划的关联

### 10.2 数据库扩展（仅扩列，不新建表）

#### 10.2.1 `tb_test_report` 增加列
```sql
ALTER TABLE tb_test_report
  ADD COLUMN trigger_type VARCHAR(32)  NOT NULL DEFAULT 'MANUAL'
             COMMENT '触发类型: MANUAL | SCHEDULED | TEST_PLAN' AFTER report_type,
  ADD COLUMN test_plan_id BIGINT       DEFAULT NULL
             COMMENT '所属测试计划ID（仅 reportType=TEST_PLAN 时填）' AFTER trigger_type,
  ADD COLUMN test_plan_name VARCHAR(128) DEFAULT NULL
             COMMENT '计划名快照（避免计划被删后展示异常）' AFTER test_plan_id,
  ADD COLUMN test_plan_execution_id BIGINT DEFAULT NULL
             COMMENT '关联 tb_api_test_plan_execution.id' AFTER test_plan_name,
  ADD KEY idx_trigger_type (trigger_type),
  ADD KEY idx_test_plan_id (test_plan_id);
```

`reportType` 新增枚举值 `TEST_PLAN`（无需 schema 改动，是 VARCHAR）。

#### 10.2.2 `tb_api_test_plan_execution` 增加列
为了报告页"查看详情"能反向跳到完整执行记录，加一个反向引用：
```sql
ALTER TABLE tb_api_test_plan_execution
  ADD COLUMN test_report_id BIGINT DEFAULT NULL
             COMMENT '关联 tb_test_report.id（执行结束后回填）' AFTER console_output;
```

#### 10.2.3 `tb_test_report.detail` JSON 结构（TEST_PLAN 类型）
现有 `detail MEDIUMTEXT` 字段对 SCENARIO 存场景步骤、对 CASE 存请求响应。对 TEST_PLAN 我们存计划级别的汇总 + 条目清单：
```json
{
  "executionMode": "SERIAL",
  "parallelLimit": 5,
  "items": [
    {
      "planItemId": 1001,
      "itemType": "API_CASE",
      "refId": 2001,
      "refName": "登录接口",
      "environmentId": 11,
      "environmentName": "dev",
      "status": "passed",
      "durationMs": 135,
      "subExecutionId": 30001,
      "subReportType": "CASE"
    },
    {
      "planItemId": 1002,
      "itemType": "SCENARIO",
      "refId": 5001,
      "refName": "下单全链路",
      "environmentId": 12,
      "environmentName": "staging",
      "status": "failed",
      "durationMs": 4800,
      "subExecutionId": 40001,
      "subReportType": "SCENARIO",
      "errorMessage": "step3 断言失败：status_code expected 200 got 500"
    }
  ]
}
```

`subExecutionId` 指向底层的 `tb_api_case_execution.id` 或 `tb_scenario_execution.id`，详情页据此下钻。

### 10.3 写入时机

#### 10.3.1 PlanRunner 收尾流程
在 `PlanRunner` 的 finally 块（status 变成 `passed`/`failed`/`cancelled` 之后），统一调用：
```java
TestReportCreateFromPlanDTO dto = new TestReportCreateFromPlanDTO();
dto.setTestPlanId(plan.getId());
dto.setTestPlanName(plan.getPlanName());
dto.setTestPlanExecutionId(execution.getId());
dto.setTriggerType(execution.getTriggerType());  // MANUAL / SCHEDULED
dto.setSpaceId(plan.getCaseLibraryId());
dto.setItems(buildItemsSummary(executionId));    // 从 tb_api_test_plan_execution_item 聚合
Long reportId = testReportService.createFromPlan(dto);
planExecutionService.updateReportId(execution.getId(), reportId);
```

#### 10.3.2 新增后端接口
在 `TestReportController` 加：
```java
@PostMapping("/create/plan")
public JsonDataVO<String> createFromPlan(@Valid @RequestBody TestReportCreateFromPlanDTO dto)
```

由 `PlanRunner` 在执行完成时**内部调用**（不暴露给前端）。

### 10.4 前端改动

#### 10.4.1 `SceneReport.vue` — 列表页筛选扩展
**新增筛选项**（放在现有"状态"右侧）：
```vue
<el-select v-model="filters.triggerType" placeholder="触发类型" clearable @change="reload">
  <el-option label="全部" value="" />
  <el-option label="手动" value="MANUAL" />
  <el-option label="定时" value="SCHEDULED" />
  <el-option label="测试计划" value="TEST_PLAN" />
</el-select>

<el-select v-model="filters.reportType" placeholder="报告类型" clearable @change="reload">
  <el-option label="全部" value="" />
  <el-option label="单接口" value="CASE" />
  <el-option label="场景" value="SCENARIO" />
  <el-option label="测试计划" value="TEST_PLAN" />
</el-select>
```

> 用户的核心诉求"单独过滤查看测试计划报告" → 在 `reportType` 下拉里选「测试计划」即可（最简）。`triggerType` 是更细粒度的次级筛选，可一并加上。

**列表新增列**：
| 列 | 显示 | 备注 |
|---|---|---|
| 触发类型 | `<el-tag>` 手动/定时/测试计划 | 现有列后追加 |
| 所属计划 | `triggerType=TEST_PLAN` 时显示计划名 + 链接 | 点击跳转到对应测试计划页面 |

**`getTestReportListPageApi` 调用**：在请求参数里把 `reportType` 改为可选（之前硬编码 `"SCENARIO"`），并新增 `triggerType` 字段。后端 `TestReportListDTO` 同步加 `triggerType`。

#### 10.4.2 `TestReportDetailDialog.vue` — 详情对话框扩展
新增 `TEST_PLAN` 类型的渲染分支：

```
┌─ 测试计划报告：xxxxx ─────────────────────────────┐
│ 执行模式：串行    总条目：10    通过：9    失败：1│
│ 通过率：90% [█████████░]                          │
│ 触发：手动 by 张三   开始：2026-04-25 10:00:01    │
│ 耗时：12.3s         结束：2026-04-25 10:00:13    │
├───────────────────────────────────────────────────┤
│ 条目执行明细                                      │
│ ┌──┬─────────┬────┬──────┬──────┬──────┬────────┐│
│ │序│名称     │类型│环境  │状态  │耗时  │操作    ││
│ ├──┼─────────┼────┼──────┼──────┼──────┼────────┤│
│ │1 │登录接口 │接口│dev   │✅通过│135ms │查看详情││
│ │2 │下单链路 │场景│staging│❌失败│4.8s │查看详情││
│ │…                                                ││
│ └─────────────────────────────────────────────────┘│
└───────────────────────────────────────────────────┘
```

「查看详情」点击行为：
- `subReportType=CASE` → 在新对话框中打开 `tb_api_case_execution` 的详情（请求/响应/断言）
- `subReportType=SCENARIO` → 打开既有的场景详情视图（步骤列表）

实现上，详情对话框可拆 3 个子组件：
- `TestReportDetailPlan.vue`（新）— 计划汇总 + 条目表
- `TestReportDetailScenario.vue`（既有逻辑提取）
- `TestReportDetailCase.vue`（既有逻辑提取）

主对话框根据 `report.reportType` 切换渲染哪个子组件。

#### 10.4.3 类型扩展
`src/api/interface/scene.ts` 修改：
```ts
export interface TestReportListVO {
  // ...现有字段
  reportType: "SCENARIO" | "CASE" | "TEST_PLAN";   // 新增 TEST_PLAN
  triggerType: "MANUAL" | "SCHEDULED" | "TEST_PLAN"; // 新增字段
  testPlanId?: string | null;
  testPlanName?: string | null;
  testPlanExecutionId?: string | null;
}

export interface TestReportListDTO {
  // ...现有字段
  reportType?: "SCENARIO" | "CASE" | "TEST_PLAN";
  triggerType?: "MANUAL" | "SCHEDULED" | "TEST_PLAN";
}
```

### 10.5 入口与跳转
1. **测试计划页面 → 报告**
   - 在 `ApiTestPlan.vue` 的"基本信息"区域新增"最近报告"链接，跳转到报告页并自动按 `testPlanId` 筛选
   - 在执行完成后的 toast 中加"查看报告"按钮 → 同上
2. **报告页 → 测试计划**
   - 列表"所属计划"列点击跳转回测试计划页面定位到对应 plan
3. **跳转参数**：通过 URL query 传 `?testPlanId=xxx`，`SceneReport.vue` 在 `onMounted` 里读取并初始化 filter

### 10.6 执行历史（plan 维度）与测试报告的关系
两层结构，**不冗余**：
- `tb_api_test_plan_execution`：plan 维度的"执行流水"，关注调度/状态/取消/恢复（前端"执行状态"section 实时显示用）
- `tb_test_report`（reportType=TEST_PLAN）：plan 执行**完成后**的"快照报告"，关注汇总/审计/导出（报告页展示用）
- 两者通过 `tb_api_test_plan_execution.test_report_id` ↔ `tb_test_report.test_plan_execution_id` 双向引用

进行中（`status=running`）的执行只在前者，不会出现在报告页，避免脏数据。

### 10.7 其他注意事项
- **删除联动**：删除 plan → 不删除其报告（保留审计）；删除 report → 不影响 plan execution（仅清掉双向引用）
- **PDF 导出**：现有 `/test-report/export/pdf` 需对 `TEST_PLAN` 类型新增模板（计划级汇总 + 条目表）
- **统计接口**：`getTestReportStatisticsApi` 当前按 spaceId 全量统计，可加 `reportType` 维度细分（前端可视化用，本期可不做）
- **PR 拆分**：建议作为 **PR-6** 单独提交（在前端 PR-5 之后），与 plan 主流程解耦，便于灰度

### 10.8 与原文档 §8.2 的关系
原文档 §8.2 提到"测试报告模块（聚合 `tb_api_test_plan_execution_item`，展示接口详情、断言、变量提取、响应体差异）"作为后续扩展，本节将其落地，并明确：
- 不再独立做"plan 报告"页面，而是融入现有报告页
- 数据来源不直接读 `tb_api_test_plan_execution_item`，而是通过 `subExecutionId` 链回 `tb_api_case_execution` / `tb_scenario_step_execution`，避免数据冗余

### 10.9 设计权衡总结

| 选择 | 候选方案 | 决策 | 理由 |
|---|---|---|---|
| 报告存储 | A. 复用 `tb_test_report`<br>B. 新建 `tb_api_test_plan_report` | **A** | 列表 / 筛选 / 删除 / 导出 / 统计逻辑全套继承；仅 `detail` JSON 结构差异化即可；维护成本最低 |
| 子报告数据 | A. 通过 `subExecutionId` 引用底层执行表<br>B. 在 plan 报告里复制响应体/断言数据 | **A** | 避免 GB 级响应体重复存储；底层执行表已包含完整请求/响应/断言/变量；详情页按需加载更省内存 |
| 触发来源筛选 | A. 仅扩 `reportType` 加 `TEST_PLAN`<br>B. 仅加 `triggerType` 字段<br>C. **两个都加** | **C** | `reportType=TEST_PLAN` 直接满足用户"单独过滤测试计划报告"主诉求；`triggerType` 提供正交的"手动/定时/计划"维度筛选，未来扩展定时单接口/场景报告也用得上 |
| 计划页面 ↔ 报告页面跳转 | A. 通过 store 临时传参<br>B. URL query 参数 `?testPlanId=xxx` | **B** | 可分享链接、可刷新、可后退；与现有路由习惯一致 |
| 执行流水 vs 报告快照 | A. 合并到一张表<br>B. 两张表双向引用 | **B** | 进行中的执行只属于流水（`tb_api_test_plan_execution`），完成后的快照在报告（`tb_test_report`），互不污染；报告页不会出现 running 脏数据 |
| 详情对话框 | A. 在原对话框里加大量 v-if 分支<br>B. 拆分 3 个子组件 | **B** | 已有的 SCENARIO/CASE 渲染逻辑独立沉淀，TEST_PLAN 新增子组件不污染原代码；后续若加 UI_PLAN 报告也可继续平铺 |
| 删除联动 | A. 级联删除<br>B. 保留双向引用，不级联 | **B** | 报告作为审计快照应独立留存；删除 plan 不影响历史报告；删除报告也不影响 plan 自身的执行流水 |
