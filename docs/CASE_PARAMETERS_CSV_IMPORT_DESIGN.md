# 用例参数 - CSV 导入与参数组重构设计

> 本文档是 [`CASE_PARAMETERS_CSV_IMPORT_REQUIREMENTS.md`](./CASE_PARAMETERS_CSV_IMPORT_REQUIREMENTS.md) 的设计落地版。
>
> **重要**：第一版上线，旧的「`valueType=CSV` 单变量」实现全部丢弃，前后端都用全新文件，不写迁移、不写兼容分支。

---

## 0. 总体策略

| 层 | 处理 |
|----|------|
| 数据库 | 新建独立表 `tb_parameter_set` 与 `tb_parameter_set_row`，与 `tb_variables` 解耦。`tb_variables` 删除 CSV 相关代码路径 |
| 后端 | 新建 `ParameterSetController` / `ParameterSetService` / `CsvParseService`，与现有 `VariableController` 平级 |
| 前端 | 新建 `ParameterSetDialog.vue` 替换旧 `CsvVariableDialog.vue`；改 `SceneParameters.vue` 让"添加变量"下拉走新组件；新增 `parameter-set.ts` API 模块 |
| 旧代码 | `CsvVariableDialog.vue` 删除；`Scene.VariableItem` 上 `filePath / csvPreview / encoding / delimiter / allowQuotes` 字段删除；`SceneParameters.vue` 中 `isCsvVariable / openCsvVariableDetail / csvDialogVisible / csvEditVariable` 等旧逻辑删除 |

**两类数据的边界**：

- **常量（Variable）**：仍走 `tb_variables`，`variableType=SCENARIO`，单值键值对。后端表/接口不动。
- **参数集（ParameterSet）**：全新表 + 全新接口，CSV 导入产物，多列 × 多行结构化存储。

**前端展示**：参数 Tab 上方一个表格同时展示常量和参数集，但二者数据源是两份接口拉到的列表 → 在前端合并展示，不在后端搞 union。

---

## 1. 数据库设计

### 1.1 `tb_parameter_set` —— 参数集主表

```sql
CREATE TABLE tb_parameter_set (
  id              BIGINT       NOT NULL COMMENT '参数集ID',
  space_id        BIGINT       DEFAULT NULL COMMENT '所属space_id',
  scenario_id     BIGINT       NOT NULL COMMENT '所属场景ID（tb_test_scenario.id）',
  name            VARCHAR(128) NOT NULL COMMENT '参数集名称（用户填或文件名兜底）',
  description     VARCHAR(512) DEFAULT NULL COMMENT '参数集描述',
  headers         JSON         NOT NULL COMMENT '参数名列表，JSON 数组；["username","password"]',
  column_count    INT          NOT NULL COMMENT '列数（headers 长度）',
  row_count       INT          NOT NULL COMMENT '参数组行数',
  file_path       VARCHAR(512) DEFAULT NULL COMMENT '原 CSV 在 storage 的路径',
  source_filename VARCHAR(255) DEFAULT NULL COMMENT '上传时的原始文件名',
  status          TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '1=启用，0=禁用',

  create_user_id  BIGINT       DEFAULT NULL,
  modify_user_id  BIGINT       DEFAULT NULL,
  create_time     DATETIME     DEFAULT CURRENT_TIMESTAMP,
  update_time     DATETIME     DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  deleted         TINYINT(1)   NOT NULL DEFAULT 0,

  PRIMARY KEY (id),
  KEY idx_scenario (scenario_id, deleted)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='参数集主表';
```

### 1.2 `tb_parameter_set_row` —— 参数组行表

```sql
CREATE TABLE tb_parameter_set_row (
  id                BIGINT     NOT NULL COMMENT '行ID',
  parameter_set_id  BIGINT     NOT NULL COMMENT '所属参数集ID',
  row_index         INT        NOT NULL COMMENT '行序号，从 0 开始',
  values_json       JSON       NOT NULL COMMENT '一行的所有列值，JSON 数组；与 headers 顺序一致',
  create_time       DATETIME   DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (id),
  KEY idx_set_row (parameter_set_id, row_index)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='参数集行';
```

**为什么 row 单独一张表**：

