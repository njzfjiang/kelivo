import '../../models/assistant.dart';
import '../../models/chat_message.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import '../chat/chat_service.dart';
import 'analysis_store.dart';

class RollingSummaryService {
  RollingSummaryService({
    required ChatService chatService,
    AnalysisStore? store,
  }) : _chatService = chatService,
       _store = store ?? AnalysisStore.instance;

  static const String defaultRollingSummaryPrompt = '''
I will give you the previous rolling summary and recent messages from the same conversation.
Update the rolling summary so the assistant can continue the current work after context truncation.

Requirements:
1. Use the same language as the conversation
2. Focus on current goal, recent progress, open questions, next step, and important constraints
3. Keep it concise but practical
4. Output plain text only, without headings or meta-commentary

<previous_summary>
{previous_summary}
</previous_summary>

<messages>
{messages}
</messages>
''';

  final ChatService _chatService;
  final AnalysisStore _store;

  Future<Map<String, dynamic>?> getLatest(String conversationId) {
    return _store.getRollingSummary(conversationId);
  }

  Future<void> maybeGenerateForConversation({
    required String conversationId,
    required Assistant? assistant,
    required SettingsProvider settings,
    int? thinkingBudget,
  }) async {
    final convo = _chatService.getConversation(conversationId);
    if (convo == null) return;

    final messages = _chatService
        .getMessages(conversationId)
        .where(
          (m) => _isSummarizableRole(m.role) && m.content.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (messages.isEmpty) return;

    final existing = await _store.getRollingSummary(conversationId);
    final lastCount = _asInt(existing?['source_last_message_count']) ?? 0;
    final triggerCount =
        assistant?.recentChatsSummaryMessageCount ??
        Assistant.defaultRecentChatsSummaryMessageCount;
    if (messages.length - lastCount < triggerCount) return;

    final providerKey =
        settings.summaryModelProvider ??
        settings.titleModelProvider ??
        assistant?.chatModelProvider ??
        settings.currentModelProvider;
    final modelId =
        settings.summaryModelId ??
        settings.titleModelId ??
        assistant?.chatModelId ??
        settings.currentModelId;
    if (providerKey == null || modelId == null) return;

    final cfg = settings.getProviderConfig(providerKey);
    final previousSummary = (existing?['summary_text'] ?? '').toString().trim();
    final deltaMessages = messages.skip(lastCount).toList(growable: false);
    if (deltaMessages.isEmpty) return;

    final transcript = _buildTranscript(deltaMessages, maxChars: 4000);
    if (transcript.trim().isEmpty) return;

    final prompt = defaultRollingSummaryPrompt
        .replaceAll('{previous_summary}', previousSummary)
        .replaceAll('{messages}', transcript);

    try {
      final summary = (await ChatApiService.generateText(
        config: cfg,
        modelId: modelId,
        prompt: prompt,
        thinkingBudget: thinkingBudget,
      )).trim();
      if (summary.isEmpty) return;
      final now = DateTime.now().toIso8601String();
      await _store.upsertRollingSummary(
        sessionId: conversationId,
        assistantId: assistant?.id ?? convo.assistantId ?? '',
        summaryText: summary,
        sourceLastMessageCount: messages.length,
        now: now,
      );
    } catch (_) {
      // Keep previous rolling summary on failure.
    }
  }

  static bool _isSummarizableRole(String role) {
    return role == 'user' || role == 'assistant';
  }

  static String _buildTranscript(
    List<ChatMessage> messages, {
    int maxChars = 4000,
  }) {
    final buffer = StringBuffer();
    for (final message in messages) {
      final role = message.role == 'assistant' ? 'assistant' : 'user';
      final content = message.content.trim();
      if (content.isEmpty) continue;
      buffer.writeln('$role: $content');
      buffer.writeln();
    }
    final text = buffer.toString().trim();
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
