# gRPC 协议执行设计文档

> 工单：**ASAIO-1858**
> 模块：`test-mng-api-test-execution`
> 范围：**仅 Unary**（Reflection 模式 + Proto 文件模式），不含 streaming
> 状态：Stage 1 代码已实现（本地编译通过，尚未部署验证）；Stage 2 待开始
> 最近更新：2026-05-24（详见 §11 实施进展）

---

## 1. 背景

当前 `cloud.aisky.protocol.impl.GrpcProtocolExecutor` 的 `executeWithReflection` 方法是个 TODO 桩：

- 只调用 `channel.getState(true)` 做端口探测
- 直接返回硬编码字符串 `{"status":"reflection_connected","note":"gRPC Reflection完整实现需要配合proto文件上传模式使用"}`
- 永远 `statusCode=0`、`responseTime≈0ms`

而另一条分支（Proto 文件模式）直接返回「Proto文件模式暂未实现」错误响应。**两条路径都没有真正发起 gRPC 调用**。

测试平台上 fat 环境 `apiId=2055893380398391297`（`demo.Demo/SayHello`）就是因此一直无法真测试。

## 2. 本轮范围

| 范围 | 是否本轮 |
|---|---|
| Reflection 模式 unary 真实调用 | ✅ Stage 1 |
| Proto 文件模式 unary 真实调用 | ✅ Stage 2 |
| TLS 通道修复 | ✅ Stage 1 顺手修 |
| gRPC Status code 正确映射 | ✅ Stage 1 |
| Server streaming / Client streaming / Bidi streaming | ❌ 独立工单 |
| 前端 proto 文件上传 UI | ✅ Stage 2（前端独立 MR）|
| 前端 streaming UI | ❌ 独立工单 |

按团队 git-flow，Stage 1 与 Stage 2 各提一个 MR 到 `develop`。

## 3. 现状盘点

`GrpcProtocolExecutor` 里**已有可复用**的代码：

| 能力 | 文件:行号 |
|---|---|
| Channel 缓存（`ConcurrentHashMap<endpoint, ManagedChannel>`） | `GrpcProtocolExecutor.java:42, 186-195` |
| Metadata 解析（JSONArray → `io.grpc.Metadata`） | `GrpcProtocolExecutor.java:200-214` |
| Endpoint 解析（剥 `grpc://` 前缀、`host:port` 切分） | `GrpcProtocolExecutor.java:230-240` |
| `parseServiceName`（从 `/pkg.Service/Method` 提取 `pkg.Service`） | `GrpcProtocolExecutor.java:219-228` |
| `testConnection`、`cleanup`、`validateConfig` | `GrpcProtocolExecutor.java:138-181` |
| 变量替换 / config 解析 | `GrpcProtocolExecutor.java:242-262` |

**已有的小问题**（Stage 1 顺手修复，不另起任务）：

1. `getOrCreateChannel` 在 `useTLS=true` 时没显式调 `useTransportSecurity()`，依赖 `ManagedChannelBuilder` 的默认行为，不够明确
2. Channel 缓存 key 只用 `host:port`，没区分 `useTLS`，同地址不同 TLS 设置时会复用错通道
3. `testConnection` 读了 `useTLS` 但建 channel 时没用

`tb_protocol_file` 表 + `ProtocolFile*Service` + `ProtocolFileController` **已存在**，可用于 Stage 2 的 proto 文件存储 / 管理。

前端 `GrpcApiDetail.vue` 已有 `discoveryMode` 选择（`REFLECTION` / `PROTO_FILE`）和 `protoFileId` 字段，**Stage 2 只需要补 proto 文件上传 UI**。

## 4. 总体流程

