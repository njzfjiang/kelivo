import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/instruction_injection.dart';
import '../../../core/models/assistant_memory.dart';
import '../../../core/models/world_book.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/chat/document_text_extractor.dart';
import '../../../core/services/chat/prompt_transformer.dart';
import '../../../core/services/instruction_injection_store.dart';
import '../../../core/services/analysis/rolling_summary_service.dart';
import '../../../core/services/world_book_store.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/providers/instruction_injection_provider.dart';
import '../../../core/providers/world_book_provider.dart';
import '../../../core/services/api/builtin_tools.dart';
import '../../../core/models/assistant_regex.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../utils/assistant_regex.dart';
import '../../../utils/markdown_media_sanitizer.dart';

/// Service for building API messages from conversation state.
///
/// This service handles:
/// - Building API messages list from chat history
/// - Processing user messages (documents, OCR, templates)
/// - Injecting system prompts
/// - Injecting memory and recent chats context
/// - Injecting search prompts
/// - Injecting instruction prompts
/// - Applying context limits
/// - Inlining local images for model context
class MessageBuilderService {
  static const String internalMediaPathsKey = multimodalInternalMediaPathsKey;

  MessageBuilderService({
    required this.chatService,
    required this.contextProvider,
    this.rollingSummaryService,
    this.ocrHandler,
    this.geminiThoughtSignatureHandler,
  });

  final ChatService chatService;

  /// Build context (used for accessing providers via context.read)
  final BuildContext contextProvider;
  final RollingSummaryService? rollingSummaryService;

  /// OCR handler for processing images (optional, injected from home_page)
  final Future<String?> Function(List<String> imagePaths)? ocrHandler;

  /// OCR text wrapper function
  String Function(String ocrText)? ocrTextWrapper;

  /// Handler to append Gemini thought signatures for API calls
  final String Function(ChatMessage message, String content)?
  geminiThoughtSignatureHandler;

  /// Cache for document text extraction to avoid re-reading files on every message
  /// Keyed by path, validated with (modified + size) to avoid stale reuse.
  final Map<String, _DocTextCacheEntry> _docTextCache =
      <String, _DocTextCacheEntry>{};

  /// Collapse message versions to show only selected version per group.
  List<ChatMessage> collapseVersions(
    List<ChatMessage> items,
    Map<String, int> versionSelections,
  ) {
    final Map<String, List<ChatMessage>> byGroup =
        <String, List<ChatMessage>>{};
    final List<String> order = <String>[];

    for (final m in items) {
      final gid = (m.groupId ?? m.id);
      final list = byGroup.putIfAbsent(gid, () {
        order.add(gid);
        return <ChatMessage>[];
      });
      list.add(m);
    }

    // Sort each group by version
    for (final e in byGroup.entries) {
      e.value.sort((a, b) => a.version.compareTo(b.version));
    }

    // Select the appropriate version from each group
    final out = <ChatMessage>[];
    for (final gid in order) {
      final vers = byGroup[gid]!;
      final sel = versionSelections[gid];
      final idx = (sel != null && sel >= 0 && sel < vers.length)
          ? sel
          : (vers.length - 1);
      out.add(vers[idx]);
    }

    return out;
  }

  /// Build API messages list from current conversation state.
  ///
  /// Applies truncation, version collapsing, and strips [image:] / [file:] markers.
  List<Map<String, dynamic>> buildApiMessages({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    bool includeOpenAIToolMessages = false,
  }) {
    final tIndex = currentConversation?.truncateIndex ?? -1;
    final List<ChatMessage> sourceAll =
        (tIndex >= 0 && tIndex <= messages.length)
        ? messages.sublist(tIndex)
        : List.of(messages);
    final List<ChatMessage> source = collapseVersions(
      sourceAll,
      versionSelections,
    );

    final out = <Map<String, dynamic>>[];

    for (final m in source) {
      var handledAssistantContentInToolHistory = false;
      if (includeOpenAIToolMessages && m.role == 'assistant') {
        final events = chatService.getToolEvents(m.id);
        if (events.isNotEmpty) {
          final historyMessages = _buildAssistantToolHistoryMessages(
            message: m,
            events: events,
          );
          if (historyMessages.isNotEmpty) {
            out.addAll(historyMessages);
            handledAssistantContentInToolHistory = historyMessages.any(
              (item) =>
                  item['role'] == 'assistant' &&
                  item['tool_calls'] == null &&
                  (item['content'] ?? '').toString() == m.content,
            );
          }
        }
      }

      var content = m.content;
      if (m.role == 'assistant' && geminiThoughtSignatureHandler != null) {
        content = geminiThoughtSignatureHandler!(m, content);
      }
      if (handledAssistantContentInToolHistory && m.role == 'assistant') {
        continue;
      }
      if (content.isEmpty) continue;
      out.add(<String, dynamic>{
        'role': m.role == 'assistant' ? 'assistant' : 'user',
        'content': content,
      });
    }

    return out;
  }

