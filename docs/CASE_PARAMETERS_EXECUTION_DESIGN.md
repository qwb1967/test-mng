# 用例参数 - 第二阶段：执行集成与参数组循环

> 本文档承接 [`CASE_PARAMETERS_CSV_IMPORT_DESIGN.md`](./CASE_PARAMETERS_CSV_IMPORT_DESIGN.md)，描述如何把"参数集"接入用例执行：步骤里如何引用、如何循环所有参数组、如何展示循环报告。
>
> 第一阶段（导入 + 建模）已落地，本阶段不改 `tb_parameter_set` 数据结构。

---

## 0. 总体策略

| 关注点 | 决策 |
|---|---|
| 引用语法 | `${列名}` 平铺；同一用例下跨参数集列名禁止重名（创建/编辑时校验拦截） |
| 单组调试 | 用例调试默认用第 1 组；用户可在调试下拉里选第 N 组 |
| 多组循环 | 用例级隐式循环，N = max(各参数集行数)；多参数集"按行对齐 + 短的截断 + 警告" |
| Foreach 步骤集成 | 第三阶段再做（`foreach.collection` 字段下拉化），本阶段不动现有 foreach 逻辑 |
| 报告 | 复用 `tb_scenario_execution` + `tb_scenario_step_execution`，新增 `iteration_index` 等字段；前端报告页加"按参数组聚合"视图 |
| 老 CSV 单变量逻辑 | 删除 `ScenarioExecutionServiceImpl.loadCsvVariable` 及相关枚举、彻底切到参数集 |

**最大利好**：执行引擎里的迭代循环框架（`VariableContext.registerIterableVariable` + `iterationCount` + `for (int i=0; i<iterationCount; i++) { context.advanceIteration(i); ... }`）**已经存在**，本阶段是"接线"工作，不是"造轮子"。

---

## 1. 引用语法 + 冲突校验

### 1.1 语法

步骤里直接用 mustache 风格 `${列名}`，与现有变量引用规则完全一致：

```
URL:    https://example.com/api/login
Body:   { "username": "${username}", "password": "${password}" }
```

执行时由 `VariableContext` 解析。每个参数集的 N 列 → 注册成 N 个可迭代变量；每轮 `advanceIteration(i)` 同步推进所有列到第 i 行。

### 1.2 冲突规则

| 冲突类型 | 处理 | 校验位置 |
|---|---|---|
| 同一用例内，参数集 A 的列名 与 参数集 B 的列名重复 | **禁止**，创建/编辑参数集时报错 | 后端 `ParameterSetService.create / update` |
| 同一用例内，常量名 与 参数集列名重复 | **禁止**（双向） | 后端：参数集校验时查常量；常量保存时查参数集 |
| 用例参数集列名 与 环境变量 / 全局变量 同名 | 允许，**参数集优先**（更具体），UI 上加灰色提示 | 仅作运行时记录，不阻塞 |

### 1.3 校验实现要点（后端）

新增 `ParameterSetValidator` 工具类（service 内私有方法即可）：

```java
private void validateNoColumnNameConflict(Long scenarioId, List<String> headers, Long excludeId) {
    // 查同场景下其它启用参数集的所有 headers，做集合相交
    LambdaQueryWrapper<ParameterSet> w = new LambdaQueryWrapper<>();
    w.eq(ParameterSet::getScenarioId, scenarioId)
     .eq(ParameterSet::getStatus, true);
    if (excludeId != null) w.ne(ParameterSet::getId, excludeId);
    List<ParameterSet> others = parameterSetMapper.selectList(w);
    Set<String> conflicts = new HashSet<>();
    for (ParameterSet ps : others) {
        for (String h : JSON.parseArray(ps.getHeaders(), String.class)) {
            if (headers.contains(h)) conflicts.add(h);
        }
    }
    // 再查同场景下的常量变量名
    LambdaQueryWrapper<Variables> v = new LambdaQueryWrapper<>();
    v.eq(Variables::getVariableType, "SCENARIO")
     .eq(Variables::getEnvironmentId, scenarioId)  // 项目里 SCENARIO 复用 environmentId 字段
     .eq(Variables::getDeleted, false);
    for (Variables var : variablesMapper.selectList(v)) {
        if (headers.contains(var.getVariableName())) conflicts.add(var.getVariableName());
    }
    if (!conflicts.isEmpty()) {
        throw new BizException(BizCodeEnum.PARAMETER_SET_NAME_CONFLICT,
            "列名与已有变量重复: " + String.join(", ", conflicts));
    }
}
```