```
┌──────────────────────────────────────────────────────┐
│  GrpcProtocolExecutor.execute(request, ctx, console) │
└───┬──────────────────────────────────────────────────┘
    │  1. 解析 protocolConfig
    │     → host/port/fullMethod/discoveryMode/metadata
    │       /deadline/useTLS
    │  2. getOrCreateChannel(host, port, useTLS)
    │
    ▼
┌──────────────────────────────────────────────────────┐
│  解析目标方法的 Descriptors.MethodDescriptor          │
│  ┌────────────────────┐  ┌────────────────────────┐ │
│  │ ReflectionResolver │  │ ProtoFileResolver      │ │
│  │ (Stage 1)          │  │ (Stage 2)              │ │
│  └────────────────────┘  └────────────────────────┘ │
└───┬──────────────────────────────────────────────────┘
    │ Descriptors.MethodDescriptor
    ▼
┌──────────────────────────────────────────────────────┐
│  DynamicGrpcCaller（共同逻辑）                        │
│  • JsonFormat 解析用户 body → DynamicMessage          │
│  • 构造 io.grpc.MethodDescriptor<Dyn, Dyn>            │
│    用 ProtoUtils.marshaller                           │
│  • ClientCalls.blockingUnaryCall（带 deadline、       │
│    metadata 拦截器）                                  │
│  • 响应 DynamicMessage → JsonFormat 序列化            │
└───┬──────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────┐
│  ProtocolResponse 组装                                │
│  • 成功：statusCode=0, body=JSON, responseTime, size  │
│  • 失败：从 StatusRuntimeException 提取 gRPC code     │
│    映射 statusCode + statusText + errorMessage        │
└──────────────────────────────────────────────────────┘
```

## 5. 模块依赖变更

`test-mng-service/pom.xml`（parent dependencyManagement）已有：

- `io.grpc:grpc-netty-shaded:1.62.2`
- `io.grpc:grpc-protobuf:1.62.2`
- `io.grpc:grpc-stub:1.62.2`
- `com.google.protobuf:protobuf-java-util:3.25.3`
- `com.google.protobuf:protobuf-java:3.25.3`

**新增**：

```xml
<dependency>
    <groupId>io.grpc</groupId>
    <artifactId>grpc-services</artifactId>
    <version>${grpc.version}</version>
</dependency>
```

`grpc-services` 提供 `io.grpc.reflection.v1alpha.ServerReflectionGrpc` 与 `ServerReflectionRequest/Response` 等 stub，是 Reflection 客户端调用的关键。`test-mng-api-test-execution` 模块的 pom 同步引入。

## 6. Stage 1：Reflection 模式

### 6.1 类设计

新增 2 个支撑类，保持 `GrpcProtocolExecutor` 主类只做编排：

```
cloud.aisky.protocol.grpc/
├── ReflectionDescriptorResolver.java   ← Reflection 拉 FileDescriptor
└── DynamicGrpcCaller.java              ← JSON↔DynamicMessage + unary 调用
```

主类 `GrpcProtocolExecutor.executeWithReflection` 改造为：

```java
private ProtocolResponse executeWithReflection(
        ManagedChannel channel, String host, int port,
        String fullMethod, Metadata metadata,
        String bodyJson, int deadline,
        long startTime, ConsoleCollector console) throws Exception {

    String serviceName = parseServiceName(fullMethod);
    String methodSimpleName = parseMethodSimpleName(fullMethod);

    // 1. Reflection 拉描述符
    Descriptors.MethodDescriptor methodDesc =
            reflectionResolver.resolve(channel, serviceName, methodSimpleName, console);

    // 2. 共同调用逻辑
    return dynamicCaller.invokeUnary(
            channel, methodDesc, fullMethod, metadata, bodyJson,
            deadline, startTime, console);
}
```

### 6.2 ReflectionDescriptorResolver

核心流程：

```java
public Descriptors.MethodDescriptor resolve(
        ManagedChannel channel, String serviceName, String methodName,
        ConsoleCollector console) throws Exception {

    // 1. 开 bidi stream 到 ServerReflection
    ServerReflectionGrpc.ServerReflectionStub stub = ServerReflectionGrpc.newStub(channel);

    // 2. 请求 fileContainingSymbol = serviceName（带超时）
    // 3. 收 FileDescriptorResponse → 拿到 List<ByteString> fileDescriptorProto
    // 4. 解析每个 ByteString 为 FileDescriptorProto
    // 5. 递归拉取所有 import 的 .proto 文件
    //    （ServerReflectionRequest.fileByFilename）
    //    设深度上限 32 防恶意循环
    // 6. 拓扑排序，按依赖顺序构建 Descriptors.FileDescriptor
    //    用 Descriptors.FileDescriptor.buildFrom(proto, deps, true)
    // 7. 从最终 FileDescriptor 找到 ServiceDescriptor → MethodDescriptor
}
```

关键点：

