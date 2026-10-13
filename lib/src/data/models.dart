/// Typed view models for the subset of the OpenCode API this client uses.
///
/// Field names mirror `tool/openapi.json` so the wire format and the Dart model
/// stay in one-to-one correspondence. Everything is parsed defensively: the
/// server adds message and event types without notice, and a client that throws
/// on an unknown shape is useless on a phone.
library;

int _int(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double _double(Object? v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

String? _str(Object? v) => v is String ? v : null;

Map<String, Object?> _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : const <String, Object?>{};

List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

// --- server -----------------------------------------------------------------

class ServerInfo {
  const ServerInfo({
    required this.version,
    required this.pid,
    required this.urls,
  });

  factory ServerInfo.fromJson(Map<String, Object?> json) => ServerInfo(
    version: _str(json['version']) ?? 'unknown',
    pid: _int(json['pid']),
    urls: _list(json['urls']).map((e) => '$e').toList(growable: false),
  );

  final String version;
  final int pid;
  final List<String> urls;
}

// --- projects ---------------------------------------------------------------

class Project {
  const Project({
    required this.id,
    required this.canonical,
    required this.sandboxes,
    this.name,
  });

  factory Project.fromJson(Map<String, Object?> json) => Project(
    id: _str(json['id']) ?? '',
    canonical: _str(json['canonical']) ?? '',
    sandboxes: _list(json['sandboxes']).map((e) => '$e').toList(growable: false),
    name: _str(json['name']),
  );

  final String id;
  final String canonical;
  final List<String> sandboxes;
  final String? name;

  /// Directory to use as the `directory` scope for session calls.
  String get scopeDirectory =>
      sandboxes.isNotEmpty ? sandboxes.first : canonical;

  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    final trimmed = canonical.replaceAll(RegExp(r'[/\\]+$'), '');
    final parts = trimmed.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? canonical : parts.last;
  }
}

// --- sessions ---------------------------------------------------------------

class TokenUsage {
  const TokenUsage({
    this.input = 0,
    this.output = 0,
    this.reasoning = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  factory TokenUsage.fromJson(Map<String, Object?> json) {
    final cache = _map(json['cache']);
    return TokenUsage(
      input: _int(json['input']),
      output: _int(json['output']),
      reasoning: _int(json['reasoning']),
      cacheRead: _int(cache['read']),
      cacheWrite: _int(cache['write']),
    );
  }

  final int input;
  final int output;
  final int reasoning;
  final int cacheRead;
  final int cacheWrite;

  int get total => input + output + reasoning + cacheRead + cacheWrite;
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.projectId,
    required this.cost,
    required this.tokens,
    required this.created,
    required this.updated,
    this.agent,
    this.modelId,
    this.modelProvider,
    this.modelVariant,
    this.directory,
    this.outcome,
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    final time = _map(json['time']);
    final model = _map(json['model']);
    final location = _map(json['location']);
    return SessionSummary(
      id: _str(json['id']) ?? '',
      title: _str(json['title']) ?? '',
      projectId: _str(json['projectID']) ?? '',
      cost: _double(json['cost']),
      tokens: TokenUsage.fromJson(_map(json['tokens'])),
      created: _int(time['created']),
      updated: _int(time['updated']),
      agent: _str(json['agent']),
      modelId: _str(model['id']),
      modelProvider: _str(model['providerID']),
      modelVariant: _str(model['variant']),
      directory: _str(location['directory']),
      outcome: _str(json['outcome']),
    );
  }

  final String id;
  final String title;
  final String projectId;
  final double cost;
  final TokenUsage tokens;
  final int created;
  final int updated;
  final String? agent;
  final String? modelId;
  final String? modelProvider;
  /// Reasoning effort applied to this session.
  final String? modelVariant;
  final String? directory;
  final String? outcome;

  String get displayTitle => title.trim().isEmpty ? 'Untitled session' : title;
}

// --- messages ---------------------------------------------------------------

sealed class ChatMessage {
  const ChatMessage({required this.id, required this.created});

  final String id;
  final int created;
}

class UserMessage extends ChatMessage {
  const UserMessage({
    required super.id,
    required super.created,
    required this.text,
  });

  factory UserMessage.fromJson(Map<String, Object?> json) => UserMessage(
    id: _str(json['id']) ?? '',
    created: _int(_map(json['time'])['created']),
    text: _str(json['text']) ?? '',
  );

  final String text;
}

class SystemMessage extends ChatMessage {
  const SystemMessage({
    required super.id,
    required super.created,
    required this.text,
  });

  factory SystemMessage.fromJson(Map<String, Object?> json) => SystemMessage(
    id: _str(json['id']) ?? '',
    created: _int(_map(json['time'])['created']),
    text: _str(json['text']) ?? '',
  );

  final String text;
}

/// A single assistant turn. [parts] is mutated while the response streams in,
/// so the UI can rebuild cheaply from a stable identity.
class AssistantMessage extends ChatMessage {
  AssistantMessage({
    required super.id,
    required super.created,
    required this.agent,
    required this.modelId,
    List<AssistantPart>? parts,
    this.error,
    this.errorType,
  }) : parts = parts ?? <AssistantPart>[];

  factory AssistantMessage.fromJson(Map<String, Object?> json) {
    final time = _map(json['time']);
    final model = _map(json['model']);
    final error = _map(json['error']);
    return AssistantMessage(
      id: _str(json['id']) ?? '',
      created: _int(time['created']),
      agent: _str(json['agent']) ?? '',
      modelId: _str(model['id']) ?? '',
      parts: _list(json['content'])
          .map((e) => assistantPartFromJson(_map(e)))
          .whereType<AssistantPart>()
          .toList(),
      error: _str(error['message']),
      errorType: _str(error['type']),
    );
  }

  final String agent;
  final String modelId;
  final List<AssistantPart> parts;
  final String? error;
  final String? errorType;

  /// An aborted step is the server reporting that execution stopped, not that
  /// something went wrong. Showing it as a failure is wrong.
  bool get isAborted => errorType == 'aborted';

  String get text =>
      parts.whereType<TextPart>().map((p) => p.text).join('\n\n').trim();
}

/// Any assistant message the client does not model yet (compaction, idle,
/// model-selected, …). Kept so the timeline never silently drops history.
class UnknownMessage extends ChatMessage {
  const UnknownMessage({
    required super.id,
    required super.created,
    required this.kind,
    required this.raw,
  });

  factory UnknownMessage.fromJson(Map<String, Object?> json) => UnknownMessage(
    id: _str(json['id']) ?? '',
    created: _int(_map(json['time'])['created']),
    kind: _str(json['type']) ?? 'unknown',
    raw: json,
  );

  final String kind;
  final Map<String, Object?> raw;

  String? get text {
    final value = raw['text'] ?? raw['description'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  /// Server bookkeeping that the reader does not need to see. Rendering
  /// "idle" or "model-selected" as chat lines is noise, not information.
  bool get isVisible => switch (kind) {
    'idle' ||
    'synthetic' ||
    'model-selected' ||
    'agent-selected' ||
    'location-switched' => false,
    _ => true,
  };
}

sealed class AssistantPart {
  const AssistantPart();
}

class TextPart extends AssistantPart {
  TextPart(this.text);

  factory TextPart.fromJson(Map<String, Object?> json) =>
      TextPart(_str(json['text']) ?? '');

  String text;
}

class ReasoningPart extends AssistantPart {
  ReasoningPart(this.text);

  factory ReasoningPart.fromJson(Map<String, Object?> json) =>
      ReasoningPart(_str(json['text']) ?? '');

  String text;
}

class ToolPart extends AssistantPart {
  ToolPart({
    required this.id,
    required this.name,
    this.input = const <String, Object?>{},
    this.status = ToolStatus.pending,
    this.output = '',
    this.error,
  });

  factory ToolPart.fromJson(Map<String, Object?> json) {
    final state = _map(json['state']);
    final status = switch (_str(state['status'])) {
      'completed' => ToolStatus.completed,
      'error' => ToolStatus.error,
      'running' => ToolStatus.running,
      _ => ToolStatus.pending,
    };
    return ToolPart(
      id: _str(json['id']) ?? '',
      name: _str(json['name']) ?? 'tool',
      input: _map(state['input']),
      status: status,
      output: _list(state['content'])
          .map((e) => _str(_map(e)['text']))
          .whereType<String>()
          .join('\n'),
      error: _str(_map(state['error'])['message']),
    );
  }

  final String id;
  final String name;
  Map<String, Object?> input;
  ToolStatus status;
  String output;
  String? error;
}

enum ToolStatus { pending, running, completed, error }

/// Dispatches a content block to the right model, returning `null` for blocks
/// this version of the client does not understand.
AssistantPart? assistantPartFromJson(Map<String, Object?> json) {
  return switch (_str(json['type'])) {
    'text' => TextPart.fromJson(json),
    'reasoning' => ReasoningPart.fromJson(json),
    'tool' => ToolPart.fromJson(json),
    _ => null,
  };
}

ChatMessage? messageFromJson(Map<String, Object?> json) {
  return switch (_str(json['type'])) {
    'user' => UserMessage.fromJson(json),
    'assistant' => AssistantMessage.fromJson(json),
    'system' => SystemMessage.fromJson(json),
    _ => UnknownMessage.fromJson(json),
  };
}

// --- permissions ------------------------------------------------------------

enum PermissionReply { once, always, reject }

class PermissionRequest {
  const PermissionRequest({
    required this.id,
    required this.sessionId,
    required this.action,
    required this.resources,
    this.message,
    this.toolId,
  });

  factory PermissionRequest.fromEventData(Map<String, Object?> data) {
    final source = _map(data['source']);
    return PermissionRequest(
      id: _str(data['id']) ?? '',
      sessionId: _str(data['sessionID']) ?? '',
      action: _str(data['action']) ?? 'unknown',
      resources: _list(data['resources'])
          .map((e) => '$e')
          .toList(growable: false),
      message: _str(data['message']),
      toolId: _str(source['id']),
    );
  }

  final String id;
  final String sessionId;
  final String action;
  final List<String> resources;
  final String? message;
  final String? toolId;

  String get headline => switch (action) {
    'external_directory' => 'Access outside the workspace',
    'bash' => 'Run a shell command',
    'edit' || 'write' => 'Modify a file',
    _ => action,
  };
}
// --- models -----------------------------------------------------------------

/// Reasoning effort levels are expressed as model variants: `low`, `medium`,
/// `high`, `xhigh`, `max`, and sometimes `none`.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.providerID,
    required this.name,
    required this.variants,
    required this.contextLimit,
    required this.outputLimit,
    required this.enabled,
    this.status = 'active',
    this.costIn,
    this.costOut,
  });

  factory ModelInfo.fromJson(Map<String, Object?> json) {
    final limit = _map(json['limit']);
    final cost = _list(json['cost']);
    final tier = cost.isEmpty ? const <String, Object?>{} : _map(cost.first);
    return ModelInfo(
      id: _str(json['id']) ?? '',
      providerID: _str(json['providerID']) ?? '',
      name: _str(json['name']) ?? '',
      variants: _list(json['variants'])
          .map((e) => _str(_map(e)['id']))
          .whereType<String>()
          .toList(growable: false),
      contextLimit: _int(limit['context']),
      outputLimit: _int(limit['output']),
      enabled: json['enabled'] != false,
      status: _str(json['status']) ?? 'active',
      costIn: _asDouble(tier['input']),
      costOut: _asDouble(tier['output']),
    );
  }

  final String id;
  final String providerID;
  final String name;
  final List<String> variants;
  final int contextLimit;
  final int outputLimit;
  final bool enabled;
  final String status;
  final double? costIn;
  final double? costOut;

  String get key => '$providerID/$id';

  bool get hasVariants => variants.isNotEmpty;

  /// True when [variant] is one this model actually offers. Servers accept an
  /// unknown variant silently, which then quietly does nothing.
  bool supportsVariant(String variant) => variants.contains(variant);

  static double? _asDouble(Object? v) => v is num ? v.toDouble() : null;
}

// --- agents -----------------------------------------------------------------

/// What an agent is for, as the server classifies it.
enum AgentMode {
  /// A full participant: this is the one you talk to.
  primary,

  /// An internal worker the primary agents spawn. Selecting one as your session
  /// agent is possible but rarely what you want.
  subagent,

  /// Not classified by the server.
  other;

  static AgentMode parse(String? value) => switch (value) {
    'primary' => AgentMode.primary,
    'subagent' => AgentMode.subagent,
    _ => AgentMode.other,
  };
}

/// One agent the server offers.
class AgentInfo {
  const AgentInfo({
    required this.id,
    required this.name,
    required this.mode,
    required this.hidden,
    this.description = '',
    this.color,
  });

  factory AgentInfo.fromJson(Map<String, Object?> json) => AgentInfo(
    id: _str(json['id']) ?? '',
    name: _str(json['name']) ?? '',
    mode: AgentMode.parse(_str(json['mode'])),
    hidden: json['hidden'] == true,
    description: _str(json['description']) ?? '',
    color: _str(json['color']),
  );

  final String id;
  final String name;
  final AgentMode mode;
  final bool hidden;
  final String description;
  final String? color;

  /// Whether this agent is worth offering as the session's agent.
  ///
  /// `POST /api/session/{id}/agent` accepts any string at all - an id that does
  /// not exist is stored as happily as a real one - so the list has to come
  /// from the server and be filtered here. Hidden agents are bookkeeping
  /// (compaction, title, summary); subagents are workers, not conversation
  /// partners.
  bool get isSelectable => !hidden && mode == AgentMode.primary;

  @override
  String toString() => 'AgentInfo($id, ${mode.name})';
}

/// The agents worth putting in front of someone, in a stable order.
List<AgentInfo> selectableAgents(List<AgentInfo> agents) {
  final selectable = agents.where((a) => a.isSelectable).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return selectable;
}

/// A model selection: which model, and at which reasoning effort.
class ModelRef {
  const ModelRef({
    required this.id,
    required this.providerID,
    this.variant,
  });

  factory ModelRef.fromJson(Map<String, Object?> json) => ModelRef(
    id: _str(json['id']) ?? '',
    providerID: _str(json['providerID']) ?? '',
    variant: _str(json['variant']),
  );

  final String id;
  final String providerID;
  final String? variant;

  Map<String, Object?> toJson() => {
    'id': id,
    'providerID': providerID,
    if (variant != null && variant!.isNotEmpty) 'variant': variant,
  };

  ModelRef copyWith({String? variant}) => ModelRef(
    id: id,
    providerID: providerID,
    variant: variant ?? this.variant,
  );

  String get key => '$providerID/$id';

  @override
  bool operator ==(Object other) =>
      other is ModelRef &&
      other.id == id &&
      other.providerID == providerID &&
      other.variant == variant;

  @override
  int get hashCode => Object.hash(id, providerID, variant);
}

/// Reasoning efforts, ordered from cheapest to most thorough. Used to sort
/// whatever a model declares, including names we have not seen before.
const reasoningOrder = <String>[
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

int reasoningRank(String variant) {
  final index = reasoningOrder.indexOf(variant.toLowerCase());
  return index < 0 ? reasoningOrder.length : index;
}

/// Orders variants best-first and drops anything the model does not declare.
List<String> usableVariants(ModelInfo model, {String? current}) {
  final ordered = [...model.variants]..sort(
    (a, b) => reasoningRank(a).compareTo(reasoningRank(b)),
  );
  return ordered;
}