- 后续执行循环时按 `parameter_set_id + row_index` 取行，避免每次反序列化主表 JSON。
- 行数可能从几行到上万行，单独表更利于分页和查询。
- 主表 `headers` 仍然冗余存一份，便于"只读列表展示"时不用 JOIN。

### 1.3 `tb_variables` 的处理

- 不动表结构，但代码层面：
  - `Variables.valueType` 不再写入 `CSV` 值。
  - 枚举 `VariableValueTypeEnum` 移除 `CSV`（如果有）。
- 后端启动初始化 SQL 不需要清理（用户确认无生产数据）。

### 1.4 SQL 文件

新增 `test-mng-service/sql/api-test/mysql/{yyyyMMdd}__parameter_set.sql`，包含上述两张表的 DDL。文件名遵循现有命名（参考 `20260408.sql` / `20260420.sql`）。

---

## 2. 后端设计（test-mng-api-test 模块）

### 2.1 包结构

全部新文件放在 `cloud.aisky` 现有分层下（与 `VariableController` 平级）：

```
cloud.aisky/
├── controller/
│   └── ParameterSetController.java        【新】
├── service/
│   ├── ParameterSetService.java           【新】
│   ├── CsvParseService.java               【新】
│   └── impl/
│       ├── ParameterSetServiceImpl.java   【新】
│       └── CsvParseServiceImpl.java       【新】
├── mapper/
│   ├── ParameterSetMapper.java            【新】
│   └── ParameterSetRowMapper.java         【新】
├── entity/
│   ├── ParameterSet.java                  【新】
│   └── ParameterSetRow.java               【新】
├── dto/
│   ├── ParameterSetCreateDTO.java         【新】
│   ├── ParameterSetUpdateDTO.java         【新】
│   ├── ParameterSetIdDTO.java             【新】
│   └── ParameterSetListDTO.java           【新】
├── vo/
│   ├── ParameterSetVO.java                【新】
│   ├── ParameterSetDetailVO.java          【新】
│   └── CsvParsePreviewVO.java             【新】
├── converter/
│   └── ParameterSetConverter.java         【新】
└── enums/
    └── ParameterSetStatusEnum.java        【新】（如需要）
```

### 2.2 接口清单

所有接口前缀 `/parameter-set`，在网关侧聚合到 `test-mng-api-test` 服务下。

| Method | Path | 用途 | 入参 | 出参 |
|--------|------|------|------|------|
| POST | `/parameter-set/parse-csv` | **解析 CSV**（不落库），返回预览数据 | multipart `file`（CSV）| `JsonDataVO<CsvParsePreviewVO>` |
| POST | `/parameter-set/create` | 用解析结果落库 | `ParameterSetCreateDTO` | `JsonDataVO<ParameterSetVO>` |
| POST | `/parameter-set/update` | 修改 name / description / status / 重新替换数据 | `ParameterSetUpdateDTO` | `JsonDataVO<ParameterSetVO>` |
| POST | `/parameter-set/delete` | 删除参数集（软删，同时软删行） | `ParameterSetIdDTO` | `JsonDataVO<Boolean>` |
| POST | `/parameter-set/detail` | 查询单个参数集（含所有行，用于预览/编辑） | `ParameterSetIdDTO` | `JsonDataVO<ParameterSetDetailVO>` |
| POST | `/parameter-set/list` | 按场景列出参数集（不含行数据） | `ParameterSetListDTO` | `JsonDataVO<List<ParameterSetVO>>` |
| GET  | `/parameter-set/template` | 下载模板 CSV（流式返回） | — | `text/csv` 文件流 |

> 命名遵循现有 `VariableController`：用 `JsonDataVO`、`@PostMapping`、`@Operation`、`@Tag`，便于和现有代码一致。

### 2.3 关键 DTO / VO

#### 2.3.1 `CsvParsePreviewVO`（解析预览返回）

```java
@Data
@Schema(description = "CSV 解析预览结果")
public class CsvParsePreviewVO {
    @Schema(description = "已上传 CSV 在 storage 的路径", example = "/storage/.../scene-csv/abc.csv")
    private String filePath;

    @Schema(description = "上传时原始文件名", example = "users.csv")
    private String sourceFilename;

    @Schema(description = "嗅探到的编码", example = "UTF-8")
    private String detectedEncoding;

    @Schema(description = "嗅探到的分隔符", example = ",")
    private String detectedDelimiter;

    @Schema(description = "参数名列表（CSV 表头）", example = "[\"username\",\"password\"]")
    private List<String> headers;

    @Schema(description = "参数组行数据，与 headers 顺序一致")
    private List<List<String>> rows;

    @Schema(description = "列数")
    private Integer columnCount;

    @Schema(description = "行数")
    private Integer rowCount;
}
```

