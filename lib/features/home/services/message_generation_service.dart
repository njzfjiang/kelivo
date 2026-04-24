import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../../core/models/assistant.dart';
import '../../../core/services/analysis/analysis_capture_service.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/model_override_payload_parser.dart';
import '../../../core/utils/multimodal_input_utils.dart';
import '../../../core/utils/openai_model_compat.dart';
import '../../../utils/assistant_regex.dart';
import '../../../core/models/assistant_regex.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import '../controllers/generation_controller.dart';
import 'message_builder_service.dart';
import 'tool_approval_service.dart';

/// Callback types for UI updates from MessageGenerationService
typedef OnMessagesChanged = void Function();
typedef OnConversationLoadingChanged =
    void Function(String conversationId, bool loading);
typedef OnScrollToBottom = void Function();
typedef OnShowError = void Function(String message);
typedef OnShowWarning = void Function(String message);
typedef OnHapticFeedback = void Function();

const String conversationIdHeaderName = 'X-Conversation-Id';
const String _conversationIdHeaderNameLower = 'x-conversation-id';

Map<String, String>? buildConversationRequestHeaders({
  required String conversationId,
  Map<String, String>? customHeaders,
}) {
  final headers = <String, String>{
    if (customHeaders != null)
      for (final entry in customHeaders.entries)
        if (entry.key.toLowerCase() != _conversationIdHeaderNameLower)
          entry.key: entry.value,
  };
  final normalizedConversationId = conversationId.trim();
  if (normalizedConversationId.isNotEmpty) {
    headers[conversationIdHeaderName] = normalizedConversationId;
  }
  return headers.isEmpty ? null : headers;
}

/// Result of preparing a message generation
class PreparedGeneration {
  final List<Map<String, dynamic>> apiMessages;
  final List<Map<String, dynamic>> toolDefs;
  final Map<String, dynamic> mcpDiagnostics;
  final Future<String> Function(String, Map<String, dynamic>)? onToolCall;
  final bool hasBuiltInSearch;
  final List<String> lastUserImagePaths;
  final String? systemPrompt;
  final List<Map<String, dynamic>> memoryRecords;
  final List<Map<String, dynamic>> recentChatSummaries;
  final Map<String, dynamic>? rollingSummary;
  final List<Map<String, dynamic>> instructionPrompts;
  final List<Map<String, dynamic>> worldBookEntries;
  final String? searchPrompt;
  final Map<String, dynamic> contextLimit;

  PreparedGeneration({
    required this.apiMessages,
    required this.toolDefs,
    this.mcpDiagnostics = const <String, dynamic>{},
    this.onToolCall,
    required this.hasBuiltInSearch,
    required this.lastUserImagePaths,
    this.systemPrompt,
    this.memoryRecords = const <Map<String, dynamic>>[],
    this.recentChatSummaries = const <Map<String, dynamic>>[],
    this.rollingSummary,
    this.instructionPrompts = const <Map<String, dynamic>>[],
    this.worldBookEntries = const <Map<String, dynamic>>[],
    this.searchPrompt,
    this.contextLimit = const <String, dynamic>{},
  });
}

/// Service for handling message generation orchestration.
///
/// This service coordinates:
/// - Message creation (user + assistant placeholder)
/// - API message preparation with all injections
/// - Stream execution and management
/// - Reasoning state initialization
///
/// UI updates are communicated through callbacks to maintain separation.
class MessageGenerationService {
  MessageGenerationService({
    required this.chatService,
    required this.messageBuilderService,
    required this.generationController,
    required this.streamController,
    required this.contextProvider,
    required this.analysisCaptureService,
  });

  final ChatService chatService;
  final MessageBuilderService messageBuilderService;
  final GenerationController generationController;
  final stream_ctrl.StreamController streamController;
  final BuildContext contextProvider;
  final AnalysisCaptureService analysisCaptureService;

  // Callbacks for UI updates (set by home_page)
  OnMessagesChanged? onMessagesChanged;
  OnConversationLoadingChanged? onConversationLoadingChanged;
  OnScrollToBottom? onScrollToBottom;
  OnShowError? onShowError;
  OnShowWarning? onShowWarning;
  OnHapticFeedback? onHapticFeedback;