新增错误码：

```java
PARAMETER_SET_NAME_CONFLICT(925011, "参数集列名与已有变量重复"),
```

常量保存（`VariableServiceImpl.create / update`，scope=SCENARIO 时）也加反向校验：常量名不能与该场景下任一启用参数集的列名重复。

### 1.4 前端提示

- 参数集弹窗保存时，若后端报 `925011`，错误信息透传到 ElMessage（已有逻辑覆盖）
- `SceneParameters.vue` 的常量行 `el-input` 失焦时本地校验，对照已加载的参数集 headers 集合，重名则把输入框 set 红边 + 下方红字"与参数集 X 的列重复"，避免提交时才报错

---

## 2. 用例级隐式循环

### 2.1 触发条件

只要场景下有**启用**状态的参数集，且该参数集 `row_count > 0`，则用例执行（普通执行 / 调试 / 定时任务）按"循环模式"驱动。

### 2.2 执行模式（DTO 扩展）

`ScenarioExecutionCreateDTO` 新增字段：

```java
@Schema(description = "参数集运行模式：SINGLE_ROW=用单组（调试用） / LOOP_ALL=循环所有组 / NONE=未挂参数集时自动")
private String paramSetMode;     // 默认 LOOP_ALL；调试若用户选了"使用第 N 组"则前端传 SINGLE_ROW

@Schema(description = "SINGLE_ROW 模式下使用第几组，从 0 开始")
private Integer paramSetRowIndex;
```

枚举：

```java
public enum ParamSetRunModeEnum { SINGLE_ROW, LOOP_ALL, NONE }
```

### 2.3 加载逻辑：替换老 loadCsvVariable

`ScenarioExecutionServiceImpl` 当前 `loadCsvVariable` 把单个 CSV 当作一个变量的 flat list，不符合新模型。**整个方法删除**，新增：

```java
/**
 * 加载场景下所有启用参数集到 VariableContext。
 * 每个参数集的每一列都注册为一个可迭代变量。
 * iterationCount 自动取所有列表最大长度（registerIterableVariable 内部累计）。
 */
private void loadParameterSets(Long scenarioId, VariableContext context, ScenarioExecutionCreateDTO dto) {
    LambdaQueryWrapper<ParameterSet> w = new LambdaQueryWrapper<>();
    w.eq(ParameterSet::getScenarioId, scenarioId)
     .eq(ParameterSet::getStatus, true);
    List<ParameterSet> sets = parameterSetMapper.selectList(w);
    if (sets.isEmpty()) return;

    Map<Integer, Integer> rowCountByPs = new HashMap<>();
    int maxRowCount = 0;
    for (ParameterSet ps : sets) {
        if (ps.getRowCount() == null || ps.getRowCount() == 0) continue;
        // 加载所有行
        LambdaQueryWrapper<ParameterSetRow> rw = new LambdaQueryWrapper<>();
        rw.eq(ParameterSetRow::getParameterSetId, ps.getId())
          .orderByAsc(ParameterSetRow::getRowIndex);
        List<ParameterSetRow> rows = parameterSetRowMapper.selectList(rw);
        if (rows.isEmpty()) continue;

        List<String> headers = JSON.parseArray(ps.getHeaders(), String.class);
        // 每列收集 N 行数据 → 注册为可迭代变量
        for (int colIdx = 0; colIdx < headers.size(); colIdx++) {
            List<String> colValues = new ArrayList<>(rows.size());
            for (ParameterSetRow row : rows) {
                List<String> rowValues = JSON.parseArray(row.getValuesJson(), String.class);
                colValues.add(colIdx < rowValues.size() ? rowValues.get(colIdx) : "");
            }
            context.registerIterableVariable(headers.get(colIdx), colValues);
        }
        maxRowCount = Math.max(maxRowCount, rows.size());
    }

    // SINGLE_ROW 模式：把 iterationCount 钉成 1，预先 advance 到指定行
    if ("SINGLE_ROW".equals(dto.getParamSetMode())) {
        int rowIdx = Optional.ofNullable(dto.getParamSetRowIndex()).orElse(0);
        if (rowIdx < 0 || rowIdx >= maxRowCount) {
            throw new BizException(BizCodeEnum.PARAMETER_SET_ROW_INDEX_OUT_OF_RANGE);
        }
        context.advanceIteration(rowIdx);
        context.setIterationCount(1);  // 需要给 VariableContext 加 setter
    }
    // LOOP_ALL 模式：什么都不做，registerIterableVariable 自动累积 iterationCount
}
```