> 注意 `filePath` —— 解析接口除了返回结构化数据，还把 CSV 落到 storage（复用 `test-mng-storage`），落地后的路径作为后续 `create` 时的标识。

#### 2.3.2 `ParameterSetCreateDTO`

```java
@Data
@Schema(description = "创建参数集请求")
public class ParameterSetCreateDTO {
    @NotNull(message = "scenarioId 不能为空")
    @Schema(description = "所属场景ID", requiredMode = REQUIRED, example = "1234567890")
    private Long scenarioId;

    @NotBlank(message = "参数集名称不能为空")
    @Size(max = 128)
    @Schema(description = "参数集名称", requiredMode = REQUIRED, example = "测试用户集")
    private String name;

    @Size(max = 512)
    @Schema(description = "描述", example = "用于登录用例的 10 个测试账号")
    private String description;

    @NotEmpty(message = "headers 不能为空")
    @Schema(description = "参数名列表（CSV 表头）", requiredMode = REQUIRED, example = "[\"username\",\"password\"]")
    private List<String> headers;

    @NotEmpty(message = "rows 不能为空")
    @Schema(description = "参数组行数据", requiredMode = REQUIRED)
    private List<List<String>> rows;

    @Schema(description = "已上传 CSV 路径（来自 parse-csv 接口）", example = "/storage/.../abc.csv")
    private String filePath;

    @Schema(description = "原始文件名", example = "users.csv")
    private String sourceFilename;
}
```

#### 2.3.3 `ParameterSetVO`（列表项）

```java
@Data
@Schema(description = "参数集列表项")
public class ParameterSetVO {
    private Long id;
    private Long scenarioId;
    private String name;
    private String description;
    private List<String> headers;
    private Integer columnCount;
    private Integer rowCount;
    private Boolean status;
    private String sourceFilename;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
```

#### 2.3.4 `ParameterSetDetailVO`（详情，含所有行）

```java
@Data
@Schema(description = "参数集详情")
public class ParameterSetDetailVO extends ParameterSetVO {
    @Schema(description = "所有参数组行")
    private List<List<String>> rows;
}
```

### 2.4 CSV 解析服务（核心难点）

`CsvParseService.parse(MultipartFile file)` 行为：

1. **读取字节**：先读全部 `byte[]`（限制单文件 ≤ 10 MB；超出抛 `BusinessException("CSV 文件过大，限制 10MB")`）。
2. **嗅探编码**：
   - 优先级：BOM 识别 → 用 `juniversalchardet` 或 `Apache Tika` 检测 → 默认 UTF-8。
   - 候选：`UTF-8`、`UTF-8 with BOM`、`GBK`、`GB18030`、`UTF-16LE`、`UTF-16BE`。
   - 添加依赖：`com.googlecode.juniversalchardet:juniversalchardet:2.4.0`（轻量、Apache 2.0）。
3. **嗅探分隔符**：
   - 候选：`,` `;` `\t`。
   - 取前 N 行（N=10），分别用三种分隔符切分，选"列数最稳定"的那一种（每行列数一致 → 优先；其次列数最多）。
4. **解析**：用 `org.apache.commons:commons-csv:1.10.0`（已成熟、RFC 4180 兼容）按嗅探出的编码 + 分隔符解析，引号默认开启（`"` 标准引号）。
5. **校验**：
   - 表头不能为空、不能有重复列名、不能有空白列名（trim 后）。
   - 数据行列数必须等于表头列数，否则抛 `BusinessException("第 N 行列数与表头不一致")`。
   - 行数限制 ≤ 10000，列数 ≤ 100。超出抛对应错误。
6. **落库 storage**：调 `test-mng-storage` 的上传接口（与现有 `uploadFiles` 一致），路径前缀 `/scene-csv/{scenarioId}/`，文件名加时间戳避免重名。返回 `filePath`。
7. **返回** `CsvParsePreviewVO`。