- ServerReflection 是 **bidi streaming RPC**（一次 stream 内可多次 request/response），用 `StreamObserver` + `CountDownLatch` 阻塞同步化
- 递归拉 import 时用 `Map<filename, FileDescriptorProto>` 去重
- 构建 FileDescriptor 必须按依赖拓扑顺序，且第三个参数 `allowUnknownDependencies=true` 兜底
- 整体设 10 秒超时（来自 `protocolConfig.deadline`）

### 6.3 DynamicGrpcCaller

```java
public ProtocolResponse invokeUnary(
        ManagedChannel channel, Descriptors.MethodDescriptor methodDesc,
        String fullMethod, Metadata metadata, String bodyJson,
        int deadlineMs, long startTime, ConsoleCollector console) {

    // 1. JSON → DynamicMessage
    DynamicMessage.Builder reqBuilder =
            DynamicMessage.newBuilder(methodDesc.getInputType());
    JsonFormat.parser().ignoringUnknownFields().merge(bodyJson, reqBuilder);
    DynamicMessage request = reqBuilder.build();

    // 2. 构造 io.grpc.MethodDescriptor<Dyn, Dyn>
    io.grpc.MethodDescriptor<DynamicMessage, DynamicMessage> grpcMethod =
            io.grpc.MethodDescriptor.<DynamicMessage, DynamicMessage>newBuilder()
                    .setType(io.grpc.MethodDescriptor.MethodType.UNARY)
                    .setFullMethodName(fullMethod.startsWith("/") ?
                            fullMethod.substring(1) : fullMethod)
                    .setRequestMarshaller(ProtoUtils.marshaller(
                            DynamicMessage.getDefaultInstance(methodDesc.getInputType())))
                    .setResponseMarshaller(ProtoUtils.marshaller(
                            DynamicMessage.getDefaultInstance(methodDesc.getOutputType())))
                    .build();

    // 3. 调用（带 deadline + metadata）
    CallOptions callOptions = CallOptions.DEFAULT
            .withDeadlineAfter(deadlineMs, TimeUnit.MILLISECONDS);
    Channel channelWithMeta = ClientInterceptors.intercept(channel,
            MetadataUtils.newAttachHeadersInterceptor(metadata));

    try {
        DynamicMessage response = ClientCalls.blockingUnaryCall(
                channelWithMeta, grpcMethod, callOptions, request);

        // 4. DynamicMessage → JSON
        String responseJson = JsonFormat.printer()
                .omittingInsignificantWhitespace()
                .preservingProtoFieldNames()
                .print(response);

        long responseTime = System.currentTimeMillis() - startTime;
        return ProtocolResponse.builder()
                .success(true)
                .statusCode(0)        // gRPC OK
                .body(responseJson)
                .responseTime(responseTime)
                .responseSize((long) responseJson.length())
                .actualRequestUrl(channelEndpointOf(channel) + fullMethod)
                .actualRequestMethod("gRPC_unary")
                .actualRequestBody(bodyJson)
                .build();

    } catch (StatusRuntimeException sre) {
        // 5. gRPC 错误状态映射
        return mapStatusException(sre, ...);
    }
}
```

### 6.4 gRPC Status 映射

`ProtocolResponse` 本身没有 `statusText` 字段（确认过 `ProtocolResponse.java`），所以：

- `statusCode` ← `StatusRuntimeException.getStatus().getCode().value()`（gRPC 标准 0-16）
- `metadata.put("grpcStatus", code.name())` ← 状态枚举名（`OK` / `UNIMPLEMENTED` / `DEADLINE_EXCEEDED` 等），上层 / 前端取这里
- `errorMessage` ← `sre.getStatus().getDescription()`，没有时回退 `sre.getMessage()`

成功路径：`statusCode=0`、`metadata.grpcStatus="OK"`、`body=` 真实 JSON 响应。

### 6.5 TLS 与 Channel 缓存修复

```java
private ManagedChannel getOrCreateChannel(String host, int port, boolean useTLS) {
    String key = host + ":" + port + (useTLS ? ":tls" : ":plain");   // 区分 TLS
    return channelCache.computeIfAbsent(key, k -> {
        ManagedChannelBuilder<?> builder = ManagedChannelBuilder.forAddress(host, port);
        if (useTLS) {
            builder.useTransportSecurity();                          // 显式 TLS
        } else {
            builder.usePlaintext();
        }
        return builder.build();
    });
}
```

`testConnection` 也用同一份逻辑。

### 6.6 异常分层

