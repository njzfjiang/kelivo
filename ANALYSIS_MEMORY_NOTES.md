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
dart run bin/kelivo_proxy.dart --upstream=https://api.openai.com --port=8787
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

### 2. 未来 `summary_versions`

用途：保存每一版 summary 的历史证据，用于分析和 benchmark。

建议字段：

```sql
summary_versions:
id, session_id, assistant_id, created_at,
source_from_message_count, source_to_message_count,
summary_text, prompt_json, provider_key, model_id
```

特点：

- append-only
- 保存每次 summary 生成结果
- 可用于比较不同摘要策略
- 可作为 memory suggestion 的输入来源之一

### 3. 未来 `memory_suggestions`

用途：保存从 summary 或 turn delta 中提炼出的长期记忆候选。

建议字段：

```sql
memory_suggestions:
id, session_id, assistant_id, created_at,
source_summary_version_id, source_turn_id,
candidate_text, reason, confidence,
status, review_note, accepted_memory_id
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

短期：

- 继续用阈值 3 观察 rolling summary 的连续性收益
- 用 `analysis_inspect --app-db --rolling` 查看当前 summary
- 用 `analysis_inspect --db-path=proxy_analysis_v1.db --stats` 看 turn 级注入统计

中期：

- 新增 `summary_versions`，每次 rolling summary 更新时 append 一版
- 增加 inspect 命令查看 summary 版本时间线
- 比较不同阈值下的 token 成本和回答连续性

长期：

- 新增 `memory_suggestions`
- 从 `summary_versions` 和高价值 turn delta 中提议长期 memory
- 加入人工审核状态流
- accepted 后再写入现有 assistant memory
- 记录 rejected/merged 结果，用于评估 suggestion 模型质量