> **注意**：`parse-csv` 接口本身不写 `tb_parameter_set`。前端拿到预览后让用户确认 / 改名 / 加描述，再调 `create` 落库。这样上传错文件不会留垃圾数据。

### 2.5 业务逻辑细节

#### 2.5.1 创建（`create`）

```java
@Transactional(rollbackFor = Exception.class)
public ParameterSetVO create(ParameterSetCreateDTO dto, Long currentUserId) {
    // 1. 校验 headers 不重复、不为空
    validateHeaders(dto.getHeaders());

    // 2. 校验每行列数 == headers.size
    validateRowsShape(dto.getHeaders().size(), dto.getRows());

    // 3. 写入主表
    ParameterSet entity = converter.toEntity(dto);
    entity.setColumnCount(dto.getHeaders().size());
    entity.setRowCount(dto.getRows().size());
    entity.setStatus(true);
    parameterSetMapper.insert(entity);

    // 4. 批量写入行表
    List<ParameterSetRow> rows = IntStream.range(0, dto.getRows().size())
        .mapToObj(i -> {
            ParameterSetRow row = new ParameterSetRow();
            row.setParameterSetId(entity.getId());
            row.setRowIndex(i);
            row.setValuesJson(JsonUtils.toJson(dto.getRows().get(i)));
            return row;
        })
        .toList();
    parameterSetRowMapper.insertBatch(rows);  // 自定义 XML 批量插入

    return converter.toVO(entity);
}
```

#### 2.5.2 更新（`update`）

支持两种语义：

- **只改元信息**（name / description / status）：不动行表。
- **替换数据**（headers + rows 都传了）：删旧行 + 写新行；主表 `column_count / row_count / file_path / source_filename` 同步更新。

DTO 用一个 boolean `replaceData` 区分（默认 false）。

#### 2.5.3 删除（`delete`）

软删 `tb_parameter_set.deleted=1`；行表不软删（行表无 deleted 字段，靠主表筛即可）。删除时不去清理 storage 文件（storage 自有清理策略；CSV 原文留底也方便审计）。

### 2.6 异常 & 错误码

新增 `ErrorCode`（如项目有统一错误码枚举，否则用 `BusinessException(message)`）：

- `PARAM_SET_FILE_TOO_LARGE` — CSV 超过大小限制
- `PARAM_SET_HEADER_INVALID` — 表头有空值/重复
- `PARAM_SET_ROW_SHAPE_MISMATCH` — 行列数不一致
- `PARAM_SET_ENCODING_UNDETECTABLE` — 编码无法识别
- `PARAM_SET_NOT_FOUND` — 详情查不到

### 2.7 单元测试要点

放在 `test-mng-api-test/src/test/java/.../ParameterSetTest.java`：

- 编码嗅探：UTF-8 / UTF-8 BOM / GBK / GB18030 各一份样本 CSV，断言 detectedEncoding 正确。
- 分隔符嗅探：`,` `;` `\t` 各一份样本，断言 detectedDelimiter 正确。
- 表头校验：空表头、重复表头、空白表头各报对应错。
- 行列数不一致：故意写错的样本，报第 N 行错。
- 引号：含逗号字段加引号、引号转义（`""`）。

---

## 3. 前端设计（test-mng-web）

### 3.1 文件清单

| 操作 | 文件 |
|------|------|
| **新建** | `src/views/case/detail/components/scene/ParameterSetDialog.vue` |
| **新建** | `src/views/case/detail/components/scene/ParameterSetPreview.vue`（表格预览，可独立复用） |
| **新建** | `src/api/modules/parameter-set.ts` |
| **新建** | `src/api/interface/parameter-set.ts` |
| **修改** | `src/views/case/detail/components/scene/SceneParameters.vue`（重写主表格 + 引用新弹窗） |
| **删除** | `src/views/case/detail/components/scene/CsvVariableDialog.vue` |
| **修改** | `src/api/interface/scene.ts`（删除 `VariableItem` 上的 `filePath / csvPreview / encoding / delimiter / allowQuotes`） |

### 3.2 类型定义（`src/api/interface/parameter-set.ts`）