  List<Map<String, dynamic>> _buildAssistantToolHistoryMessages({
    required ChatMessage message,
    required List<Map<String, dynamic>> events,
  }) {
    final normalizedEvents = <_ToolHistoryEvent>[];
    for (int i = 0; i < events.length; i++) {
      final e = events[i];
      final name = (e['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final rawId = (e['id'] ?? '').toString().trim();
      final id = rawId.isNotEmpty
          ? rawId
          : 'call_${message.id.substring(0, message.id.length < 8 ? message.id.length : 8)}_$i';

      Map<String, dynamic> args = const <String, dynamic>{};
      final a = e['arguments'];
      if (a is Map) {
        args = a.map((k, v) => MapEntry(k.toString(), v));
      }

      String argumentsJson = '{}';
      try {
        argumentsJson = jsonEncode(args);
      } catch (_) {}

      normalizedEvents.add(
        _ToolHistoryEvent(
          id: id,
          name: name,
          arguments: args,
          argumentsJson: argumentsJson,
          content: e['content']?.toString(),
          toolBatchIndex: e['tool_batch_index'] as int?,
          assistantContent: e['assistant_content']?.toString(),
          assistantReasoningContent: e['assistant_reasoning_content']
              ?.toString(),
        ),
      );
    }

    if (normalizedEvents.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final segments = _decodeReasoningSegments(message.reasoningSegmentsJson);
    if (normalizedEvents.any((event) => event.toolBatchIndex != null)) {
      return _buildBatchedToolHistoryMessages(
        message: message,
        events: normalizedEvents,
        segments: segments,
      );
    }
    if (segments.isEmpty) {
      return _buildFallbackToolHistoryMessages(
        message: message,
        events: normalizedEvents,
      );
    }

    final out = <Map<String, dynamic>>[];
    int eventIndex = 0;

    for (int i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final nextBoundary = i < segments.length - 1
          ? segments[i + 1].toolStartIndex.clamp(0, normalizedEvents.length)
          : normalizedEvents.length;
      final segmentToolStart = segment.toolStartIndex.clamp(
        0,
        normalizedEvents.length,
      );

      if (nextBoundary > segmentToolStart) {
        final subEvents = normalizedEvents.sublist(
          segmentToolStart,
          nextBoundary,
        );
        out.add({
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            for (final event in subEvents)
              {
                'id': event.id,
                'type': 'function',
                'function': {
                  'name': event.name,
                  'arguments': event.argumentsJson,
                },
              },
          ],
          if (segment.text.isNotEmpty) 'reasoning_content': segment.text,
        });
        for (final event in subEvents) {
          if (event.content == null) continue;
          out.add({
            'role': 'tool',
            'name': event.name,
            'tool_call_id': event.id,
            'content': event.content!,
          });
        }
        eventIndex = nextBoundary;
        continue;
      }

      if (i == segments.length - 1) {
        final finalContent = message.content;
        if (finalContent.isNotEmpty || segment.text.isNotEmpty) {
          out.add({
            'role': 'assistant',
            'content': finalContent,
            if (segment.text.isNotEmpty) 'reasoning_content': segment.text,
          });
        }
      }
    }

    while (eventIndex < normalizedEvents.length) {
      final event = normalizedEvents[eventIndex];
      out.add({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': event.id,
            'type': 'function',
            'function': {'name': event.name, 'arguments': event.argumentsJson},
          },
        ],
      });
      if (event.content != null) {
        out.add({
          'role': 'tool',
          'name': event.name,
          'tool_call_id': event.id,
          'content': event.content!,
        });
      }
      eventIndex++;
    }

    if (out.isEmpty && message.content.isNotEmpty) {
      out.add({'role': 'assistant', 'content': message.content});
    }

    return out;
  }

  List<Map<String, dynamic>> _buildBatchedToolHistoryMessages({
    required ChatMessage message,
    required List<_ToolHistoryEvent> events,
    required List<_StoredReasoningSegment> segments,
  }) {
    final grouped = <int, List<_ToolHistoryEvent>>{};
    for (final event in events) {
      grouped
          .putIfAbsent(event.toolBatchIndex ?? 0, () => <_ToolHistoryEvent>[])
          .add(event);
    }

    final batchIndexes = grouped.keys.toList()..sort();
    final out = <Map<String, dynamic>>[];
    for (final batchIndex in batchIndexes) {
      final batch = grouped[batchIndex]!;
      final first = batch.first;
      out.add({
        'role': 'assistant',
        'content': first.assistantContent ?? '',
        'tool_calls': [
          for (final event in batch)
            {
              'id': event.id,
              'type': 'function',
              'function': {
                'name': event.name,
                'arguments': event.argumentsJson,
              },
            },
        ],
        if ((first.assistantReasoningContent ?? '').isNotEmpty)
          'reasoning_content': first.assistantReasoningContent,
      });
      for (final event in batch) {
        if (event.content == null) continue;
        out.add({
          'role': 'tool',
          'name': event.name,
          'tool_call_id': event.id,
          'content': event.content!,
        });
      }
    }

    final finalReasoning = _finalAssistantReasoningContent(
      events: events,
      segments: segments,
    );
    if (message.content.isNotEmpty || finalReasoning.isNotEmpty) {
      out.add({
        'role': 'assistant',
        'content': message.content,
        if (finalReasoning.isNotEmpty) 'reasoning_content': finalReasoning,
      });
    }
    return out;
  }

