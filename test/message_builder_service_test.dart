import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/features/home/services/message_builder_service.dart';

class _FakeChatService extends ChatService {
  _FakeChatService(this._toolEventsByMessageId);

  final Map<String, List<Map<String, dynamic>>> _toolEventsByMessageId;

  @override
  List<Map<String, dynamic>> getToolEvents(String assistantMessageId) {
    return _toolEventsByMessageId[assistantMessageId] ??
        const <Map<String, dynamic>>[];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'buildApiMessages rebuilds assistant tool history with reasoning_content',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final service = MessageBuilderService(
        chatService: _FakeChatService({
          'assistant-1': [
            {
              'id': 'call_1',
              'name': 'date',
              'arguments': <String, dynamic>{'timezone': 'America/Toronto'},
              'content': '2026-04-24',
              'tool_batch_index': 0,
              'assistant_content': 'Let me check the date.',
              'assistant_reasoning_content': 'First I need today\'s date.',
            },
          ],
        }),
        contextProvider: context,
      );

      final apiMessages = service.buildApiMessages(
        messages: [
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'I checked the date for you.',
            conversationId: 'conversation-1',
            reasoningText: 'First I need today\'s date.',
            reasoningSegmentsJson:
                '{"segments":[{"text":"First I need today\\u0027s date.","toolStartIndex":0},{"text":"Now I can answer.","toolStartIndex":1}]}',
          ),
        ],
        versionSelections: const <String, int>{},
        currentConversation: null,
        includeOpenAIToolMessages: true,
      );

      expect(apiMessages, hasLength(3));
      expect(apiMessages[0]['role'], 'assistant');
      expect(apiMessages[0]['tool_calls'], isA<List<dynamic>>());
      expect(apiMessages[0]['content'], 'Let me check the date.');
      expect(
        apiMessages[0]['reasoning_content'],
        'First I need today\'s date.',
      );
      expect(apiMessages[1], {
        'role': 'tool',
        'name': 'date',
        'tool_call_id': 'call_1',
        'content': '2026-04-24',
      });
      expect(apiMessages[2], {
        'role': 'assistant',
        'content': 'I checked the date for you.',
        'reasoning_content': 'Now I can answer.',
      });
    },
  );

  testWidgets(
    'buildApiMessages omits reasoning_content when history has no reasoning text',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final service = MessageBuilderService(
        chatService: _FakeChatService({
          'assistant-2': [
            {
              'id': 'call_2',
              'name': 'weather',
              'arguments': <String, dynamic>{},
              'content': 'sunny',
              'tool_batch_index': 0,
              'assistant_content': 'Let me check the weather.',
            },
          ],
        }),
        contextProvider: context,
      );

      final apiMessages = service.buildApiMessages(
        messages: [
          ChatMessage(
            id: 'assistant-2',
            role: 'assistant',
            content: 'Let me check the weather.',
            conversationId: 'conversation-2',
          ),
        ],
        versionSelections: const <String, int>{},
        currentConversation: null,
        includeOpenAIToolMessages: true,
      );

      expect(apiMessages, hasLength(3));
      expect(apiMessages[0].containsKey('reasoning_content'), isFalse);
      expect(apiMessages[0]['content'], 'Let me check the weather.');
      expect(apiMessages[2], {
        'role': 'assistant',
        'content': 'Let me check the weather.',
      });
    },
  );
}