`VariableContext` 加一个 setter：

```java
public void setIterationCount(int iterationCount) {
    this.iterationCount = iterationCount;
}
```

新增错误码：

```java
PARAMETER_SET_ROW_INDEX_OUT_OF_RANGE(925012, "参数组序号超出范围"),
```

### 2.4 调用接入

`ScenarioExecutionServiceImpl` 创建执行时，原来调 `loadVariables(...)` 的地方在加载完场景变量、环境变量后追加：

```java
loadParameterSets(dto.getScenarioId(), context, dto);
```

老 `loadCsvVariable` 调用点全部删除（含 `case "CSV"` 分支、`ValueTypeEnum.CSV` 枚举值、相关测试）。

### 2.5 边界处理

| 情况 | 行为 |
|---|---|
| 场景无任何启用参数集 | `iterationCount=1`（默认）—— 用例只跑一次，引用 `${...}` 命中常量 |
| 参数集启用但 0 行 | 跳过该参数集（不注册迭代变量）；若是唯一参数集 → 跑一次（同上） |
| 多参数集行数不齐 | `iterationCount = max`，**短的参数集越界后留空字符串**；不在执行时报错。前端在用例参数 Tab 顶部显示警告 |
| `LOOP_ALL` 模式下行数过大（>500） | 警告但不阻塞；需要做异步执行的话沿用现有 `ScheduleTask` 路径 |
| `SINGLE_ROW` 模式 + rowIndex 越界 | 报错 `925012` |

> "短的参数集越界留空字符串"是 `advanceIteration` 已有行为（看代码注释"循环取值"，但实际是 `i % size`）。我们采纳"截断"语义而不是"循环复用"会更直觉，需在 `advanceIteration` 里改成 `i < size ? values.get(i) : ""`。**这是一个老逻辑微调，验收时确认。**

---

## 3. 调试入口：下拉选择运行模式

### 3.1 UI 改动（前端）

`SceneSteps.vue` / `SceneOps.vue` 顶部已有调试按钮（具体位置以代码为准）。把它改造为带下拉的复合按钮：

```vue
<el-dropdown split-button type="primary" @click="onDebugSingle(0)" @command="onDebugCommand">
  调试
  <template #dropdown>
    <el-dropdown-menu>
      <el-dropdown-item :command="{ mode: 'SINGLE_ROW', row: 0 }">
        使用第 1 组运行
      </el-dropdown-item>
      <el-dropdown-item :command="{ mode: 'SINGLE_ROW', row: 'pick' }">
        使用第 N 组运行…
      </el-dropdown-item>
      <el-dropdown-item :command="{ mode: 'LOOP_ALL' }" :disabled="totalRowCount === 0">
        循环执行所有组（共 {{ totalRowCount }} 组）
      </el-dropdown-item>
    </el-dropdown-menu>
  </template>
</el-dropdown>
```

- 用例无参数集时，下拉项灰显或隐藏（直接当普通调试按钮）
- 选"使用第 N 组运行…"弹一个轻量数字输入对话框
- 顶部直接点的默认 = 第 1 组（SINGLE_ROW + rowIndex=0）

调用 `executeSceneApi`（已存在）时多带两个字段 `paramSetMode / paramSetRowIndex`。

### 3.2 总组数获取

`SceneSteps.vue` 通过 `listParameterSetApi(scenarioId)` 拉一遍参数集（在 `SceneParameters.vue` 里已经做过），把 `max(rowCount)` 暴露给父级或独立调一次。简单起见每次打开下拉时 lazy fetch 一次，不缓存。

---

## 4. 执行报告：按参数组聚合

### 4.1 数据库改动

`tb_scenario_step_execution` 新增列：

```sql
ALTER TABLE tb_scenario_step_execution
    ADD COLUMN iteration_index INT NOT NULL DEFAULT 0 COMMENT '所属迭代轮次（0=第一轮；无参数集时恒为 0）',
    ADD KEY idx_execution_iteration (execution_id, iteration_index);
```