```typescript
export namespace ParameterSet {
  export interface Item {
    id: string;
    scenarioId: string;
    name: string;
    description?: string;
    headers: string[];
    columnCount: number;
    rowCount: number;
    status: boolean;
    sourceFilename?: string;
    createTime?: string;
    updateTime?: string;
  }

  export interface DetailItem extends Item {
    rows: string[][];
  }

  export interface ParsePreview {
    filePath: string;
    sourceFilename: string;
    detectedEncoding: string;
    detectedDelimiter: string;
    headers: string[];
    rows: string[][];
    columnCount: number;
    rowCount: number;
  }

  export interface CreateParams {
    scenarioId: string;
    name: string;
    description?: string;
    headers: string[];
    rows: string[][];
    filePath?: string;
    sourceFilename?: string;
  }

  export interface UpdateParams {
    id: string;
    name?: string;
    description?: string;
    status?: boolean;
    replaceData?: boolean;
    headers?: string[];
    rows?: string[][];
    filePath?: string;
    sourceFilename?: string;
  }

  export interface ListParams {
    scenarioId: string;
  }
}
```

### 3.3 API 模块（`src/api/modules/parameter-set.ts`）

```typescript
import http from "@/api";
import type { ParameterSet } from "@/api/interface/parameter-set";

const service = "/test-mng-api-test/parameter-set";

export const parseCsvApi = (file: File) => {
  const form = new FormData();
  form.append("file", file);
  return http.post<ParameterSet.ParsePreview>(`${service}/parse-csv`, form, {
    headers: { "Content-Type": "multipart/form-data" }
  });
};

export const createParameterSetApi = (params: ParameterSet.CreateParams) =>
  http.post<ParameterSet.Item>(`${service}/create`, params);

export const updateParameterSetApi = (params: ParameterSet.UpdateParams) =>
  http.post<ParameterSet.Item>(`${service}/update`, params);

export const deleteParameterSetApi = (id: string) =>
  http.post<boolean>(`${service}/delete`, { id });

export const getParameterSetDetailApi = (id: string) =>
  http.post<ParameterSet.DetailItem>(`${service}/detail`, { id });

export const listParameterSetApi = (scenarioId: string) =>
  http.post<ParameterSet.Item[]>(`${service}/list`, { scenarioId });

export const downloadTemplateUrl = `${service}/template`;
```

### 3.4 主页面 `SceneParameters.vue` 改造

#### 3.4.1 顶部按钮区

```vue
<el-dropdown trigger="click" @command="handleAddCommand">
  <el-button type="primary" :icon="Plus">添加变量</el-button>
  <template #dropdown>
    <el-dropdown-menu>
      <el-dropdown-item command="constant">添加常量</el-dropdown-item>
      <el-dropdown-item command="paramSet">导入参数集（CSV）</el-dropdown-item>
    </el-dropdown-menu>
  </template>
</el-dropdown>
```

#### 3.4.2 主表格（合并展示常量 + 参数集）

两份数据源在前端用一个 `mergedRows` computed 合并：

```typescript
type MergedRow =
  | { kind: "constant"; data: Scene.VariableItem }
  | { kind: "paramSet"; data: ParameterSet.Item };

const constants = ref<Scene.VariableItem[]>([]);
const parameterSets = ref<ParameterSet.Item[]>([]);

const mergedRows = computed<MergedRow[]>(() => [
  ...constants.value.map(d => ({ kind: "constant" as const, data: d })),
  ...parameterSets.value.map(d => ({ kind: "paramSet" as const, data: d }))
]);
```

表格列：

| 列 | 常量 | 参数集 |
|----|------|--------|
| 类型 | `<el-tag>常量</el-tag>` | `<el-tag type="warning">参数集</el-tag>` |
| 名称 | 可编辑 input | 参数集名称（可编辑），下方副信息：`共 N 组 · M 个参数` |
| 值 | 可编辑 input | `<el-button link>查看</el-button>` 打开预览 |
| 描述 | 可编辑 input | 可编辑 input |
| 状态 | switch | switch |
| 操作 | 删除 | 删除 / 编辑 / 重新上传 |

ASCII 示意：