| 异常类型 | 处理 |
|---|---|
| `StatusRuntimeException` (UNIMPLEMENTED on `ServerReflection.ServerReflectionInfo`) | 友好提示「目标服务未启用 gRPC Reflection，请使用 Proto 文件模式」 |
| `InvalidProtocolBufferException` (JsonFormat.parser merge 失败) | 「请求体 JSON 不符合 proto schema：{原因}」 |
| `StatusRuntimeException` (其它) | 按 6.4 映射 |
| 其它 `Exception` | 走 `execute()` 已有的 catch 兜底 |

### 6.7 Stage 1 验收

- fat: `apiId=2055893380398391297` (demo.Demo/SayHello) 用 body `{"name":"测试用户"}`，预期：
  - `success=true`，`statusCode=0`，`statusText="SUCCESS"`
  - `body` 是真实 RPC 响应 JSON（含 `message` 等字段），**不是占位字符串**
  - `responseTime` > 0
- 错误场景：
  - method 不存在 → `statusCode=12 (UNIMPLEMENTED)`
  - body 不合 schema → 明确报错原因
  - 目标不支持 Reflection → 提示切到 Proto 文件模式
  - 网络超时 → `statusCode=4 (DEADLINE_EXCEEDED)`

## 7. Stage 2：Proto 文件模式

### 7.1 上传格式决策

**已决定：方案 B —— 上传 `.proto` 源码，服务端运行时编译**。

原因：测试人员通常拿到的就是 `.proto` 源文件，不必额外学习 `protoc --descriptor_set_out` 命令，体验更顺。

实施要点：

- 引入 `com.github.os72:protoc-jar:3.11.4`（嵌入式 protoc，运行时调用编译 `.proto` → `FileDescriptorSet`）
- 或备选：用纯 Java protobuf 解析器（`com.squareup.wire:wire-schema` 等）
- 编译失败时返回明确的 syntax error 行号
- `tb_protocol_file.file_content` 已是 LONGTEXT（适合源码字符串），无需 schema 变更
- 多文件 import 场景：先支持单文件 / 用户 paste 进去，多文件 import 留扩展点

### 7.2 ProtoFileDescriptorResolver

```java
public Descriptors.MethodDescriptor resolve(
        Long protoFileId, String serviceName, String methodName) throws Exception {
    // 1. ProtocolFileService.getById(protoFileId) 拿 file_content（byte[]）
    // 2. DescriptorProtos.FileDescriptorSet.parseFrom(bytes)
    // 3. 按依赖顺序 buildFrom 重建 FileDescriptor[]
    // 4. 找到 ServiceDescriptor → MethodDescriptor
}
```

之后复用 Stage 1 的 `DynamicGrpcCaller.invokeUnary`，路径合一。

### 7.3 前端补丁（独立前端仓库 MR）

`test-mng-web/src/views/api-module/components/GrpcApiDetail.vue`：

- `discoveryMode=PROTO_FILE` 时显示 proto 文件选择器
- 调用现有 `ProtocolFileController` 的上传/列表接口
- 复用 `tb_protocol_file` 已有的目录结构

## 8. 风险

| 风险 | 缓解 |
|---|---|
| 目标 gRPC 服务关了 Reflection | 友好报错，引导用户切换到 Proto 文件模式 |
| `FileDescriptor` 循环依赖（恶意服务端） | 递归深度上限 32 + 已访问 filename 去重 |
| ServerReflection bidi stream 超时挂起 | `StreamObserver` + `CountDownLatch` + 整体超时 |
| Channel 资源泄漏 | 复用现有 `cleanup()` 池关闭逻辑；不在调用路径上 close |
| `tb_protocol_file.file_content` 类型不支持二进制 | Stage 2 起步前先 `DESC` 确认；如需改 BLOB 走 DBA 工单（**不在程序里 DDL**）|
| Channel 缓存内存膨胀 | 现状未实现 TTL/LRU；本轮先不动，若线上有问题再加 |

## 9. 实施步骤

### Stage 1（MR #1）

1. parent `pom.xml` + `test-mng-api-test-execution/pom.xml` 加 `grpc-services` 依赖
2. 新增 `cloud.aisky.protocol.grpc.ReflectionDescriptorResolver`
3. 新增 `cloud.aisky.protocol.grpc.DynamicGrpcCaller`
4. 改造 `GrpcProtocolExecutor.executeWithReflection` 调用新类
5. 修复 `getOrCreateChannel` + `testConnection` 的 TLS / 缓存 key
6. 本地编译通过 + 部署 dev/fat 验证 fat apiId=2055893380398391297
7. 提交 MR：`feat: ASAIO-1858 实现 gRPC Reflection 模式 unary 真实调用`