`tb_scenario_execution` 新增列（描述本次执行的参数集运行情况，便于报告页直接渲染不需要再 JOIN）：

```sql
ALTER TABLE tb_scenario_execution
    ADD COLUMN param_set_mode VARCHAR(16) DEFAULT NULL COMMENT 'SINGLE_ROW / LOOP_ALL / NONE',
    ADD COLUMN iteration_count INT NOT NULL DEFAULT 1 COMMENT '总迭代轮数',
    ADD COLUMN param_set_snapshot JSON DEFAULT NULL COMMENT '本次执行使用的参数集快照：[{name, headers, rows}]';
```

`param_set_snapshot` 是冗余但极有用 —— 一旦执行后用户改了参数集内容，报告还能精确回溯当时跑的是什么参数。

### 4.2 写入逻辑

`ScenarioExecutionServiceImpl`：

1. 创建 ScenarioExecution 时，根据加载结果填 `param_set_mode` / `iteration_count` / `param_set_snapshot`
2. `executeScenarioSteps` 入参增加 `int iterationIndex`，写入每个 `ScenarioStepExecution.iterationIndex`
3. 现有循环点：
   ```java
   for (int i = 0; i < iterationCount; i++) {
       context.advanceIteration(i);
       executeScenarioSteps(execution, steps, i);  // 加 i 参数
   }
   ```
4. 步骤级 `successCount` / `failCount` 累计逻辑不变（仍然是步骤维度），但报告页可以按 iterationIndex GROUP BY 重新切片

### 4.3 报告 VO 扩展

`Scene.ExecuteSceneResult`（前端类型）+ `ScenarioExecutionDetailVO`（后端 VO）增加：

```typescript
paramSetMode?: "SINGLE_ROW" | "LOOP_ALL" | "NONE";
iterationCount?: number;
paramSetSnapshot?: Array<{
  name: string;
  headers: string[];
  rows: string[][];
}>;
iterationSummary?: Array<{
  iterationIndex: number;
  paramRow: Record<string, string>;   // { username: "alice", password: "123" }
  successCount: number;
  failCount: number;
  status: "PASSED" | "FAILED" | "PARTIAL";
}>;
```

`iterationSummary` 由后端 detail 接口聚合 step_execution 后返回（一次查询 GROUP BY iteration_index）。

### 4.4 报告页 UI 调整

`SceneReport.vue` / `TestReportDetailDialog.vue`（已存在）顶部加一个折叠区：

```
本次执行配置
  模式：循环执行所有组（共 10 组）
  参数集：测试用户集（10 组 / 2 个参数）
  通过率：8/10 ✓
  ▼ 展开各组详情
```

展开后是一个表格：

| 第 N 组 | username | password | 通过 | 失败 | 状态 |
|---|---|---|---|---|---|
| 1 | alice | 123456 | 5 | 0 | ✓ |
| 2 | bob | abc | 4 | 1 | ✗ |
| ... | | | | | |

点击某一行展开 → 列表变成那一组的具体步骤执行详情（即现有报告页的步骤明细，按 `iteration_index` 过滤）。

实现路径：在 `TestReportDetailDialog.vue` 当前的"步骤列表"上方插入这个聚合表，原本的"显示所有步骤"加一个"按组过滤"开关。

---

## 5. 后端接口/字段改动总览

| 模块 | 改动 |
|---|---|
| `tb_scenario_execution` | 加 `param_set_mode` / `iteration_count` / `param_set_snapshot` |
| `tb_scenario_step_execution` | 加 `iteration_index` + 索引 |
| `ScenarioExecutionCreateDTO` | 加 `paramSetMode` / `paramSetRowIndex` |
| `ScenarioExecutionService` | 删 `loadCsvVariable`；新增 `loadParameterSets`；调用点串联 |
| `VariableContext` | 加 `setIterationCount(int)`；微调 `advanceIteration` 越界语义为"留空"而非"循环取" |
| `ParameterSetService` | `create`/`update` 加 `validateNoColumnNameConflict`（跨参数集 + 与常量） |
| `VariableService`（既有） | `create`/`update` 加反向校验：常量名不能与已存在参数集列名重复 |
| `BizCodeEnum` | 新增 `925011 PARAMETER_SET_NAME_CONFLICT` / `925012 PARAMETER_SET_ROW_INDEX_OUT_OF_RANGE` |
| 老 `valueType=CSV` 单变量代码 | 删除 `loadCsvVariable` / `case "CSV"` / `ValueTypeEnum.CSV` 等 |