```
┌────────┬────────────────────┬───────────────┬────────────┬──────┬──────┐
│ 类型   │ 名称                │ 值             │ 描述        │ 状态 │ 操作  │
├────────┼────────────────────┼───────────────┼────────────┼──────┼──────┤
│ 常量    │ baseUrl            │ https://...   │            │ ●    │ 🗑️   │
│ 参数集  │ 测试用户集          │ [查看]         │ 登录用     │ ●    │ ⋯   │
│        │ 共 10 组 · 2 个参数  │               │            │      │      │
│ 常量    │ token              │ abcd1234      │            │ ●    │ 🗑️   │
└────────┴────────────────────┴───────────────┴────────────┴──────┴──────┘
```

> **数据保存**：常量沿用现有 `update:modelValue` 逻辑（场景整体保存时一起提交）；参数集是独立 CRUD（每次操作即时调接口），不参与场景保存。这点要在视觉上不引起用户困惑——参数集的删除/编辑直接生效，常量的修改仍跟随场景保存。

### 3.5 `ParameterSetDialog.vue` —— 核心导入弹窗

#### 3.5.1 状态机

```
[空] ──选择文件──▶ [上传中] ──成功──▶ [预览中] ──确定──▶ 关闭
                              │                │
                              └──失败──▶ [错误]  └──删除文件──▶ [空]
```

#### 3.5.2 模板

```vue
<CommonDialog
  v-model:visible="visible"
  :title="dialogTitle"
  width="900px"
  append-to-body
  :close-on-click-modal="false"
  destroy-on-close
>
  <!-- 1. 引导说明 -->
  <div class="ps-intro">
    CSV 文件第一行作为参数名，每一行表示一组参数。
    用例执行时会按行依次/循环取用这些参数组。
  </div>

  <!-- 2. 元信息 -->
  <el-form ref="formRef" :model="form" :rules="rules" label-width="100px" label-position="left">
    <el-form-item label="参数集名称" prop="name">
      <el-input v-model="form.name" placeholder="不填将使用文件名" />
    </el-form-item>
    <el-form-item label="描述">
      <el-input v-model="form.description" type="textarea" :rows="2" />
    </el-form-item>

    <!-- 3. 文件区 -->
    <el-form-item label="CSV 文件" prop="filePath">
      <div class="ps-upload-row">
        <el-upload
          v-if="!form.filePath"
          drag
          :auto-upload="false"
          :show-file-list="false"
          accept=".csv,text/csv"
          :on-change="handleFileChange"
        >
          <div class="ps-upload-tip">
            <el-icon><UploadFilled /></el-icon>
            <div>点击或拖拽 CSV 文件到这里</div>
          </div>
        </el-upload>

        <div v-else class="ps-file-chip">
          <span>{{ form.sourceFilename }}</span>
          <el-button link type="danger" @click="removeFile">删除</el-button>
        </div>

        <el-button link type="primary" @click="downloadTemplate">
          <el-icon><Download /></el-icon> 下载模板
        </el-button>
      </div>
    </el-form-item>
  </el-form>

  <!-- 4. 表格预览 -->
  <ParameterSetPreview
    v-if="form.headers.length"
    :headers="form.headers"
    :rows="form.rows"
    :max-height="320"
    class="mt15"
  />

  <template #footer>
    <el-button @click="visible = false">取消</el-button>
    <el-button type="primary" :loading="submitting" @click="onConfirm">确定</el-button>
  </template>
</CommonDialog>
```

#### 3.5.3 关键脚本逻辑

