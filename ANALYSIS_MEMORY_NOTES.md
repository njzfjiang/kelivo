# Kelivo Analysis / Memory Notes

记录日期：2026-04-22

## 当前目标

这轮实现的目标是给 Kelivo 增加一条旁路分析与外部记忆实验链路：

- 不替换现有 `MemoryProvider`
- 不替换现有 `Conversation.summary`
- 保留当前聊天发送、重试、summary 自动生成行为
- 额外采集每轮实际送模上下文、注入来源、请求响应原文
- 为后续 external memory、rolling summary、memory suggestion 和 benchmark 做数据底座

## 已实现能力

### App 侧分析库

App 侧新增 SQLite 分析库，默认文件名：

```text
analysis_v1.db
```

Windows 当前路径：

```text
%APPDATA%\com.psyche\kelivo\analysis_v1.db
```

当前 app 侧负责：

- 生成 turn id 和 session id
- 保存每轮请求前后的分析记录
- 保存实际注入快照
- 保存注入来源日志
- 保存当前会话 rolling summary 最新状态

核心文件：

- `lib/core/services/analysis/analysis_schema.dart`
- `lib/core/services/analysis/analysis_store.dart`
- `lib/core/services/analysis/analysis_capture_service.dart`
- `lib/core/services/analysis/analysis_protocol.dart`

### Proxy 侧分析库

Proxy 侧默认使用独立 SQLite 文件：

```text
proxy_analysis_v1.db
```

Proxy 侧负责：

- 接收 App 通过 header/body 传来的 `_kelivo_analysis_meta`
- 不把 `_kelivo_analysis_meta` 透传给上游
- 保存脱敏后的 request/response headers
- 保存上游 request/response 原文
- 流式时累积 assistant 最终文本
- 记录 completed/error/cancelled 状态

核心文件：

- `lib/core/services/analysis/proxy_analysis_store.dart`
- `lib/core/services/analysis/kelivo_proxy_server.dart`
- `bin/kelivo_proxy.dart`

启动示例：

```bash
dart run bin/kelivo_proxy.dart --upstream=https://api.openai.com/v1
 --port=8787
```

如果上游是 OpenAI 官方 API，Kelivo provider 的 Base URL 应使用本地 proxy：

```text
http://127.0.0.1:8787
```

Proxy 内部会把请求转发到真实 HTTPS upstream。

### 注入采集

每轮请求会采集：

- system prompt
- assistant memory
- recent chat summary
- instruction injection
- world book trigger
- search prompt
- current chat rolling summary
- context limit 后的消息预览

`inject_log.kind` 目前包括：

- `system_prompt`
- `memory`
- `recent_chat_summary`
- `instruction`
- `world_book`
- `search_prompt`
- `rolling_summary`

注意：`inject_log` 是 turn 级审计日志。看到 `kind=rolling_summary` 只表示那一轮请求注入过 rolling summary，不等于当前打开的 DB 一定有 `rolling_summaries` 状态表。

### 观察工具

新增 CLI：

```bash
dart run bin/analysis_inspect.dart
```

常用示例：

```bash
dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --recent=10
dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --stats --recent=50
dart run bin/analysis_inspect.dart --db-path=proxy_analysis_v1.db --turn-id=<turn_id>
dart run bin/analysis_inspect.dart --app-db --rolling --session-id=<session_id>
dart run bin/analysis_inspect.dart --app-db --summary-versions --session-id=<session_id>
dart run bin/analysis_inspect.dart --app-db --memory-suggestions --session-id=<session_id>
```

`--app-db` 会自动指向 app 侧分析库。Windows 下等价于：

```text
%APPDATA%\com.psyche\kelivo\analysis_v1.db
```

## Rolling Summary 当前设计

Rolling summary 是当前会话连续性功能，不是 cross-chat summary。

现有 `Conversation.summary` 仍然用于跨聊天 recent chats reference。它的特征是：

- 每个 chat 只存一条 summary
- 本 chat 当前 summary 不注入给自己
- 其他 chat 的 summary 可作为 cross-chat reference 注入

新增 rolling summary 的特征是：

- 只服务当前 chat 的上下文连续性
- 存在 app 侧 `rolling_summaries` 表
- 每个 session 只保留最新一版
- 下次同 chat 发送消息时注入到 system 上下文
- 不自动写入长期 memory

当前触发规则：

- 只统计当前会话中 `user` / `assistant` 消息
- 读取上次 `source_last_message_count`
- 当新增可总结消息数达到 `assistant.recentChatsSummaryMessageCount` 后刷新
- 当前测试阈值为 3

这意味着它是“分段刷新摘要”，不是每轮实时刷新。

优点：

- 成本低
- 摘要不容易每轮抖动
- 适合先验证连续性收益

代价：

- 阈值之间的几轮不会立刻进入 rolling summary

核心文件：

- `lib/core/services/analysis/rolling_summary_service.dart`
- `lib/features/home/services/message_builder_service.dart`
- `lib/features/home/services/message_generation_service.dart`
- `lib/features/home/controllers/home_view_model.dart`
- `lib/features/home/controllers/home_page_controller.dart`