### Stage 2（MR #2）

1. 确认 `tb_protocol_file.file_content` 字段类型支持二进制
2. 新增 `cloud.aisky.protocol.grpc.ProtoFileDescriptorResolver`
3. 改造 `GrpcProtocolExecutor` 的 PROTO_FILE 分支
4. 前端 `GrpcApiDetail.vue` 加 proto 文件上传 UI（独立 MR）
5. 提交 MR：`feat: ASAIO-1858 实现 gRPC Proto 文件模式 unary 调用`

## 10. 不变更的部分

- `protocolConfig` JSON schema 不变（字段已齐全）
- `tb_api_info` / `tb_protocol_file` 表结构不动（不在程序里 DDL）
- 前端 `protocolConfig` 字段填写规则不变（Stage 2 仅加 proto 文件选择 UI）
- `ProtocolExecutor` 接口与 `ProtocolResponse` 结构不变

## 11. 实施进展

> 最近更新：2026-05-24

### 11.1 总览

| Stage | 子项 | 状态 |
|---|---|---|
| **Stage 1** | parent + 模块 `pom.xml` 引入 `grpc-services` | ✅ 已完成 |
| **Stage 1** | `ReflectionDescriptorResolver`（Reflection 拉描述符） | ✅ 已完成 |
| **Stage 1** | `DynamicGrpcCaller`（JSON↔DynamicMessage + unary 调用） | ✅ 已完成 |
| **Stage 1** | `GrpcProtocolExecutor` 主链路改造 | ✅ 已完成 |
| **Stage 1** | TLS / Channel 缓存 key 修复 | ✅ 已完成 |
| **Stage 1** | gRPC Status code 映射 + 友好错误提示 | ✅ 已完成 |
| **Stage 1** | 本地编译验证 | ✅ 通过 |
| **Stage 1** | dev / fat 部署实测（`demo.Demo/SayHello`） | ⏳ 待做 |
| **Stage 1** | 单元测试 | ⏳ 待评估 |
| **Stage 1** | MR #1 提交 | ⏳ 待做 |
| **Stage 2** | `tb_protocol_file.file_content` 字段类型确认 | ⏳ 待做 |
| **Stage 2** | 引入嵌入式 protoc / 编译方案 | ⏳ 待做 |
| **Stage 2** | `ProtoFileDescriptorResolver` | ⏳ 待做 |
| **Stage 2** | `GrpcProtocolExecutor` PROTO_FILE 分支 | ⏳ 占位返回 UNIMPLEMENTED |
| **Stage 2** | 前端 proto 文件上传 UI（独立前端 MR） | ⏳ 待做 |
| **Stage 2** | MR #2 提交 | ⏳ 待做 |

### 11.2 已完成的实现细节

**依赖**：parent `pom.xml` 在 `dependencyManagement` 中新增 `io.grpc:grpc-services:${grpc.version}`；
`test-mng-api-test-execution/pom.xml` 同步声明引入。版本沿用现有 `grpc.version = 1.62.2`。

**新增类**（`test-mng-api-test-execution/src/main/java/cloud/aisky/protocol/grpc/`）：

- `ReflectionDescriptorResolver`
  - `ServerReflectionGrpc` bidi stream + `CountDownLatch` 同步化，整体超时 10 s
  - 递归拉取所有 `.proto` 依赖，深度上限 32 + filename 去重
  - 内置 `WELL_KNOWN_PROTOS` 静默兜底（`google/protobuf/any.proto` 等 10 个），优先用 classpath 自带描述符，不存在则降级走远端拉取——比设计文档多做了一步，避免目标服务依赖 well-known proto 时反复打扰 Reflection 端点
  - `Descriptors.FileDescriptor.buildFrom(proto, deps, allowUnknownDependencies=true)` 按依赖拓扑构建
- `DynamicGrpcCaller`
  - `JsonFormat.parser().ignoringUnknownFields()` 解析 body
  - `io.grpc.MethodDescriptor` + `ProtoUtils.marshaller` 构造 dynamic stub
  - `ClientCalls.blockingUnaryCall` + `withDeadlineAfter` + `MetadataUtils.newAttachHeadersInterceptor`
  - `JsonFormat.printer().preservingProtoFieldNames()` 序列化响应
  - `StatusRuntimeException` 与 `InvalidProtocolBufferException` 分别映射

