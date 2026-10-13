import '../data/events.dart';
import '../data/models.dart';

/// Immutable view of one conversation.
///
/// The server sends incremental deltas; this type is the client's folded
/// result. [applyEvent] is the only way to build or change it.
class Timeline {
  const Timeline({
    this.messages = const [],
    this.running = false,
    this.cost = 0,
    this.tokens,
    this.retryAttempt = 0,
    this.retryError,
  });

  final List<ChatMessage> messages;
  final bool running;
  final double cost;
  final TokenUsage? tokens;

  /// Which attempt failed last, or 0 when nothing is being retried.
  final int retryAttempt;

  /// Why the last attempt failed, or null when nothing is being retried.
  /// Transient by design: any real progress clears it.
  final String? retryError;

  bool get isEmpty => messages.isEmpty;

  bool get isRetrying => retryAttempt > 0 && retryError != null;

  Timeline copyWith({
    List<ChatMessage>? messages,
    bool? running,
    double? cost,
    TokenUsage? tokens,
    int? retryAttempt,
    String? retryError,
    bool clearRetry = false,
  }) => Timeline(
    messages: messages ?? this.messages,
    running: running ?? this.running,
    cost: cost ?? this.cost,
    tokens: tokens ?? this.tokens,
    retryAttempt: clearRetry ? 0 : (retryAttempt ?? this.retryAttempt),
    retryError: clearRetry ? null : (retryError ?? this.retryError),
  );
}

/// Folds one server event into [state].
///
/// Pure by design: no timers, no I/O, no error throwing. Unknown event types —
/// and events for other sessions — return the state unchanged, because the
/// server adds types without warning and a chat client must not crash on one.
Timeline applyEvent(Timeline state, ServerEvent event, {String? sessionId}) {
  if (sessionId != null && event.sessionId != sessionId) return state;

  switch (event.type) {
    case Ev.executionStarted:
      return state.copyWith(running: true, clearRetry: true);

    case Ev.executionSucceeded:
    case Ev.executionInterrupted:
      return state.copyWith(running: false, clearRetry: true);

    case Ev.executionFailed:
      // Terminal like the two above, but with the reason kept: a failed
      // execution must read as failed, not as stopped.
      return state.copyWith(running: false, retryError: _errorText(event));

    case Ev.retryScheduled:
      final attempt = event.data['attempt'];
      return state.copyWith(
        running: true,
        retryAttempt: attempt is num ? attempt.toInt() : 0,
        retryError: _errorText(event),
      );

    case Ev.textStarted:
      return _progress(_withAssistant(state, event.messageId));

    case Ev.textDelta:
      return _progress(
        _appendText(state, event.messageId, _ordinal(event), event.data['delta'] as String? ?? ''),
      );

    case Ev.textEnded:
      return _progress(
        _setText(state, event.messageId, _ordinal(event), event.data['text'] as String? ?? '',),
      );

    case Ev.reasoningStarted:
      return _progress(_withAssistant(state, event.messageId));

    case Ev.reasoningDelta:
      return _progress(
        _appendReasoning(state, event.messageId, _ordinal(event), event.data['delta'] as String? ?? '',),
      );

    case Ev.reasoningEnded:
      return _progress(
        _setReasoning(state, event.messageId, _ordinal(event), event.data['text'] as String? ?? '',),
      );

    case Ev.toolInputStarted:
      return _progress(
        _withTool(
          state,
          event.messageId,
          ToolPart(
            id: event.toolId,
            name: event.data['name'] as String? ?? 'tool',
            status: ToolStatus.pending,
          ),
        ),
      );

    case Ev.toolCalled:
      return _progress(_updateTool(state, event.messageId, event.toolId, (tool) {
        final input = event.data['input'];
        return ToolPart(
          id: tool.id,
          name: tool.name,
          input: input is Map
              ? input.cast<String, Object?>()
              : const <String, Object?>{},
          status: ToolStatus.running,
          output: tool.output,
          error: tool.error,
        );
      }));

    case Ev.toolSuccess:
      return _progress(_updateTool(state, event.messageId, event.toolId, (tool) {
        final content = event.data['content'];
        final text = content is List
            ? content
                  .whereType<Map>()
                  .map((e) => e['text'])
                  .whereType<String>()
                  .join('\n')
            : '';
        return ToolPart(
          id: tool.id,
          name: tool.name,
          input: tool.input,
          status: ToolStatus.completed,
          output: text.isEmpty ? tool.output : text,
        );
      }));

    case Ev.toolFailed:
      return _progress(_updateTool(state, event.messageId, event.toolId, (tool) {
        final error = event.data['error'];
        return ToolPart(
          id: tool.id,
          name: tool.name,
          input: tool.input,
          status: ToolStatus.error,
          output: tool.output,
          error: error is Map
              ? error['message'] as String? ?? 'Tool failed'
              : error as String? ?? 'Tool failed',
        );
      }));

    case Ev.usageUpdated:
      final tokens = event.data['tokens'];
      return _progress(
        state.copyWith(
          cost: (event.data['cost'] as num?)?.toDouble() ?? state.cost,
          tokens: tokens is Map
              ? TokenUsage.fromJson(tokens.cast<String, Object?>())
              : state.tokens,
        ),
      );

    default:
      return state;
  }
}

/// Real progress retires the retry notice: the failure it described is no
/// longer the latest news.
Timeline _progress(Timeline state) => state.isRetrying
    ? state.copyWith(clearRetry: true)
    : state;