  List<Map<String, dynamic>> _buildFallbackToolHistoryMessages({
    required ChatMessage message,
    required List<_ToolHistoryEvent> events,
  }) {
    final toolMessages = <Map<String, dynamic>>[];
    final calls = <Map<String, dynamic>>[];
    for (final event in events) {
      calls.add({
        'id': event.id,
        'type': 'function',
        'function': {'name': event.name, 'arguments': event.argumentsJson},
      });
      if (event.content != null) {
        toolMessages.add({
          'role': 'tool',
          'name': event.name,
          'tool_call_id': event.id,
          'content': event.content!,
        });
      }
    }

    return <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': calls,
        if ((message.reasoningText ?? '').isNotEmpty)
          'reasoning_content': message.reasoningText,
      },
      ...toolMessages,
      if (message.content.isNotEmpty)
        {'role': 'assistant', 'content': message.content},
    ];
  }

  List<_StoredReasoningSegment> _decodeReasoningSegments(String? json) {
    final raw = (json ?? '').trim();
    if (raw.isEmpty) return const <_StoredReasoningSegment>[];
    try {
      final decoded = jsonDecode(raw);
      final items = decoded is Map<String, dynamic>
          ? (decoded['segments'] as List? ?? const <dynamic>[])
          : decoded as List;
      return items
          .whereType<Map>()
          .map((item) => item.map((k, v) => MapEntry(k.toString(), v)))
          .map(
            (item) => _StoredReasoningSegment(
              text: (item['text'] ?? '').toString(),
              toolStartIndex: (item['toolStartIndex'] as int?) ?? 0,
            ),
          )
          .where((segment) => segment.text.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <_StoredReasoningSegment>[];
    }
  }

  String _finalAssistantReasoningContent({
    required List<_ToolHistoryEvent> events,
    required List<_StoredReasoningSegment> segments,
  }) {
    if (segments.isEmpty) return '';
    final last = segments.last;
    if (last.toolStartIndex >= events.length) {
      return last.text;
    }
    return '';
  }

  /// Parse input data from raw message content (extracts images and documents).
  ChatInputData parseInputFromRaw(String raw) {
    final imgRe = RegExp(r"\[image:(.+?)\]");
    final fileRe = RegExp(r"\[file:(.+?)\|(.+?)\|(.+?)\]");
    final images = <String>[];
    final docs = <DocumentAttachment>[];
    final buffer = StringBuffer();
    int idx = 0;
    while (idx < raw.length) {
      final imgMatch = imgRe.matchAsPrefix(raw, idx);
      final fileMatch = fileRe.matchAsPrefix(raw, idx);
      if (imgMatch != null) {
        final p = imgMatch.group(1)?.trim();
        if (p != null && p.isNotEmpty) images.add(p);
        idx = imgMatch.end;
        continue;
      }
      if (fileMatch != null) {
        final path = fileMatch.group(1)?.trim() ?? '';
        final name = fileMatch.group(2)?.trim() ?? 'file';
        final mime = fileMatch.group(3)?.trim() ?? 'text/plain';
        final doc = DocumentAttachment(path: path, fileName: name, mime: mime);
        docs.add(doc);
        // Treat media attachments as image-style attachments for downstream API builders.
        final effectiveMime = _effectiveAttachmentMime(doc);
        if ((isVideoMime(effectiveMime) || isAudioMime(effectiveMime)) &&
            path.isNotEmpty) {
          images.add(path);
        }
        idx = fileMatch.end;
        continue;
      }
      buffer.write(raw[idx]);
      idx++;
    }
    return ChatInputData(
      text: buffer.toString().trim(),
      imagePaths: images,
      documents: docs,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  @visibleForTesting
  static bool isDocumentExtractionFailureText(String? text) {
    final normalized = (text ?? '').trim();
    if (normalized.isEmpty) return true;
    return normalized == '[PDF] Unable to extract text from file.' ||
        normalized.startsWith('[[') ||
        normalized.startsWith('[DOCX]');
  }

  /// Process user messages in apiMessages: extract documents, apply OCR, inject file prompts.
  ///
  /// Returns the image paths from the last user message (for API call).
  Future<List<String>> processUserMessagesForApi(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    Assistant? assistant,
  ) async {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    List<String>? lastUserImagePaths;

    // Find last user message index
    int lastUserIdx = -1;
    for (int i = apiMessages.length - 1; i >= 0; i--) {
      if (apiMessages[i]['role'] == 'user') {
        lastUserIdx = i;
        break;
      }
    }

    Future<String?> readDocument(DocumentAttachment d) async {
      // Use file stat to detect content changes without hashing.
      FileStat? stat;
      try {
        stat = await File(d.path).stat();
      } catch (_) {
        stat = null;
      }
      if (stat != null) {
        final cached = _docTextCache[d.path];
        if (cached != null &&
            cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
            cached.size == stat.size) {
          return cached.text;
        }
      }
      try {
        final text = await DocumentTextExtractor.extract(
          path: d.path,
          mime: d.mime,
        );
        final extractedText = isDocumentExtractionFailureText(text)
            ? null
            : text;
        // Cache only when stat is available; otherwise avoid staleness.
        if (stat != null) {
          _docTextCache[d.path] = _DocTextCacheEntry(
            text: extractedText,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return extractedText;
      } catch (_) {
        if (stat != null) {
          _docTextCache[d.path] = _DocTextCacheEntry(
            text: null,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          );
        }
        return null;
      }
    }

    for (int i = 0; i < apiMessages.length; i++) {
      if (apiMessages[i]['role'] != 'user') continue;
      final rawUser = (apiMessages[i]['content'] ?? '').toString();
      final parsedUser = parseInputFromRaw(rawUser);
      final videoPaths = <String>{
        for (final d in parsedUser.documents)
          if (isVideoMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);
      final audioPaths = <String>{
        for (final d in parsedUser.documents)
          if (isAudioMime(_effectiveAttachmentMime(d))) d.path.trim(),
      }..removeWhere((p) => p.isEmpty);

      final messageMediaPaths = parsedUser.imagePaths
          .map((p) => p.trim())
          .where(
            (p) =>
                p.isNotEmpty &&
                (!ocrActive ||
                    videoPaths.contains(p) ||
                    audioPaths.contains(p)),
          )
          .toSet()
          .toList(growable: false);
      if (messageMediaPaths.isEmpty) {
        apiMessages[i].remove(internalMediaPathsKey);
      } else {
        apiMessages[i][internalMediaPathsKey] = messageMediaPaths;
      }

      // Capture image paths from last user message
      if (i == lastUserIdx &&
          lastUserImagePaths == null &&
          parsedUser.imagePaths.isNotEmpty) {
        lastUserImagePaths = List<String>.of(parsedUser.imagePaths);
      }

      final inlineImagePaths = parsedUser.imagePaths
          .map((p) => p.trim())
          .where(
            (p) =>
                p.isNotEmpty &&
                !videoPaths.contains(p) &&
                !audioPaths.contains(p),
          )
          .toList(growable: false);

      // Apply replace-only regexes at send-time on user text (exclude markers).
      final replacedUserText = applyAssistantRegexes(
        parsedUser.text,
        assistant: assistant,
        scope: AssistantRegexScope.user,
        target: AssistantRegexTransformTarget.send,
      );

      final imageMarkers = (!ocrActive && inlineImagePaths.isNotEmpty)
          ? inlineImagePaths.map((p) => '\n[image:$p]').join()
          : '';
      final cleanedUser = (replacedUserText + imageMarkers).trim();

      final filePrompts = StringBuffer();
      for (final d in parsedUser.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) || isAudioMime(effectiveMime)) {
          continue;
        }
        final text = await readDocument(d);
        if (text == null || text.trim().isEmpty) continue;
        filePrompts.writeln('## user sent a file: ${d.fileName}');
        filePrompts.writeln('<content>');
        filePrompts.writeln('```');
        filePrompts.writeln(text);
        filePrompts.writeln('```');
        filePrompts.writeln('</content>');
        filePrompts.writeln();
      }

      String merged = (filePrompts.toString() + cleanedUser).trim();

      if (ocrActive && ocrHandler != null) {
        final ocrTargets = parsedUser.imagePaths
            .map((p) => p.trim())
            .where(
              (p) =>
                  p.isNotEmpty &&
                  !videoPaths.contains(p) &&
                  !audioPaths.contains(p),
            )
            .toSet()
            .toList();
        if (ocrTargets.isNotEmpty) {
          final ocrText = await ocrHandler!(ocrTargets);
          if (ocrText != null && ocrText.trim().isNotEmpty) {
            final wrapped = ocrTextWrapper != null
                ? ocrTextWrapper!(ocrText)
                : _defaultWrapOcrBlock(ocrText);
            merged = (wrapped + merged).trim();
          }
        }
      }

      apiMessages[i]['content'] = merged.isEmpty ? cleanedUser : merged;
    }

    // Apply message template to last user message
    if (lastUserIdx != -1) {
      final userText = (apiMessages[lastUserIdx]['content'] ?? '').toString();
      final templ =
          (assistant?.messageTemplate ?? '{{ message }}').trim().isEmpty
          ? '{{ message }}'
          : (assistant!.messageTemplate);
      final templated = PromptTransformer.applyMessageTemplate(
        templ,
        role: 'user',
        message: userText,
        now: DateTime.now(),
      );
      apiMessages[lastUserIdx]['content'] = templated;
    }

    return lastUserImagePaths ?? <String>[];
  }

  /// Default OCR text wrapper
  String _defaultWrapOcrBlock(String ocrText) {
    final buf = StringBuffer();
    buf.writeln(
      "The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.",
    );
    buf.writeln('<image_file_ocr>');
    buf.writeln(ocrText.trim());
    buf.writeln('</image_file_ocr>');
    buf.writeln();
    return buf.toString();
  }

  /// Inject system prompt into apiMessages.
  String? injectSystemPrompt(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
    String modelId,
  ) {
    if ((assistant?.systemPrompt.trim().isNotEmpty ?? false)) {
      final vars = PromptTransformer.buildPlaceholders(
        context: contextProvider,
        assistant: assistant!,
        modelId: modelId,
        modelName: modelId,
        userNickname: contextProvider.read<UserProvider>().name,
      );
      final sys = PromptTransformer.replacePlaceholders(
        assistant.systemPrompt,
        vars,
      );
      apiMessages.insert(0, {'role': 'system', 'content': sys});
      return sys;
    }
    return null;
  }

  /// Inject memory prompts and recent chats reference into apiMessages.
  Future<MemoryAndRecentChatsInjectionCapture> injectMemoryAndRecentChats(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant, {
    String? currentConversationId,
  }) async {
    final memoryRecords = <Map<String, dynamic>>[];
    final recentChatSummaries = <Map<String, dynamic>>[];
    Map<String, dynamic>? rollingSummary;
    try {
      if (assistant?.enableMemory == true) {
        final mp = contextProvider.read<MemoryProvider>();
        await mp.initialize();
        final mems = mp.getForAssistant(assistant!.id);
        final buf = StringBuffer();
        buf.writeln('## Memories');
        buf.writeln(
          'These are memories that you can reference in the future conversations.',
        );
        buf.writeln('<memories>');
        for (final m in mems) {
          memoryRecords.add(_memoryRecordToJson(m));
          buf.writeln('<record>');
          buf.writeln('<id>${m.id}</id>');
          buf.writeln('<content>${m.content}</content>');
          buf.writeln('</record>');
        }
        buf.writeln('</memories>');
        buf.writeln('''
## Memory Tool
你是一个无状态的大模型，你无法存储记忆，因此为了记住信息，你需要使用**记忆工具**。
你可以使用 `create_memory`, `edit_memory`, `delete_memory` 工具创建、更新或删除记忆。
- 如果记忆中没有相关信息，请使用 create_memory 创建一条新的记录。
- 如果已有相关记录，请使用 edit_memory 更新内容。
- 若记忆过时或无用，请使用 delete_memory 删除。
这些记忆会自动包含在未来的对话上下文中，在<memories>标签内。
请勿在记忆中存储敏感信息，敏感信息包括：用户的民族、宗教信仰、性取向、政治观点及党派归属、性生活、犯罪记录等。
在与用户聊天过程中，你可以像一个私人秘书一样**主动的**记录用户相关的信息到记忆里，包括但不限于：
- 用户昵称/姓名
- 年龄/性别/兴趣爱好
- 计划事项等
- 聊天风格偏好
- 工作相关
- 首次聊天时间
- ...
请主动调用工具记录，而不是需要用户要求。
记忆如果包含日期信息，请包含在内，请使用绝对时间格式，并且当前时间是 ${DateTime.now().toIso8601String()}。
无需告知用户你已更改记忆记录，也不要在对话中直接显示记忆内容，除非用户主动要求。
相似或相关的记忆应合并为一条记录，而不要重复记录，过时记录应删除。
你可以在和用户闲聊的时候暗示用户你能记住东西。
''');
        _appendToSystemMessage(apiMessages, buf.toString());
      }
      if (assistant?.enableRecentChatsReference == true) {
        final relevantChats = chatService
            .getConversationsWithSummaryForAssistant(assistant!.id)
            .where((c) => c.id != currentConversationId)
            .take(10)
            .toList();
        if (relevantChats.isNotEmpty) {
          final sb = StringBuffer();
          sb.writeln('<recent_chats>');
          sb.writeln('这是用户最近的一些对话标题和摘要，你可以参考这些内容了解用户偏好和关注点');
          for (final c in relevantChats) {
            recentChatSummaries.add({
              'id': c.id,
              'title': c.title,
              'updated_at': c.updatedAt.toIso8601String(),
              'summary': c.summary,
            });
            sb.writeln('<conversation>');
            // Format: timestamp: title || summary
            final timestamp = c.updatedAt.toIso8601String().substring(0, 10);
            final title = c.title.trim();
            final summary = (c.summary ?? '').trim();
            if (summary.isNotEmpty) {
              sb.writeln('  $timestamp: $title || $summary');
            } else {
              sb.writeln('  $timestamp: $title');
            }
            sb.writeln('</conversation>');
          }
          sb.writeln('</recent_chats>');
          _appendToSystemMessage(apiMessages, sb.toString());
        }
      }
      if (currentConversationId != null &&
          currentConversationId.trim().isNotEmpty &&
          rollingSummaryService != null) {
        final latestRollingSummary = await rollingSummaryService!.getLatest(
          currentConversationId,
        );
        final summaryText = (latestRollingSummary?['summary_text'] ?? '')
            .toString()
            .trim();
        if (summaryText.isNotEmpty) {
          rollingSummary = latestRollingSummary;
          _appendToSystemMessage(apiMessages, '''
<current_chat_rolling_summary>
This is the latest working summary for the current conversation. Use it to preserve continuity after context trimming.
$summaryText
</current_chat_rolling_summary>
''');
        }
      }
    } catch (_) {}
    return MemoryAndRecentChatsInjectionCapture(
      memoryRecords: memoryRecords,
      recentChatSummaries: recentChatSummaries,
      rollingSummary: rollingSummary,
    );
  }

  /// Inject search tool usage prompt into apiMessages.
  String? injectSearchPrompt(
    List<Map<String, dynamic>> apiMessages,
    SettingsProvider settings,
    bool hasBuiltInSearch,
  ) {
    if (settings.searchEnabled && !hasBuiltInSearch) {
      final prompt = SearchToolService.getSystemPrompt();
      _appendToSystemMessage(apiMessages, prompt);
      return prompt;
    }
    return null;
  }

  /// Inject instruction injection prompts into apiMessages.
  Future<List<Map<String, dynamic>>> injectInstructionPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<InstructionInjection> actives = const <InstructionInjection>[];
      try {
        final ip = contextProvider.read<InstructionInjectionProvider>();
        actives = ip.activesFor(assistantId);
        if (actives.isEmpty) {
          actives = await InstructionInjectionStore.getActives(
            assistantId: assistantId,
          );
        }
      } catch (_) {
        actives = await InstructionInjectionStore.getActives(
          assistantId: assistantId,
        );
      }
      final prompts = actives
          .map((e) => e.prompt.trim())
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (prompts.isNotEmpty) {
        final lp = prompts.join('\n\n');
        _appendToSystemMessage(apiMessages, lp);
      }
      return actives.map(_instructionToJson).toList(growable: false);
    } catch (_) {}
    return const <Map<String, dynamic>>[];
  }

  /// Inject world book (lorebook) entries into apiMessages.
  Future<List<Map<String, dynamic>>> injectWorldBookPrompts(
    List<Map<String, dynamic>> apiMessages,
    String? assistantId,
  ) async {
    try {
      List<WorldBook> all = const <WorldBook>[];
      List<String> activeBookIds = const <String>[];

      try {
        final wb = contextProvider.read<WorldBookProvider>();
        all = wb.books;
        activeBookIds = wb.activeBookIdsFor(assistantId);
        if (all.isEmpty) all = await WorldBookStore.getAll();
        if (activeBookIds.isEmpty) {
          activeBookIds = await WorldBookStore.getActiveIds(
            assistantId: assistantId,
          );
        }
      } catch (_) {
        all = await WorldBookStore.getAll();
        activeBookIds = await WorldBookStore.getActiveIds(
          assistantId: assistantId,
        );
      }

      if (all.isEmpty || activeBookIds.isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final activeSet = activeBookIds.toSet();
      final books = all
          .where((b) => b.enabled && activeSet.contains(b.id))
          .toList(growable: false);
      if (books.isEmpty) return const <Map<String, dynamic>>[];

      String extractContextForDepth(int scanDepth) {
        final depth = scanDepth <= 0 ? 1 : scanDepth;
        final parts = <String>[];
        for (
          int i = apiMessages.length - 1;
          i >= 0 && parts.length < depth;
          i--
        ) {
          final role = (apiMessages[i]['role'] ?? '').toString();
          if (role != 'user' && role != 'assistant') continue;
          final content = (apiMessages[i]['content'] ?? '').toString().trim();
          if (content.isEmpty) continue;
          parts.add(content);
        }
        return parts.reversed.join('\n');
      }

      bool isTriggered(WorldBookEntry entry, String context) {
        if (!entry.enabled) return false;
        if (entry.constantActive) return true;
        if (entry.keywords.isEmpty) return false;

        for (final raw in entry.keywords) {
          final keyword = raw.trim();
          if (keyword.isEmpty) continue;

          if (entry.useRegex) {
            try {
              final re = RegExp(keyword, caseSensitive: entry.caseSensitive);
              if (re.hasMatch(context)) return true;
            } catch (_) {}
          } else {
            if (entry.caseSensitive) {
              if (context.contains(keyword)) return true;
            } else {
              if (context.toLowerCase().contains(keyword.toLowerCase())) {
                return true;
              }
            }
          }
        }
        return false;
      }

      final contextCache = <int, String>{};
      final triggered = <({WorldBook book, WorldBookEntry entry, int seq})>[];
      int seq = 0;

      for (final book in books) {
        for (final entry in book.entries) {
          final depth = (entry.scanDepth <= 0 ? 1 : entry.scanDepth)
              .clamp(1, 200)
              .toInt();
          final ctx = contextCache.putIfAbsent(
            depth,
            () => extractContextForDepth(depth),
          );
          if (isTriggered(entry, ctx)) {
            triggered.add((book: book, entry: entry, seq: seq));
          }
          seq++;
        }
      }

      if (triggered.isEmpty) return const <Map<String, dynamic>>[];

      triggered.sort((a, b) {
        final pa = a.entry.priority;
        final pb = b.entry.priority;
        if (pb != pa) return pb.compareTo(pa);
        return a.seq.compareTo(b.seq);
      });

      String wrapSystemTag(String content) => '<system>\n$content\n</system>';

      String joinContents(Iterable<WorldBookEntry> items) {
        return items
            .map((e) => e.content.trim())
            .where((c) => c.isNotEmpty)
            .join('\n');
      }

      List<Map<String, dynamic>> createMergedInjectionMessages(
        List<WorldBookEntry> injections,
      ) {
        final byRole = <WorldBookInjectionRole, List<WorldBookEntry>>{};
        for (final e in injections) {
          if (e.content.trim().isEmpty) continue;
          byRole.putIfAbsent(e.role, () => <WorldBookEntry>[]).add(e);
        }

        final result = <Map<String, dynamic>>[];
        for (final role in byRole.keys) {
          final group = byRole[role]!;
          final merged = joinContents(group);
          if (merged.isEmpty) continue;
          if (role == WorldBookInjectionRole.assistant) {
            result.add({'role': 'assistant', 'content': merged});
          } else {
            result.add({'role': 'user', 'content': wrapSystemTag(merged)});
          }
        }
        return result;
      }

      int findSafeInsertIndex(List<Map<String, dynamic>> messages, int target) {
        var index = target.clamp(0, messages.length);
        while (index > 0 && index < messages.length) {
          final role = (messages[index]['role'] ?? '').toString();
          if (role != 'tool') break;
          index--;
        }
        return index;
      }

      final byPosition = <WorldBookInjectionPosition, List<WorldBookEntry>>{};
      for (final t in triggered) {
        byPosition
            .putIfAbsent(t.entry.position, () => <WorldBookEntry>[])
            .add(t.entry);
      }

      // BEFORE/AFTER_SYSTEM_PROMPT: merge into system message.
      final beforeContent = joinContents(
        byPosition[WorldBookInjectionPosition.beforeSystemPrompt] ??
            const <WorldBookEntry>[],
      );
      final afterContent = joinContents(
        byPosition[WorldBookInjectionPosition.afterSystemPrompt] ??
            const <WorldBookEntry>[],
      );

      if (beforeContent.isNotEmpty || afterContent.isNotEmpty) {
        final systemIndex = apiMessages.indexWhere(
          (m) => (m['role'] ?? '').toString() == 'system',
        );
        if (systemIndex >= 0) {
          final original = (apiMessages[systemIndex]['content'] ?? '')
              .toString();
          final sb = StringBuffer();
          if (beforeContent.isNotEmpty) {
            sb.write(beforeContent);
            sb.write('\n');
          }
          sb.write(original);
          if (afterContent.isNotEmpty) {
            sb.write('\n');
            sb.write(afterContent);
          }
          apiMessages[systemIndex]['content'] = sb.toString();
        } else {
          final sb = StringBuffer();
          if (beforeContent.isNotEmpty) sb.write(beforeContent);
          if (afterContent.isNotEmpty) {
            if (sb.isNotEmpty) sb.write('\n');
            sb.write(afterContent);
          }
          if (sb.isNotEmpty) {
            apiMessages.insert(0, {'role': 'system', 'content': sb.toString()});
          }
        }
      }

      // TOP_OF_CHAT: insert before first user message.
      final topInjections = byPosition[WorldBookInjectionPosition.topOfChat];
      if (topInjections != null && topInjections.isNotEmpty) {
        var insertIndex = apiMessages.indexWhere(
          (m) => (m['role'] ?? '').toString() == 'user',
        );
        if (insertIndex < 0) insertIndex = apiMessages.length;
        insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
        apiMessages.insertAll(
          insertIndex,
          createMergedInjectionMessages(topInjections),
        );
      }

      // BOTTOM_OF_CHAT: insert before last message.
      final bottomInjections =
          byPosition[WorldBookInjectionPosition.bottomOfChat];
      if (bottomInjections != null && bottomInjections.isNotEmpty) {
        var insertIndex = apiMessages.isEmpty ? 0 : (apiMessages.length - 1);
        insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
        apiMessages.insertAll(
          insertIndex,
          createMergedInjectionMessages(bottomInjections),
        );
      }

      // AT_DEPTH: insert at depth from end (depth=1 means before last message).
      final atDepthInjections = byPosition[WorldBookInjectionPosition.atDepth];
      if (atDepthInjections != null && atDepthInjections.isNotEmpty) {
        final byDepth = <int, List<WorldBookEntry>>{};
        for (final e in atDepthInjections) {
          final depth = (e.injectDepth <= 0 ? 1 : e.injectDepth)
              .clamp(1, 200)
              .toInt();
          byDepth.putIfAbsent(depth, () => <WorldBookEntry>[]).add(e);
        }

        final depths = byDepth.keys.toList(growable: false)
          ..sort((a, b) => b.compareTo(a));

        for (final depth in depths) {
          final injections = byDepth[depth] ?? const <WorldBookEntry>[];
          var insertIndex = (apiMessages.length - depth).clamp(
            0,
            apiMessages.length,
          );
          insertIndex = findSafeInsertIndex(apiMessages, insertIndex);
          apiMessages.insertAll(
            insertIndex,
            createMergedInjectionMessages(injections),
          );
        }
      }
      return triggered
          .map((t) => _worldBookEntryToJson(t.book, t.entry))
          .toList(growable: false);
    } catch (_) {}
    return const <Map<String, dynamic>>[];
  }

  /// Helper to append content to the system message (or create one if missing).
  void _appendToSystemMessage(
    List<Map<String, dynamic>> apiMessages,
    String content,
  ) {
    if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
      apiMessages[0]['content'] =
          '${(apiMessages[0]['content'] ?? '') as String}\n\n$content';
    } else {
      apiMessages.insert(0, {'role': 'system', 'content': content});
    }
  }

  /// Apply context message limit based on assistant settings.
  Map<String, dynamic> applyContextLimit(
    List<Map<String, dynamic>> apiMessages,
    Assistant? assistant,
  ) {
    final beforeCount = apiMessages.length;
    final keptMessages = <Map<String, dynamic>>[];
    if ((assistant?.limitContextMessages ?? true) &&
        (assistant?.contextMessageSize ?? 0) > 0) {
      final int keep = (assistant!.contextMessageSize).clamp(
        Assistant.minContextMessageSize,
        Assistant.maxContextMessageSize,
      );
      int startIdx = 0;
      if (apiMessages.isNotEmpty && apiMessages.first['role'] == 'system') {
        startIdx = 1;
      }
      final tail = apiMessages.sublist(startIdx);
      if (tail.length > keep) {
        final trimmed = tail.sublist(tail.length - keep);
        apiMessages
          ..removeRange(startIdx, apiMessages.length)
          ..addAll(trimmed);
        keptMessages
          ..clear()
          ..addAll(trimmed);
      }
      // Context trimming can cut in the middle of a tool-call triplet; avoid sending dangling tool messages.
      while (apiMessages.length > startIdx &&
          (apiMessages[startIdx]['role'] ?? '').toString() == 'tool') {
        apiMessages.removeAt(startIdx);
      }
      return {
        'applied': true,
        'requested_keep': keep,
        'before_count': beforeCount,
        'after_count': apiMessages.length,
        'system_preserved': startIdx == 1,
        'trimmed': apiMessages.length < beforeCount,
        'kept_preview': (keptMessages.isEmpty ? apiMessages : keptMessages)
            .map(_previewMessage)
            .toList(growable: false),
      };
    }
    return {
      'applied': false,
      'before_count': beforeCount,
      'after_count': apiMessages.length,
      'system_preserved':
          apiMessages.isNotEmpty &&
          (apiMessages.first['role'] ?? '').toString() == 'system',
      'trimmed': false,
      'kept_preview': apiMessages.map(_previewMessage).toList(growable: false),
    };
  }

  /// Convert local Markdown image links to inline base64 for model context.
  Future<void> inlineLocalImages(List<Map<String, dynamic>> apiMessages) async {
    for (int i = 0; i < apiMessages.length; i++) {
      final s = (apiMessages[i]['content'] ?? '').toString();
      if (s.isNotEmpty) {
        apiMessages[i]['content'] =
            await MarkdownMediaSanitizer.inlineLocalImagesToBase64(s);
      }
    }
  }

  /// Check if built-in search is enabled for the given provider/model.
  bool hasBuiltInSearch(
    SettingsProvider settings,
    String providerKey,
    String modelId,
  ) {
    try {
      final cfg = settings.getProviderConfig(providerKey);
      return BuiltInToolsHelper.isBuiltInSearchEnabled(
        cfg: cfg,
        modelId: modelId,
      );
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> _memoryRecordToJson(AssistantMemory memory) => {
    'id': memory.id,
    'assistant_id': memory.assistantId,
    'content': memory.content,
  };

  Map<String, dynamic> _instructionToJson(InstructionInjection injection) => {
    'id': injection.id,
    'title': injection.title,
    'prompt': injection.prompt,
    'group': injection.group,
  };

  Map<String, dynamic> _worldBookEntryToJson(
    WorldBook book,
    WorldBookEntry entry,
  ) => {
    'book_id': book.id,
    'book_name': book.name,
    'entry_id': entry.id,
    'entry_name': entry.name,
    'content': entry.content,
    'priority': entry.priority,
    'position': entry.position.toJson(),
    'role': entry.role.toJson(),
    'inject_depth': entry.injectDepth,
    'scan_depth': entry.scanDepth,
    'constant_active': entry.constantActive,
  };

  static Map<String, dynamic> _previewMessage(Map<String, dynamic> message) => {
    'role': (message['role'] ?? '').toString(),
    'content': _excerpt((message['content'] ?? '').toString()),
  };

  static String _excerpt(String value, {int maxLength = 200}) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }
}

class _DocTextCacheEntry {
  const _DocTextCacheEntry({
    required this.text,
    required this.modifiedMs,
    required this.size,
  });

  final String? text;
  final int modifiedMs;
  final int size;
}

class _ToolHistoryEvent {
  const _ToolHistoryEvent({
    required this.id,
    required this.name,
    required this.arguments,
    required this.argumentsJson,
    required this.content,
    this.toolBatchIndex,
    this.assistantContent,
    this.assistantReasoningContent,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String argumentsJson;
  final String? content;
  final int? toolBatchIndex;
  final String? assistantContent;
  final String? assistantReasoningContent;
}

class _StoredReasoningSegment {
  const _StoredReasoningSegment({
    required this.text,
    required this.toolStartIndex,
  });

  final String text;
  final int toolStartIndex;
}

class MemoryAndRecentChatsInjectionCapture {
  const MemoryAndRecentChatsInjectionCapture({
    this.memoryRecords = const <Map<String, dynamic>>[],
    this.recentChatSummaries = const <Map<String, dynamic>>[],
    this.rollingSummary,
  });

  final List<Map<String, dynamic>> memoryRecords;
  final List<Map<String, dynamic>> recentChatSummaries;
  final Map<String, dynamic>? rollingSummary;
}