**改造 `GrpcProtocolExecutor`**：

- 用 `@RequiredArgsConstructor` 注入 `ReflectionDescriptorResolver` / `DynamicGrpcCaller`
- 主方法 `execute()` 直接编排 `parseService → resolve → invokeUnary`，**未保留** §6.1 提到的 `executeWithReflection` 中间方法——逻辑简化，行数更少；如果后续 Stage 2 需要复杂分支，可以再抽
- `parseMethodSimpleName` 新增（`/pkg.Service/Method → Method`）
- 顶层捕获 `StatusRuntimeException` 时，若 `code == UNIMPLEMENTED`，错误消息追加「目标服务未启用 gRPC Reflection（或方法不存在），可改用 Proto 文件模式」
- 顶层非 status 异常走 `UNKNOWN(2)` 兜底，附 `metadata.grpcStatus = "UNKNOWN"`
- `getOrCreateChannel`：缓存 key 改为 `host:port:(tls|plain)`，`useTLS=true` 时显式 `useTransportSecurity()`
- `testConnection`：复用 `getOrCreateChannel`（之前每次新建 channel + shutdown，资源浪费且未带 TLS）

**与设计文档的微小偏差**（无需 review 阻塞，备忘）：

| 偏差 | 决策 |
|---|---|
| 未保留 `executeWithReflection` 中间方法 | 简化，逻辑直接在 `execute()` 里编排 |
| `WELL_KNOWN_PROTOS` 静默兜底未写在设计里 | 多做一步，提升健壮性 |
| `InvalidProtocolBufferException` 在 `DynamicGrpcCaller` 内捕获而非 `GrpcProtocolExecutor` 顶层 | 错误就近处理，与设计 §6.6 效果等价 |

### 11.3 待办（按优先级）

**Stage 1 收尾**：

1. **部署验证**：把当前 working tree 改动合到 develop 后部署到 dev / fat
2. **fat 实测**：用 `apiId=2055893380398391297`（`demo.Demo/SayHello`）调用一次，验收清单见 §6.7
3. **错误场景实测**：method 不存在 / body 不合 schema / 目标不支持 Reflection / deadline 超时，4 种状态码映射各跑一次
4. **单元测试**（与团队对齐是否补）：`ReflectionDescriptorResolver` 的依赖解析逻辑可以用本地 mock channel 测；`DynamicGrpcCaller` 的 status 映射用单测覆盖
5. **提 MR**：`feat: ASAIO-1858 实现 gRPC Reflection 模式 unary 真实调用`

**Stage 2**（前置：Stage 1 已合）：

1. `DESC tb_protocol_file` 确认 `file_content` 字段当前类型，决定是否要先走 DBA 工单调整为 LONGTEXT（设计 §7.1 已提到拟存 `.proto` 源码字符串）
2. 引入嵌入式 protoc（候选 `com.github.os72:protoc-jar:3.11.4`，或纯 Java 解析器 `com.squareup.wire:wire-schema`），跑一次 PoC 确认可行性
3. 新增 `cloud.aisky.protocol.grpc.ProtoFileDescriptorResolver`，签名 `resolve(protoFileId, serviceName, methodName)`，返回 `Descriptors.MethodDescriptor` 后复用 `DynamicGrpcCaller`
4. `GrpcProtocolExecutor` 的 PROTO_FILE 分支：从 `protocolConfig.protoFileId` 取，调 `ProtoFileDescriptorResolver` 接 `DynamicGrpcCaller`
5. 前端独立 MR：`GrpcApiDetail.vue` `discoveryMode=PROTO_FILE` 时显示 proto 文件选择器，调用现有 `ProtocolFileController` 接口
6. 提 MR：`feat: ASAIO-1858 实现 gRPC Proto 文件模式 unary 调用`

**遗留风险**：

- Channel 缓存目前无 TTL / LRU 清理。如果调用方在测试 / 压测中频繁切换 host，缓存会无界增长。设计 §8 已记录该风险，决策是**本轮不动**，等线上有问题再加。Stage 1 / 2 合并后建议持续观察 `channelCache.size()` 的增长趋势。