## 数据库职责边界

当前建议把三类数据分开，不要让一张表承担所有职责。

### 1. `rolling_summaries`

用途：当前会话运行时连续性缓存。

特点：

- 每个 session 一条
- 只保留最新版本
- 可随策略调整覆盖
- 主要用于注入，不用于审计

### 2. `summary_versions`

用途：保存每一版 summary 的历史证据，用于分析和 benchmark。

当前字段：

```sql
summary_versions:
id, session_id, assistant_id, created_at,
source_from_message_count, source_to_message_count,
summary_text, previous_summary_text, input_excerpt,
prompt_json, provider_key, model_id
```

特点：

- append-only
- 保存每次 summary 生成结果
- 可用于比较不同摘要策略
- 可作为 memory suggestion 的输入来源之一

当前接入状态：

- 每次 rolling summary 刷新时都会写入一条 `summary_versions`
- `rolling_summaries` 仍然只保留 latest
- memory suggestion 还不会自动生成

### 3. `memory_suggestions`

用途：保存从 summary 或 turn delta 中提炼出的长期记忆候选。

当前字段：

```sql
memory_suggestions:
id, session_id, assistant_id, created_at,
updated_at,
source_summary_version_id, source_turn_id,
candidate_text, reason, confidence,
status, review_note, accepted_memory_id,
payload_json
```

建议状态：

```text
pending
accepted
rejected
merged
```

原则：

- 不要直接自动写入长期 memory
- 先作为候选项进入人工审计
- accepted 后再写入现有 memory 系统
- rejected/merged 也要保留，方便后续评估模型提议质量

当前接入状态：

- 表和基础写入接口已存在
- 还没有自动 suggestion 生成器
- 还没有人工审核 UI
- 还不会自动写入现有 assistant memory

## 为什么 memory suggestion 应该 decouple

`rolling_summaries` 更像 runtime cache，而 memory suggestion 更像审计和决策流。

如果混在一起会有问题：

- rolling summary 只保留最新版，会丢历史证据
- 摘要策略调整会污染 memory suggestion 的评估
- 生成失败或覆盖会影响候选记忆追溯
- 后续 benchmark 难以判断是摘要问题、提议问题还是人工审核问题

推荐拆分：

- `rolling_summaries`：保持当前 chat 连续性
- `summary_versions`：记录每一版 summary 历史
- `memory_suggestions`：记录待审计的长期记忆候选

## 已知注意事项

### App DB 和 Proxy DB 不是同一个文件

App DB：

```text
%APPDATA%\com.psyche\kelivo\analysis_v1.db
```

Proxy DB：

```text
<repo>/proxy_analysis_v1.db
```

如果在 Proxy DB 里查 `rolling_summaries`，可能没有这张表。Proxy DB 主要保存 turn 审计数据；app DB 才保存当前 rolling summary 状态。

### `inject_log` 与 `rolling_summaries` 的区别

`inject_log`：

- 每轮请求一组记录
- 表示当时注入了什么
- 是历史审计日志

`rolling_summaries`：

- 每个 session 一条当前状态
- 表示当前最新 rolling summary
- 是运行时缓存

### Recent chat summary 空内容问题

之前观察到 `recent_chat_summary.content_excerpt` 为空，原因是部分旧 chat 没有生成 `Conversation.summary`，但曾被作为 recent chat reference 注入。

当前已调整为只从有 summary 的 conversation 中选取 cross-chat reference。

## 后续建议

## 2026-04-23 Debug 记录

今天主要在 debug，核心结论如下。

### 1. MCP 工具“有没有进请求”要以 DB 为准，不要信模型自述

已经确认：

- `tool_definitions` 会写入 `inject_snapshot_json`
- `mcp_diagnostics` 会写入 `inject_snapshot_json`
- `inject_log.kind=mcp_tools` 会记录 MCP 工具摘要

因此当模型说“我看不到工具”时，先看 turn 级诊断，而不是先信模型。

如果 `mcp_diagnostics` 显示：

- `supports_tools=true`
- `selected_connected_mcp_server_ids` 非空
- `enabled_mcp_tool_names` 非空

那么从 Kelivo 侧看，工具已经被正确放进请求。

### 2. 当前 MCP 工具筛选逻辑

当前实现不是“把所有 server 都塞进去”，而是四层交集：

- assistant 的 `mcpServerIds`
- 当前 `connectedServers`
- `server.enabled == true`
- `tool.enabled == true`

相关路径：

- `lib/features/home/services/tool_handler_service.dart`
- `lib/core/services/mcp/mcp_tool_service.dart`
- `lib/core/providers/mcp_provider.dart`

### 3. 如果模型仍说看不到，很可能是工具集过大

一次性给模型注入太多工具时，模型可能：

- 不敢调用
- 假装自己没有权限
- 优先走文字回答
- 自述与真实能力不一致

当时观察到的工具集已经非常大，包括：

- obsidian
- my-health-data
- filesystem
- chrome-devtools
- playwright
- kelivo_fetch

后续建议优先做最小实验：

- 只保留 1 到 2 个 MCP server
- 发一个强制工具调用的短请求
- 看真实 tool call，而不是看模型的口头描述