  /// Called when file processing starts.
  VoidCallback? onFileProcessingStarted;

  /// Called when file processing finishes.
  VoidCallback? onFileProcessingFinished;

  /// Check if reasoning is enabled for given budget
  bool isReasoningEnabled(int? budget) {
    if (budget == null) return true;
    if (budget == -1) return true;
    return budget >= 1024;
  }

  /// Prepare API messages with all injections applied.
  Future<PreparedGeneration> prepareApiMessagesWithInjections({
    required List<ChatMessage> messages,
    required Map<String, int> versionSelections,
    required Conversation? currentConversation,
    required SettingsProvider settings,
    required Assistant? assistant,
    required String? assistantId,
    required String providerKey,
    required String modelId,
    ToolApprovalService? approvalService,
  }) async {
    final cfg = settings.getProviderConfig(providerKey);
    final kind = ProviderConfig.classify(
      providerKey,
      explicitType: cfg.providerType,
    );
    final includeOpenAIToolMessages = kind == ProviderKind.openai;

    onFileProcessingStarted?.call();

    // Build API messages
    final apiMessages = messageBuilderService.buildApiMessages(
      messages: messages,
      versionSelections: versionSelections,
      currentConversation: currentConversation,
      includeOpenAIToolMessages: includeOpenAIToolMessages,
    );

    // Apply assistant replace-only regexes at send-time (visual stays unchanged).
    if (assistant != null && assistant.regexRules.isNotEmpty) {
      for (int i = 0; i < apiMessages.length; i++) {
        final role = (apiMessages[i]['role'] ?? '').toString();
        if (role != 'assistant') continue;
        final raw = (apiMessages[i]['content'] ?? '').toString();
        if (raw.isEmpty) continue;
        apiMessages[i]['content'] = applyAssistantRegexes(
          raw,
          assistant: assistant,
          scope: AssistantRegexScope.assistant,
          target: AssistantRegexTransformTarget.send,
        );
      }
    }

    // Process user messages (documents, OCR, templates)
    final lastUserImagePaths = await messageBuilderService
        .processUserMessagesForApi(apiMessages, settings, assistant);

    // Signal processing finished
    onFileProcessingFinished?.call();

    // Inject prompts
    final systemPrompt = messageBuilderService.injectSystemPrompt(
      apiMessages,
      assistant,
      modelId,
    );
    final memoryAndChats = await messageBuilderService
        .injectMemoryAndRecentChats(
          apiMessages,
          assistant,
          currentConversationId: currentConversation?.id,
        );

    final hasBuiltInSearch = messageBuilderService.hasBuiltInSearch(
      settings,
      providerKey,
      modelId,
    );
    final searchPrompt = messageBuilderService.injectSearchPrompt(
      apiMessages,
      settings,
      hasBuiltInSearch,
    );
    final instructionPrompts = await messageBuilderService
        .injectInstructionPrompts(apiMessages, assistantId);
    final worldBookEntries = await messageBuilderService.injectWorldBookPrompts(
      apiMessages,
      assistantId,
    );

    // Apply context limit and inline images
    final contextLimit = messageBuilderService.applyContextLimit(
      apiMessages,
      assistant,
    );
    await messageBuilderService.inlineLocalImages(apiMessages);

    // Prepare tools
    final toolDefs = generationController.buildToolDefinitions(
      settings,
      assistant,
      providerKey,
      modelId,
      hasBuiltInSearch,
    );
    final mcpDiagnostics = generationController.buildMcpDiagnostics(
      settings,
      assistant,
      providerKey,
      modelId,
    );
    final onToolCall = toolDefs.isNotEmpty
        ? generationController.buildToolCallHandler(
            settings,
            assistant,
            approvalService: approvalService,
          )
        : null;

    return PreparedGeneration(
      apiMessages: apiMessages,
      toolDefs: toolDefs,
      mcpDiagnostics: mcpDiagnostics,
      onToolCall: onToolCall,
      hasBuiltInSearch: hasBuiltInSearch,
      lastUserImagePaths: lastUserImagePaths,
      systemPrompt: systemPrompt,
      memoryRecords: memoryAndChats.memoryRecords,
      recentChatSummaries: memoryAndChats.recentChatSummaries,
      rollingSummary: memoryAndChats.rollingSummary,
      instructionPrompts: instructionPrompts,
      worldBookEntries: worldBookEntries,
      searchPrompt: searchPrompt,
      contextLimit: contextLimit,
    );
  }

