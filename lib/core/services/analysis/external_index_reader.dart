class ExternalIndexCandidate {
  const ExternalIndexCandidate({
    required this.id,
    required this.title,
    required this.content,
    this.score,
    this.reason,
    this.source,
  });

  final String id;
  final String title;
  final String content;
  final double? score;
  final String? reason;
  final String? source;
}

abstract class ExternalMemoryIndexReader {
  Future<List<ExternalIndexCandidate>> query({
    required String assistantId,
    required String query,
    int limit = 10,
  });
}

abstract class ExternalSummaryIndexReader {
  Future<List<ExternalIndexCandidate>> query({
    required String conversationId,
    required String query,
    int limit = 10,
  });
}

class EmptyExternalMemoryIndexReader implements ExternalMemoryIndexReader {
  const EmptyExternalMemoryIndexReader();

  @override
  Future<List<ExternalIndexCandidate>> query({
    required String assistantId,
    required String query,
    int limit = 10,
  }) async => const <ExternalIndexCandidate>[];
}

class EmptyExternalSummaryIndexReader implements ExternalSummaryIndexReader {
  const EmptyExternalSummaryIndexReader();

  @override
  Future<List<ExternalIndexCandidate>> query({
    required String conversationId,
    required String query,
    int limit = 10,
  }) async => const <ExternalIndexCandidate>[];
}