```typescript
const handleFileChange = async (file: UploadFile) => {
  const raw = file.raw;
  if (!raw) return;
  if (!/\.csv$/i.test(raw.name)) {
    ElMessage.error("仅支持 .csv 文件");
    return;
  }
  uploading.value = true;
  try {
    const preview = await parseCsvApi(raw);
    form.headers = preview.headers;
    form.rows = preview.rows;
    form.filePath = preview.filePath;
    form.sourceFilename = preview.sourceFilename;
    if (!form.name) form.name = preview.sourceFilename.replace(/\.csv$/i, "");
  } catch (e: any) {
    ElMessage.error(e?.message || "CSV 解析失败");
  } finally {
    uploading.value = false;
  }
};

const downloadTemplate = () => {
  // 直接 window.open 走后端接口，让后端控制模板内容
  window.open(import.meta.env.VITE_API_URL + downloadTemplateUrl, "_blank");
};

const onConfirm = async () => {
  const ok = await formRef.value?.validate().catch(() => false);
  if (!ok) return;
  if (!form.headers.length) {
    ElMessage.warning("请先上传并解析 CSV");
    return;
  }
  submitting.value = true;
  try {
    if (props.editId) {
      await updateParameterSetApi({
        id: props.editId,
        name: form.name,
        description: form.description,
        replaceData: form.headers.length > 0 && form.filePath !== props.originalFilePath,
        headers: form.headers,
        rows: form.rows,
        filePath: form.filePath,
        sourceFilename: form.sourceFilename
      });
    } else {
      await createParameterSetApi({
        scenarioId: props.scenarioId,
        name: form.name,
        description: form.description,
        headers: form.headers,
        rows: form.rows,
        filePath: form.filePath,
        sourceFilename: form.sourceFilename
      });
    }
    emit("saved");
    visible.value = false;
  } finally {
    submitting.value = false;
  }
};
```

### 3.6 `ParameterSetPreview.vue` —— 表格预览组件

只负责把 `headers + rows` 渲染成 Element Plus 表格，可在弹窗内 / 主页面"查看"按钮里复用。

```vue
<script setup lang="ts">
defineOptions({ name: "ParameterSetPreview" });
const props = defineProps<{
  headers: string[];
  rows: string[][];
  maxHeight?: number;
}>();

const tableData = computed(() =>
  props.rows.map((row, idx) => {
    const obj: Record<string, string | number> = { __index: idx + 1 };
    props.headers.forEach((h, i) => (obj[h] = row[i] ?? ""));
    return obj;
  })
);
</script>

<template>
  <div class="ps-preview">
    <div class="ps-preview-meta mb10">
      共 {{ rows.length }} 组参数 · {{ headers.length }} 个参数
    </div>
    <el-table :data="tableData" :max-height="maxHeight ?? 320" border size="small">
      <el-table-column type="index" label="组" width="60" align="center" />
      <el-table-column
        v-for="h in headers"
        :key="h"
        :prop="h"
        :label="h"
        min-width="120"
        show-overflow-tooltip
      />
    </el-table>
  </div>
</template>

<style scoped lang="scss">
.ps-preview-meta {
  font-size: 13px;
  color: var(--el-text-color-assistant);
}
</style>
```

### 3.7 删除/重新上传交互

- **删除**：`ElMessageBox.confirm("删除后该用例引用此参数集的步骤将无可用参数，确定继续？")` → 调 delete 接口 → 刷新列表。
- **编辑**：打开 `ParameterSetDialog`，传 `editId`；初始化时调 `getParameterSetDetailApi` 拉完整数据。
- **重新上传**：本质等于编辑场景下，再次触发文件上传 → 解析 → 替换 `headers / rows / filePath` → 提交时 `replaceData=true`。

### 3.8 不做的事

- 行级编辑（在表格里改单格）。第一版只能整体替换。
- 导出参数集回 CSV。
- 大文件（> 10MB）/ 超过 10000 行的支持。

---

## 4. UI / 交互细则（Element Plus + 项目 UI 规范）

### 4.1 颜色与间距

- 全部用 `var(--el-text-color-primary | assistant | secondary)` / `var(--el-bg-color-page-white)` / `var(--el-border-color)`，**禁止硬编码十六进制**。
- 间距用工具类 `.mt10 / .mb15 / .mr8`，禁止 inline style。
- 弹窗 `border-radius: 12px`（继承 `CommonDialog`），表单项 `margin-bottom: 15px`。
- 标签字体颜色 `var(--el-text-color-assistant)`，正文 `var(--el-text-color-primary)`。

### 4.2 引导文案

弹窗顶部：

```
CSV 文件第一行作为参数名，每一行表示一组参数。
示例：第一行 username,password；第二行 alice,123456 即一组参数。
用例执行时会按行依次或循环取用这些参数组。
```

`下载模板` 旁加 tooltip：`下载示例模板，按格式填写后再上传`。

### 4.3 异常提示

- 文件类型错：`仅支持 .csv 文件`
- 文件超大：`CSV 文件过大，限制 10MB`
- 解析失败（来自后端）：原样透传 message
- 表头/行不合法：用户能看到具体到第几行
- 上传中 / 提交中：按钮 loading