  /// Create user message from input data.
  Future<ChatMessage> createUserMessage({
    required String conversationId,
    required ChatInputData input,
    required Assistant? assistant,
  }) async {
    final content = input.text.trim();
    final imageMarkers = input.imagePaths.map((p) => '\n[image:$p]').join();
    final docMarkers = input.documents
        .map((d) => '\n[file:${d.path}|${d.fileName}|${d.mime}]')
        .join();

    final processedUserText = applyAssistantRegexes(
      content,
      assistant: assistant,
      scope: AssistantRegexScope.user,
      target: AssistantRegexTransformTarget.persist,
    );

    return chatService.addMessage(
      conversationId: conversationId,
      role: 'user',
      content: processedUserText + imageMarkers + docMarkers,
    );
  }

  /// Create assistant message placeholder.
  Future<ChatMessage> createAssistantPlaceholder({
    required String conversationId,
    required String modelId,
    required String providerKey,
    String? groupId,
    int version = 0,
  }) async {
    return chatService.addMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      modelId: modelId,
      providerId: providerKey,
      isStreaming: true,
      groupId: groupId,
      version: version,
    );
  }

  /// Initialize reasoning state for a message if reasoning is enabled.
  Future<void> initializeReasoningState({
    required String messageId,
    required bool enableReasoning,
  }) async {
    if (enableReasoning) {
      final rd = stream_ctrl.ReasoningData();
      streamController.reasoning[messageId] = rd;
      await chatService.updateMessage(
        messageId,
        reasoningStartAt: DateTime.now(),
      );
    }
  }

  /// Build GenerationContext for streaming.
  Future<stream_ctrl.GenerationContext> buildGenerationContext({
    required ChatMessage assistantMessage,
    required PreparedGeneration prepared,
    required List<String> userImagePaths,
    required String providerKey,
    required String modelId,
    required Assistant? assistant,
    required SettingsProvider settings,
    required bool supportsReasoning,
    required bool enableReasoning,
    required bool generateTitleOnFinish,
  }) async {
    final baseHeaders = buildConversationRequestHeaders(
      conversationId: assistantMessage.conversationId,
      customHeaders: generationController.buildCustomHeaders(assistant),
    );
    final baseBody = generationController.buildCustomBody(assistant);
    final injectSnapshot = _buildInjectSnapshot(prepared);
    final injectLog = _buildInjectLog(prepared);
    final analysisTurn = await analysisCaptureService.prepareTurn(
      assistantMessage: assistantMessage,
      assistantId: assistant?.id,
      providerKey: providerKey,
      modelId: modelId,
      stream: assistant?.streamOutput ?? true,
      apiMessages: prepared.apiMessages,
      toolDefs: prepared.toolDefs,
      injectSnapshot: injectSnapshot,
      injectLog: injectLog,
      rollingShortBefore: currentConversationSummary(
        assistantMessage.conversationId,
      ),
      rollingShortAfter: currentConversationSummary(
        assistantMessage.conversationId,
      ),
      requestHeaders: baseHeaders,
      existingBody: baseBody,
    );
    final extraHeaders = _mergeStringMaps(
      baseHeaders,
      analysisTurn.extraHeaders,
    );
    final extraBody = analysisTurn.extraBody ?? baseBody;
    return stream_ctrl.GenerationContext(
      assistantMessage: assistantMessage,
      apiMessages: prepared.apiMessages,
      userImagePaths: userImagePaths,
      providerKey: providerKey,
      modelId: modelId,
      assistant: assistant,
      settings: settings,
      config: settings.getProviderConfig(providerKey),
      toolDefs: prepared.toolDefs,
      onToolCall: prepared.onToolCall,
      extraHeaders: extraHeaders,
      extraBody: extraBody,
      supportsReasoning: supportsReasoning,
      enableReasoning: enableReasoning,
      streamOutput: assistant?.streamOutput ?? true,
      generateTitleOnFinish: generateTitleOnFinish,
      analysisTurn: analysisTurn,
    );
  }

  String? currentConversationSummary(String conversationId) {
    return chatService.getConversation(conversationId)?.summary;
  }

  /// Get current model and provider from assistant or global settings.
  ({String? providerKey, String? modelId}) getModelConfig(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    return (
      providerKey:
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      modelId: assistant?.chatModelId ?? settings.currentModelId,
    );
  }

  Map<String, dynamic> _buildInjectSnapshot(PreparedGeneration prepared) {
    return {
      'system_messages': prepared.apiMessages
          .where((m) => (m['role'] ?? '').toString() == 'system')
          .map((m) => (m['content'] ?? '').toString())
          .toList(growable: false),
      'memory_records': prepared.memoryRecords,
      'recent_chat_summaries': prepared.recentChatSummaries,
      'rolling_summary': prepared.rollingSummary,
      'mcp_diagnostics': prepared.mcpDiagnostics,
      'tool_definitions': prepared.toolDefs
          .map(
            (tool) => {
              'type': (tool['type'] ?? '').toString(),
              'name': ((tool['function'] as Map?)?['name'] ?? '').toString(),
              'description': ((tool['function'] as Map?)?['description'] ?? '')
                  .toString(),
            },
          )
          .toList(growable: false),
      'instruction_prompts': prepared.instructionPrompts,
      'world_book_entries': prepared.worldBookEntries,
      'search_prompt_enabled': prepared.searchPrompt != null,
      'context_limit': prepared.contextLimit,
      'api_messages_preview': prepared.apiMessages
          .map(
            (m) => {
              'role': (m['role'] ?? '').toString(),
              'content': _excerpt((m['content'] ?? '').toString()),
            },
          )
          .toList(growable: false),
    };
  }

  List<Map<String, dynamic>> _buildInjectLog(PreparedGeneration prepared) {
    final out = <Map<String, dynamic>>[];
    if ((prepared.systemPrompt ?? '').trim().isNotEmpty) {
      out.add({
        'kind': 'system_prompt',
        'source_id': 'assistant_system_prompt',
        'title': 'assistant_system_prompt',
        'reason': 'assistant.systemPrompt',
        'content_excerpt': _excerpt(prepared.systemPrompt!),
        'position': 0,
        'payload_json': {'content': prepared.systemPrompt},
      });
    }
    for (final memory in prepared.memoryRecords) {
      out.add({
        'kind': 'memory',
        'source_id': memory['id']?.toString(),
        'title': 'memory_${memory['id']}',
        'reason': 'assistant_memory',
        'content_excerpt': _excerpt((memory['content'] ?? '').toString()),
        'position': null,
        'payload_json': memory,
      });
    }
    for (final chat in prepared.recentChatSummaries) {
      out.add({
        'kind': 'recent_chat_summary',
        'source_id': chat['id']?.toString(),
        'title': (chat['title'] ?? '').toString(),
        'reason': 'recent_chat_reference',
        'content_excerpt': _excerpt((chat['summary'] ?? '').toString()),
        'position': null,
        'payload_json': chat,
      });
    }
    if (prepared.rollingSummary != null) {
      out.add({
        'kind': 'rolling_summary',
        'source_id': prepared.rollingSummary!['session_id']?.toString(),
        'title': 'current_chat_rolling_summary',
        'reason': 'current_chat_continuity',
        'content_excerpt': _excerpt(
          (prepared.rollingSummary!['summary_text'] ?? '').toString(),
        ),
        'position': null,
        'payload_json': prepared.rollingSummary,
      });
    }
    final enabledTools =
        (prepared.mcpDiagnostics['enabled_mcp_tool_names'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];
    if (prepared.mcpDiagnostics.isNotEmpty) {
      out.add({
        'kind': 'mcp_tools',
        'source_id': 'mcp_tools',
        'title': 'mcp_tools',
        'reason': (prepared.mcpDiagnostics['reason'] ?? '').toString(),
        'content_excerpt': enabledTools.isEmpty
            ? 'no_mcp_tools_injected'
            : enabledTools.join(', '),
        'position': null,
        'payload_json': prepared.mcpDiagnostics,
      });
    }
    for (final instruction in prepared.instructionPrompts) {
      out.add({
        'kind': 'instruction',
        'source_id': instruction['id']?.toString(),
        'title': (instruction['title'] ?? '').toString(),
        'reason': 'instruction_injection',
        'content_excerpt': _excerpt((instruction['prompt'] ?? '').toString()),
        'position': null,
        'payload_json': instruction,
      });
    }
    for (final worldBook in prepared.worldBookEntries) {
      out.add({
        'kind': 'world_book',
        'source_id': worldBook['entry_id']?.toString(),
        'title': (worldBook['entry_name'] ?? '').toString(),
        'reason': 'world_book_trigger',
        'content_excerpt': _excerpt((worldBook['content'] ?? '').toString()),
        'position': null,
        'payload_json': worldBook,
      });
    }
    if ((prepared.searchPrompt ?? '').trim().isNotEmpty) {
      out.add({
        'kind': 'search_prompt',
        'source_id': 'search_prompt',
        'title': 'search_prompt',
        'reason': 'search_enabled_without_builtin_search',
        'content_excerpt': _excerpt(prepared.searchPrompt!),
        'position': null,
        'payload_json': {'content': prepared.searchPrompt},
      });
    }
    return out;
  }

  Map<String, String>? _mergeStringMaps(
    Map<String, String>? first,
    Map<String, String>? second,
  ) {
    final merged = <String, String>{};
    if (first != null) merged.addAll(first);
    if (second != null) merged.addAll(second);
    return merged.isEmpty ? null : merged;
  }

  static String _excerpt(String value, {int maxLength = 240}) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }

  /// Calculate version info for regeneration.
  ({String? targetGroupId, int nextVersion, int lastKeep})
  calculateRegenerationVersioning({
    required ChatMessage message,
    required List<ChatMessage> messages,
    required bool assistantAsNewReply,
  }) {
    final idx = messages.indexWhere((m) => m.id == message.id);
    if (idx < 0) {
      return (targetGroupId: null, nextVersion: 0, lastKeep: -1);
    }

    String? targetGroupId;
    int nextVersion = 0;
    int lastKeep;

    if (message.role == 'assistant') {
      lastKeep = idx;
      if (assistantAsNewReply) {
        targetGroupId = null;
        nextVersion = 0;
      } else {
        targetGroupId = message.groupId ?? message.id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      }
    } else {
      // User message
      final userGroupId = message.groupId ?? message.id;
      int userFirst = -1;
      for (int i = 0; i < messages.length; i++) {
        final gid0 = (messages[i].groupId ?? messages[i].id);
        if (gid0 == userGroupId) {
          userFirst = i;
          break;
        }
      }
      if (userFirst < 0) userFirst = idx;

      int aid = -1;
      for (int i = userFirst + 1; i < messages.length; i++) {
        if (messages[i].role == 'assistant') {
          aid = i;
          break;
        }
      }

      if (aid >= 0) {
        lastKeep = aid;
        targetGroupId = messages[aid].groupId ?? messages[aid].id;
        int maxVer = -1;
        for (final m in messages) {
          final gid = (m.groupId ?? m.id);
          if (gid == targetGroupId) {
            if (m.version > maxVer) maxVer = m.version;
          }
        }
        nextVersion = maxVer + 1;
      } else {
        lastKeep = userFirst;
        targetGroupId = null;
        nextVersion = 0;
      }
    }

    return (
      targetGroupId: targetGroupId,
      nextVersion: nextVersion,
      lastKeep: lastKeep,
    );
  }

  /// Remove trailing messages after regeneration cut point.
  Future<List<String>> removeTrailingMessages({
    required List<ChatMessage> messages,
    required int lastKeep,
    required String? targetGroupId,
  }) async {
    if (lastKeep >= messages.length - 1) {
      return const [];
    }

    // Collect groups that appear at or before lastKeep
    final keepGroups = <String>{};
    for (int i = 0; i <= lastKeep && i < messages.length; i++) {
      final g = (messages[i].groupId ?? messages[i].id);
      keepGroups.add(g);
    }
    if (targetGroupId != null) keepGroups.add(targetGroupId);

    final trailing = messages.sublist(lastKeep + 1);
    final removeIds = <String>[];
    for (final m in trailing) {
      final gid = (m.groupId ?? m.id);
      final shouldKeep = keepGroups.contains(gid);
      if (!shouldKeep) removeIds.add(m.id);
    }

    for (final id in removeIds) {
      try {
        await chatService.deleteMessage(id);
      } catch (_) {}
      streamController.reasoning.remove(id);
      streamController.toolParts.remove(id);
      streamController.reasoningSegments.remove(id);
    }

    return removeIds;
  }

  bool _shouldIncludeAudioForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    final cfg = settings.getProviderConfig(providerKey);
    if (ProviderConfig.classify(providerKey, explicitType: cfg.providerType) !=
        ProviderKind.openai) {
      return false;
    }
    final override = ModelOverridePayloadParser.modelOverride(
      cfg.modelOverrides,
      modelId,
    );
    final upstreamModelId = resolveApiModelIdOverride(override, modelId);
    return isLongCatOmniModelId(upstreamModelId);
  }

  bool supportsAudioAttachmentsForProvider(
    SettingsProvider settings, {
    required String providerKey,
    required String modelId,
  }) {
    return _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );
  }

  String _effectiveAttachmentMime(DocumentAttachment attachment) {
    return resolveDocumentAttachmentMime(attachment);
  }

  bool inputContainsAudioAttachments(ChatInputData input) {
    for (final attachment in input.documents) {
      if (isAudioMime(_effectiveAttachmentMime(attachment))) {
        return true;
      }
    }
    return false;
  }

  bool apiMessagesContainAudioAttachments(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if ((message['role'] ?? '').toString() != 'user') continue;
      final parsed = messageBuilderService.parseInputFromRaw(
        (message['content'] ?? '').toString(),
      );
      if (parsed.documents.any(
        (attachment) => isAudioMime(_effectiveAttachmentMime(attachment)),
      )) {
        return true;
      }
    }
    return false;
  }

  List<String> _filterMediaPathsForProvider(
    List<String> paths, {
    required bool includeAudio,
  }) {
    return paths
        .where((path) {
          final mime = inferMediaMimeFromSource(
            path,
            fallbackMime: 'image/png',
          );
          if (isAudioMime(mime)) return includeAudio;
          return isImageMime(mime) || isVideoMime(mime);
        })
        .toList(growable: false);
  }

  /// Build user image paths considering OCR mode.
  List<String> buildUserImagePaths({
    required ChatInputData? input,
    required List<String> lastUserImagePaths,
    required SettingsProvider settings,
    required String providerKey,
    required String modelId,
  }) {
    final bool ocrActive =
        settings.ocrEnabled &&
        settings.ocrModelProvider != null &&
        settings.ocrModelId != null;

    final includeAudio = _shouldIncludeAudioForProvider(
      settings,
      providerKey: providerKey,
      modelId: modelId,
    );

    if (input != null) {
      final currentMediaPaths = <String>[];
      for (final d in input.documents) {
        final effectiveMime = _effectiveAttachmentMime(d);
        if (isVideoMime(effectiveMime) ||
            (includeAudio && isAudioMime(effectiveMime))) {
          currentMediaPaths.add(d.path);
        }
      }
      return _filterMediaPathsForProvider(<String>[
        if (!ocrActive) ...input.imagePaths,
        ...currentMediaPaths,
      ], includeAudio: includeAudio);
    }

    return _filterMediaPathsForProvider(
      lastUserImagePaths
          .where((path) {
            if (!ocrActive) return true;
            return !isImageMime(
              inferMediaMimeFromSource(path, fallbackMime: 'image/png'),
            );
          })
          .toList(growable: false),
      includeAudio: includeAudio,
    );
  }
}
