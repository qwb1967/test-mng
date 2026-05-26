# gRPC 协议测试 · 用户使用指南

> 工单：**ASAIO-1858**
> 适用版本：含 Stage 1 + Stage 2 的发布（Reflection 模式 + Proto 文件模式 unary 真实调用）
> 阅读对象：测试人员、QA、开发自测

---

## 1. 简介

测试管理平台支持对 gRPC 服务做接口测试。当前版本提供两种**服务发现模式**：

- **Reflection 模式**：目标 gRPC server 启用了 gRPC Server Reflection 时，平台自动拉取服务描述符，**最简单**
- **Proto 文件模式**：上传 `.proto` 源码到平台，运行时编译解析后发起调用，**适用于 server 未启用 Reflection 的场景**

**仅支持 unary RPC**（一问一答），server / client / bidi streaming 暂不支持（见 [§8 当前版本限制](#8-当前版本限制)）。

---

## 2. 前置条件

| 项 | 说明 |
|---|---|
| 网络可达 | 测试平台服务器到目标 gRPC server 的 host:port 必须可访问（生产环境注意防火墙 / VPN）|
| 服务地址 | 形如 `host:port`，不需要 `grpc://` 前缀（平台会自动归一化）|
| 完整方法路径 | 形如 `/demo.Demo/SayHello`，包含包名 |
| Proto 文件（如选 Proto 文件模式）| `.proto` 源码，**单文件，≤1MB**，不能 import 其它自定义 .proto |

---

## 3. 创建 gRPC 接口

1. 打开「接口管理」页面，定位到目标服务的目录
2. 点「新建接口」，**协议类型选 gRPC**
3. 填写：
   - **服务器地址**：`159.75.169.73:50051`（host:port）
   - **服务名称**：`demo.Demo`（含包名的完整服务名）
   - **方法名称**：`SayHello`
   - **消息类型**：`JSON`（当前仅支持）
   - **服务发现模式**：Reflection 或 Proto 文件（详见 §4 / §5）
4. 在「消息内容」里填 JSON 格式的请求体
5. 点「保存」

---

## 4. Reflection 模式

### 4.1 何时用

目标 gRPC server **启用了** gRPC Server Reflection 服务。判断方法：

```bash
# 如本机装了 grpcurl
grpcurl -plaintext <host>:<port> list
# 能列出服务名说明 Reflection 已启用；报 UNIMPLEMENTED 说明没启用
```

### 4.2 操作流程

1. 「服务发现模式」选 **Reflection**
2. 直接点「发送请求」
3. 平台自动拉取描述符 → 构造请求 → 发起调用 → 展示响应

### 4.3 控制台输出示例

```
[INFO] 执行 [GRPC] 请求: GRPC 159.75.169.73:50051
[INFO] 执行 [GRPC] 请求: /demo.Demo/SayHello
[INFO] gRPC Reflection 拉取描述符: service=demo.Demo, method=SayHello
[INFO] gRPC 描述符解析成功: demo.Demo/SayHello, input=demo.HelloRequest, output=demo.HelloReply
[INFO] gRPC调用: /demo.Demo/SayHello, deadline=30000ms
[INFO] gRPC响应: status=OK(0), 耗时=576ms, size=24
```

---

## 5. Proto 文件模式

### 5.1 何时用

- 目标 server **未启用** Reflection（生产环境常见，因 Reflection 暴露内部接口列表）
- 想用本地手头已有的 `.proto` 文件做测试

### 5.2 上传 Proto 文件

1. 「服务发现模式」选 **Proto 文件**
2. 出现「Proto 文件」下拉，点旁边的 **「上传新 .proto」** 按钮
3. 弹出上传对话框，填：
   - **文件名**：如 `user.proto`
   - **描述**：可选
   - **Proto 源码**：在 textarea 粘贴源码 **或** 点「从本地选择 .proto」选择本地文件（自动读入文本）
4. 点「确认上传」，上传成功后下拉自动选中

### 5.3 切换 Proto 文件

下拉支持远程搜索：输入文件名关键字（300ms 防抖），从已上传列表里选。

### 5.4 控制台输出示例

```
[INFO] 执行 [GRPC] 请求: /demo.Demo/SayHello
[INFO] gRPC PROTO_FILE 模式: protoFileId=1, name=demo.proto, version=1.0 [缓存命中]
[INFO] gRPC 描述符解析成功（PROTO_FILE）: demo.Demo/SayHello, input=demo.HelloRequest, output=demo.HelloReply
[INFO] gRPC调用: /demo.Demo/SayHello, deadline=30000ms
[INFO] gRPC响应: status=OK(0), 耗时=68ms, size=24
```

注意 `[缓存命中]` 标记 —— 同一 proto 文件第二次调用会复用编译结果，显著更快。

---

## 6. 发送请求 + 解读响应

### 6.1 请求体（JSON）

按 proto 定义填，例：

```proto
message HelloRequest {
  string name = 1;
}
```

对应请求体：

```json
{ "name": "测试用户" }
```

### 6.2 响应区段

| 字段 | 说明 |
|---|---|
| **状态** | `SUCCESS` 或 gRPC 标准 Status code 名（如 `UNIMPLEMENTED` / `INVALID_ARGUMENT`）|
| **耗时** | 含 protoc 编译（首次）/ 描述符解析 + RPC 调用的总耗时 |
| **大小** | 响应 body 字节数 |
| **响应体** | 服务端返回的真实 JSON |
| **控制台** | 完整调用日志，排查问题用 |

### 6.3 常见 gRPC Status Code

| Code | 含义 | 常见原因 |
|---|---|---|
| `0 OK` | 成功 | — |
| `3 INVALID_ARGUMENT` | 请求参数不合法 | 请求体 JSON 不匹配 proto schema（字段类型不对、必填字段缺失）|
| `4 DEADLINE_EXCEEDED` | 超时 | 网络不通 / server 处理慢 / deadline 设太小 |
| `5 NOT_FOUND` | 找不到资源 | 业务侧报错 |
| `12 UNIMPLEMENTED` | 方法未实现 | **常见**：目标 server 未启用 Reflection；或 fullMethod 拼错 |
| `14 UNAVAILABLE` | 服务不可用 | server 挂了 / 网络不通 |
| `16 UNAUTHENTICATED` | 未认证 | metadata 里缺 token / token 错 |

---

## 7. FAQ

**Q：为什么显示 `UNIMPLEMENTED` 错误？**
A：90% 概率是目标 server 没开 Reflection。请切到「Proto 文件」模式 + 上传相应 .proto。剩余 10% 是 fullMethod 拼错或方法不存在。

**Q：上传 .proto 后报「编译失败：...」？**
A：检查 .proto 语法。注意当前**不支持** .proto 互相 import 用户自定义文件，但 `google/protobuf/*.proto` 等 well-known types 正常。如果你的 proto 引用了别的 proto，把它们 inline 到一个文件里。

**Q：请求体 JSON 不匹配 schema？**
A：响应会显示 `INVALID_ARGUMENT`，错误消息会提示具体字段。例：`Cannot find field: foo` 表示 proto 里没有 `foo` 字段；`Expected int32 but got string` 表示类型不对。

**Q：proto 文件能删除吗？**
A：可以，但**被任何 gRPC 接口引用时会拒绝删除**（响应消息会告诉你被几个接口引用）。需要先在那些接口里切换发现模式 / 换其他 proto，再来删。

**Q：metadata（HTTP/2 headers）怎么传？**
A：在接口详情页表单里有「元数据」字段，按 key/value 填即可（如 `authorization: Bearer xxx`）。

**Q：TLS 怎么开？**
A：勾选「启用 TLS」复选框。注意目标 server 必须支持 TLS（端口通常 443 / 8443），用 plaintext 端口（如 50051）勾 TLS 会握手失败。

**Q：第一次调用慢，第二次就快了，是为什么？**
A：Proto 文件模式首次调用要释放 protoc binary + 编译 .proto，约 1-2s；后续相同 proto 命中 JVM 本地缓存，仅几十 ms。Reflection 模式每次都要从 server 拉描述符，相对慢一些（受网络影响）。

---

## 8. 当前版本限制

> 以下限制不会修复在本次发布里，需要后续工单跟进。**用户、QA、产品都需知晓**。

### 8.1 协议层

- ✅ 支持：**unary RPC**（一问一答）
- ❌ 不支持：**server streaming**（一问多答）
- ❌ 不支持：**client streaming**（多问一答）
- ❌ 不支持：**bidi streaming**（双向流）

调用 streaming 方法会因 RPC type 不匹配失败。如有此类需求，请走单独工单。

### 8.2 Proto 文件

- 单文件，大小 ≤ **1MB**
- **不支持** import 用户自定义的其它 `.proto`（well-known types 如 `google/protobuf/timestamp.proto` 可正常引用）
- 如需多文件，请把所有 message / service 定义 inline 到一个文件

### 8.3 性能

- **多实例独立缓存**：proto 编译结果按 `(protoFileId, update_time)` 缓存在 JVM 本地；多实例部署时每个实例首次调用都会触发一次 protoc 编译（约 1-2s）。如压测出现首次慢的报警，是预期行为
- proto 文件 update 后立即触发重新编译（按 update_time 失效）

### 8.4 权限 / 多租户

- 当前 `ProtocolFileService` 的 `getById / update / delete` **未严格校验**跨 space 越权
- 依赖前端按 space 过滤来防止用户看到其它 space 的 proto
- 服务端**不阻断**直接以 protoFileId 调用 detail 接口的越权请求
- 待 `SessionUtils` 提供 `getCurrentSpaceId()` 后单独工单加严格校验

### 8.5 UI

- 暂未提供独立的「Proto 文件管理」CRUD 页面（菜单 / 列表 / 批量编辑）
- 所有 Proto 文件相关操作（上传 / 选择 / 删除）都在 gRPC 接口详情页嵌入式完成
- 独立管理页面留独立工单

### 8.6 Reflection 模式

- 要求目标 server 启用 gRPC Server Reflection（`io.grpc:grpc-services` 注册的 `ProtoReflectionService`）
- 生产环境的 gRPC server 通常**不启用** Reflection（暴露接口列表是安全风险）。**Proto 文件模式是生产场景的主路径**

---

## 9. 排查工具

### 9.1 看后端日志

`test-mng-api-test-execution` 服务的标准输出（生产环境通过日志平台）。搜：

- `gRPC Reflection 拉取描述符` —— Reflection 模式开始
- `gRPC PROTO_FILE 模式` —— Proto 文件模式开始
- `gRPC 描述符解析成功` —— 描述符解析完成（含 input/output 类型）
- `gRPC调用` —— 真实 RPC 开始
- `gRPC响应` —— 调用结束（含 status / 耗时 / 响应大小）
- `gRPC请求失败` —— 失败原因

### 9.2 本地复现

如果只有平台报错但你想本地复现：

```bash
# 本地装 grpcurl 直接调
grpcurl -plaintext -d '{"name":"测试用户"}' 159.75.169.73:50051 demo.Demo/SayHello

# Proto 文件模式本地复现
grpcurl -plaintext -d '{"name":"测试"}' -proto demo.proto 159.75.169.73:50051 demo.Demo/SayHello
```

### 9.3 测试用 demo server

可访问的测试 server（公网，请勿压测）：

- `159.75.169.73:50051`
- 方法：`demo.Demo/SayHello`
- 请求：`{"name": "<任意字符串>"}`
- 响应：`{"message": "Hello <字符串>"}`

---

## 10. 反馈

发现 bug / 体验问题 / 限制痛点，请在 ASAIO 提 ticket，关联 ASAIO-1858。