### 4. `analysis_inspect` 已增强 MCP 诊断可读性

新增：

- `tool_definitions`
- `mcp_diagnostics`
- `inject_log.kind=mcp_tools`

以及新命令：

```bash
dart run bin/analysis_inspect.dart --app-db --mcp-only --turn-id=<turn_id>
```

用途：

- 只打印某个 turn 的 tool/MCP 诊断
- 避免长 request/response 输出把关键字段淹没

### 5. Proxy 404 的根因是 `/v1` 路径放错位置

Kelivo 对 OpenAI-compatible provider 默认会请求：

```text
<Base URL>/chat/completions
```

因此 proxy 转发时，`--upstream` 是否带 `/v1` 会直接影响上游地址。

推荐：

```bash
dart run bin/kelivo_proxy.dart --upstream=http://127.0.0.1:4000/v1 --port=8787
```

同时 Kelivo provider Base URL 填：

```text
http://127.0.0.1:8787
```

不要两边都带 `/v1`。

### 6. `flutter_tts` 的 format warning 不是源码错误，而是 stale `.dart_tool`

问题现象：

- `dart format .` 报 `package_config.json` 指向不存在的 `Users/psyche`

根因：

- `dependencies/flutter_tts/.dart_tool/package_config.json` 是旧机器生成文件
- 里面残留了另一个用户目录和 Flutter SDK 路径

处理方式：

- 删除该 path dependency 下的 `.dart_tool`
- 重新 `pub get`
- 根 `.gitignore` 已改为递归忽略：

```gitignore
**/.dart_tool/
```

避免 path dependency 自己的 `.dart_tool` 再次污染工作区

## 云 Proxy 与手机端不改代码的边界

问题背景：

- 桌面端可以运行修改后的 Kelivo，因此 app 侧 `AnalysisStore` 和 `RollingSummaryService` 能工作
- 当前苹果手机端无法方便运行本地改代码后的 Kelivo
- 如果手机端只把 Base URL 改成云 proxy，但 app 代码不变，就不会拥有新增的 app 侧 service

关键结论：

- 云 proxy 可以保存请求/响应，也可以做一套 proxy 侧 rolling summary
- 但不改手机端代码时，proxy 拿不到 app 侧完整 `_kelivo_analysis_meta`
- 因此 proxy 不能可靠知道 Kelivo 内部的 memory、world book、instruction、recent chat summary 等真实来源
- Proxy 只能基于 OpenAI-compatible request body 里已经拼好的 `messages` 做反推和追加注入

不改手机端代码时，云 proxy 至少需要解决两个问题：

- Session 识别：每个请求必须能稳定归到同一个 conversation/session
- 注入位置：proxy 必须能安全地把 rolling summary 追加到上游 request 的 system message

可行方案从稳到险：

- 最稳：手机端也升级 Kelivo，继续由 App 生成 `_kelivo_analysis_meta`
- 次稳：如果当前手机端支持自定义 header/body，则手动加固定 `X-Kelivo-Conversation-Id` 或 body metadata
- 可用但粗糙：云 proxy 用 API key、provider endpoint、客户端 IP、model 等组合推断 session
- 不建议：完全不区分 session，只做全局 rolling summary，容易串聊天和串人格

如果真的要云 proxy 维护 rolling summary，建议 proxy 侧新增一条独立链路：

- 从 request body 的 `messages` 里提取最新 user message 和已有 system 上下文
- 用云端 DB 的 `rolling_summaries` / `summary_versions` 维护 proxy-side summary
- 在转发上游前，把 proxy-side rolling summary 注入到 system message
- 完成响应后，用 request/response delta 刷新 proxy-side rolling summary
- 所有 proxy 注入都写入 `inject_log.kind=proxy_rolling_summary`

重要限制：

- 这不是 app 侧真实注入快照
- 这无法知道 world book 具体命中了哪条 entry
- 这无法可靠知道 assistant memory 的真实来源 id
- 如果 session 识别不稳，会有严重串上下文风险

因此推荐路线：

- 本地/桌面实验继续用 app 侧 service，数据最完整
- 云 proxy 先做旁路采集和简单 proxy rolling summary
- 等手机端能升级后，再恢复 App→Proxy metadata 协议作为主路径
- 云 proxy 的 rolling summary 与 app rolling summary 应标记不同 source，不要混为一个事实来源

短期：

- 继续用阈值 3 观察 rolling summary 的连续性收益
- 用 `analysis_inspect --app-db --rolling` 查看当前 summary
- 用 `analysis_inspect --app-db --summary-versions` 查看 summary 版本历史
- 用 `analysis_inspect --db-path=proxy_analysis_v1.db --stats` 看 turn 级注入统计

中期：

- 增加 inspect 命令查看 summary 版本时间线
- 比较不同阈值下的 token 成本和回答连续性
- 实现 memory suggestion 生成器，但只写入 `pending`

长期：

- 从 `summary_versions` 和高价值 turn delta 中提议长期 memory
- 加入人工审核状态流
- accepted 后再写入现有 assistant memory
- 记录 rejected/merged 结果，用于评估 suggestion 模型质量