/// The human sentence inside an error payload, whatever shape it arrived in.
/// The server sends `{type, message}`; anything else degrades to the type, the
/// raw string, and finally a generic line rather than nothing.
String _errorText(ServerEvent event) {
  final error = event.data['error'];
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.isNotEmpty) return message;
    final type = error['type'];
    if (type is String && type.isNotEmpty) return type;
  }
  if (error is String && error.isNotEmpty) return error;
  return 'The request failed and will be retried';
}

// --- internals --------------------------------------------------------------

Timeline _replaceLast(Timeline state, ChatMessage message) {
  final next = List<ChatMessage>.of(state.messages);
  if (next.isNotEmpty && next.last.id == message.id) {
    next[next.length - 1] = message;
  } else {
    next.add(message);
  }
  return state.copyWith(messages: next);
}

Timeline _withAssistant(Timeline state, String messageId) {
  if (messageId.isEmpty) return state;
  if (state.messages.any((m) => m.id == messageId)) return state;
  return _replaceLast(
    state,
    AssistantMessage(
      id: messageId,
      created: DateTime.now().millisecondsSinceEpoch,
      agent: '',
      modelId: '',
    ),
  );
}

AssistantMessage? _findAssistant(Timeline state, String messageId) {
  if (messageId.isEmpty) return null;
  for (final message in state.messages) {
    if (message is AssistantMessage && message.id == messageId) return message;
  }
  return null;
}

/// Ensures a block exists at [ordinal]; the server uses the ordinal to place
/// interleaved text and reasoning in the right order.
TextPart _ensureText(List<AssistantPart> parts, int ordinal) {
  while (parts.length <= ordinal) {
    parts.add(TextPart(''));
  }
  final existing = parts[ordinal];
  if (existing is TextPart) return existing;
  final created = TextPart('');
  parts[ordinal] = created;
  return created;
}

ReasoningPart _ensureReasoning(List<AssistantPart> parts, int ordinal) {
  while (parts.length <= ordinal) {
    parts.add(ReasoningPart(''));
  }
  final existing = parts[ordinal];
  if (existing is ReasoningPart) return existing;
  final created = ReasoningPart('');
  parts[ordinal] = created;
  return created;
}

Timeline _withTool(Timeline state, String messageId, ToolPart tool) {
  final message = _findAssistant(state, messageId);
  if (message == null) {
    // A tool can be announced before any text block exists. Materialise the
    // message first, then add the part, otherwise the call is lost.
    return _withTool(_withAssistant(state, messageId), messageId, tool);
  }
  final parts = List<AssistantPart>.of(message.parts);
  if (parts.whereType<ToolPart>().any((t) => t.id == tool.id)) {
    return state;
  }
  parts.add(tool);
  return _replaceLast(
    state,
    AssistantMessage(
      id: message.id,
      created: message.created,
      agent: message.agent,
      modelId: message.modelId,
      parts: parts,
      error: message.error,
    ),
  );
}

Timeline _appendText(Timeline state, String messageId, int ordinal, String delta) {
  if (delta.isEmpty) return state;
  final message = _findAssistant(state, messageId);
  if (message == null) return state;
  final parts = List<AssistantPart>.of(message.parts);
  _ensureText(parts, ordinal).text += delta;
  return _replaceLast(state, _copyOf(message, parts));
}

Timeline _setText(Timeline state, String messageId, int ordinal, String text) {
  final message = _findAssistant(state, messageId);
  if (message == null) return state;
  final parts = List<AssistantPart>.of(message.parts);
  _ensureText(parts, ordinal).text = text;
  return _replaceLast(state, _copyOf(message, parts));
}

Timeline _appendReasoning(Timeline state, String messageId, int ordinal, String delta) {
  if (delta.isEmpty) return state;
  final message = _findAssistant(state, messageId);
  if (message == null) return state;
  final parts = List<AssistantPart>.of(message.parts);
  _ensureReasoning(parts, ordinal).text += delta;
  return _replaceLast(state, _copyOf(message, parts));
}

Timeline _setReasoning(Timeline state, String messageId, int ordinal, String text) {
  final message = _findAssistant(state, messageId);
  if (message == null) return state;
  final parts = List<AssistantPart>.of(message.parts);
  _ensureReasoning(parts, ordinal).text = text;
  return _replaceLast(state, _copyOf(message, parts));
}

Timeline _updateTool(
  Timeline state,
  String messageId,
  String toolId,
  ToolPart Function(ToolPart tool) change,
) {
  final message = _findAssistant(state, messageId);
  if (message == null || toolId.isEmpty) return state;
  final parts = List<AssistantPart>.of(message.parts);
  final index = parts.indexWhere((p) => p is ToolPart && p.id == toolId);
  if (index < 0) return state;
  parts[index] = change(parts[index] as ToolPart);
  return _replaceLast(state, _copyOf(message, parts));
}

AssistantMessage _copyOf(AssistantMessage message, List<AssistantPart> parts) =>
    AssistantMessage(
      id: message.id,
      created: message.created,
      agent: message.agent,
      modelId: message.modelId,
      parts: parts,
      error: message.error,
    );

/// `ordinal` is a field on text and reasoning events, not on tool events.
int _ordinal(ServerEvent event) {
  final value = event.data['ordinal'];
  return value is num ? value.toInt() : 0;
}