### 4.4 状态切换

| 状态 | 表现 |
|------|------|
| 未上传 | 显示拖拽区 + 模板下载 |
| 上传/解析中 | 拖拽区变 loading，禁用确定按钮 |
| 解析成功 | 显示文件 chip + 预览表格 |
| 解析失败 | 红色提示 + 拖拽区可重选 |
| 编辑模式 | 默认有 headers/rows，文件 chip 显示原 sourceFilename，可"删除"重新选 |

---

## 5. 联调与边界

### 5.1 storage 复用

`parse-csv` 接口内部调用 `test-mng-storage` 上传，与现有 `uploadFiles`（前端 `@/api/modules/file-chunk`）相同链路。需要：

- api-test 模块 import storage 的 OpenFeign client（如已有则复用，没有则新增）。
- storage 路径前缀建议 `/scene-csv/{scenarioId}/{yyyyMMdd}/{uuid}.csv`。

如果 api-test 模块直接调 storage 不方便，**降级方案**：前端先调 storage 上传拿 `filePath`，再调 `/parameter-set/parse-csv?filePath=xxx` 让后端从 storage 拉文件解析。两种方案选一种，前者前端体验好（一次请求），后者后端依赖少。**推荐前者**。

### 5.2 网关路由

`/parameter-set/**` 在 gateway 路由到 `test-mng-api-test`。如果路由用 service id 模式自动转发（项目当前模式），无需改 gateway 配置。

### 5.3 鉴权

沿用现有 Sa-Token 拦截，参考 `VariableController` —— 不在方法上加额外注解即可继承全局鉴权。`SessionUtils.getCurrentUserId()` 取当前用户。

### 5.4 模板内容

`/parameter-set/template` 返回固定模板：

```csv
username,password
alice,123456
bob,abcdef
```

Content-Disposition: `attachment; filename="parameter-set-template.csv"`。

---

## 6. 实施顺序（建议拆 PR）

| 阶段 | 内容 | 范围 |
|------|------|------|
| **PR-1** | DDL + 后端骨架 | 表 / Entity / Mapper / Controller / Service 空壳，先让 swagger 跑起来 |
| **PR-2** | CSV 解析能力 | `CsvParseService` 实现 + 单元测试，`parse-csv` 接口可用 |
| **PR-3** | 后端 CRUD + 模板下载 | create / update / delete / detail / list / template 全通 |
| **PR-4** | 前端 API 模块 + 类型 | 不动 UI，先让 `parameter-set.ts` 可调通后端 |
| **PR-5** | 新弹窗 + 预览组件 | `ParameterSetDialog.vue` + `ParameterSetPreview.vue`，独立可测 |
| **PR-6** | 主页面整合 + 删除旧代码 | 改 `SceneParameters.vue`，删 `CsvVariableDialog.vue`，删 `Scene.VariableItem` 上 CSV 字段 |

> 第二版（执行侧：调试单组 / 循环执行 / 报告）单独立项，本设计文档不展开。

---

## 7. 验收 Checklist

- [ ] `tb_parameter_set` / `tb_parameter_set_row` 已建表
- [ ] `parse-csv` 能识别 UTF-8 / UTF-8 BOM / GBK / GB18030
- [ ] `parse-csv` 能识别 `,` / `;` / `\t` 三种分隔符
- [ ] 引号、含逗号字段、转义引号正确解析
- [ ] 表头空 / 重复 / 列数不一致都有可读错误
- [ ] 创建后能在场景下用 `list` 查到，`detail` 拿到完整 rows
- [ ] 前端弹窗：上传 → 表格立即出现 → 确定 → 列表多一行参数集
- [ ] 主表格能同时显示常量与参数集，类型 tag 区分
- [ ] 「下载模板」可点击下载示例 CSV
- [ ] 编辑/删除/重新上传 全链路通
- [ ] 旧 `CsvVariableDialog.vue` 已删除，`Scene.VariableItem` 上 CSV 字段已删除
- [ ] UI 颜色全部走 CSS 变量、间距走工具类
- [ ] 后端 DTO/VO 字段全部带 `@Schema`（项目硬性规范）

---

**文档状态**：设计草稿，待评审。评审通过后按 §6 拆 PR 落地。