---

## 6. 前端改动总览

| 文件 | 改动 |
|---|---|
| `api/interface/scene.ts` | `ScenarioExecutionCreateDTO` 等价类型加 `paramSetMode` / `paramSetRowIndex`；`ExecuteSceneResult` 加 `paramSetMode` / `iterationCount` / `paramSetSnapshot` / `iterationSummary` |
| `views/case/detail/components/scene/SceneSteps.vue`（或调试按钮所在文件） | 调试按钮改为 split-button 下拉，三个选项 |
| `views/case/detail/components/scene/SceneParameters.vue` | 常量行加列名冲突本地校验；多参数集行数不齐时顶部黄条警告 |
| `views/case/detail/components/scene/SceneReport.vue` 或 `TestReportDetailDialog.vue` | 顶部加"本次执行配置"折叠区 + 各组聚合表 + 步骤明细按组过滤 |

---

## 7. PR 拆分建议

| PR | 范围 | 风险 |
|---|---|---|
| **PR-7** | DDL（两表新增列）+ DTO/VO 字段扩展 + `BizCodeEnum` 错误码 | 低 |
| **PR-8** | 后端：`loadParameterSets` 实现 + 删 `loadCsvVariable` + 调用串联 + 单测 | 中 |
| **PR-9** | 后端：列名冲突校验（`ParameterSetService` + `VariableService` 双向） + 单测 | 低 |
| **PR-10** | 前端：调试按钮下拉 + 用例参数 Tab 冲突提示 + 顶部行数不齐警告 | 低 |
| **PR-11** | 前后端：报告页"按参数组聚合"视图（detail VO 聚合 + UI 表格） | 中 |
| **PR-12** | 老 `valueType=CSV` 残留代码清理（枚举、配置项、迁移脚本如果需要） | 低 |

每个 PR 都要：跑现有 `ScenarioExecutionServiceImplTest`（如有）+ 新增针对性单测。

---

## 8. 验收 Checklist（第二阶段整体）

- [ ] 用例挂启用状态参数集后，步骤里 `${列名}` 被正确替换
- [ ] 调试按钮直接点 = 第 1 组运行成功
- [ ] 调试下拉"使用第 N 组" + 数字弹窗 = 用第 N 组运行
- [ ] 调试下拉"循环执行所有组" = 跑 N 轮，每轮 step_execution 写入对应 iteration_index
- [ ] 报告页顶部展示"模式 / 总组数 / 通过率 / 各组明细"
- [ ] 各组明细表格点开任一组 → 显示该组的所有步骤
- [ ] 跨参数集列名重复 → 创建/编辑参数集时被拒绝
- [ ] 常量名与参数集列名重复 → 双向都被拒绝
- [ ] 多参数集行数不齐 → 顶部黄条警告 + 短的参数集对应列从越界行开始为空
- [ ] 单组调试 rowIndex 越界 → 报错 `925012`
- [ ] 全场景下旧 `valueType=CSV` 代码已彻底删除（grep 不到 `loadCsvVariable` / `case "CSV"`）

---

## 9. 不在本阶段范围内

- **`foreach` 步骤的 `collection` 字段下拉化**（让用户在某几个步骤之间循环参数集）—— 第三阶段
- **多参数集笛卡尔积**（嵌套 foreach 实现，第三阶段）
- **参数集行级编辑**（在表格里改某行某列）—— 单独议题
- **执行结果导出 / 失败行重跑** —— 单独议题

---

**文档状态**：第二阶段设计草稿，待评审。评审通过后按 §7 拆 PR 落地。

**主要受影响文件**：
- 后端：`ScenarioExecutionServiceImpl` / `VariableContext` / `ParameterSetServiceImpl` / `VariableServiceImpl` / `ScenarioExecutionCreateDTO` / `BizCodeEnum` + 一份 ALTER SQL
- 前端：调试按钮所在视图 / `SceneParameters.vue` / 报告组件 / `scene.ts` 类型
