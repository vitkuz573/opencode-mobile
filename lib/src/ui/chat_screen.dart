import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/events.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../state/timeline.dart';
import 'model_picker_sheet.dart';
import 'agent_picker_sheet.dart';
import 'widgets.dart';

/// Opens a session by id, for callers that only know the id (permission
/// requests, notifications, deep links).
Future<void> openSessionById(
  BuildContext context, {
  required String sessionId,
  String title = 'Session',
  String? directory,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        sessionId: sessionId,
        title: title,
        directory: directory,
      ),
    ),
  );
}

/// One conversation: history from the server plus live deltas from the event
/// stream, folded by the pure reducer in `state/timeline.dart`.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.sessionId,
    required this.title,
    this.directory,
    this.model,
    this.agent,
  });

  final String sessionId;
  final String title;
  final String? directory;

  /// Known up front from the session list, so the chip shows immediately
  /// instead of waiting for a round trip.
  final ModelRef? model;

  /// Which agent the session talks to, when the caller already knows.
  final String? agent;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<ServerEvent>? _subscription;

  Timeline _timeline = const Timeline();
  late ModelRef? _model;
  late String? _agent;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _model = widget.model;
    _agent = widget.agent;
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    if (api == null) {
      setState(() {
        _loading = false;
        _error = 'Not connected';
      });
      return;
    }
    try {
      final messages = await api.messages(
        widget.sessionId,
        directory: widget.directory,
      );
      ModelRef? model = _model;
      var agent = _agent;
      try {
        final summary = await api.session(widget.sessionId);
        if (summary.modelId != null) {
          model = ModelRef(
            id: summary.modelId!,
            providerID: summary.modelProvider ?? 'opencode',
            variant: summary.modelVariant,
          );
        }
        // A session that never ran reports no agent, which is the normal case:
        // the server picks the default one on the first turn.
        if (summary.agent != null && summary.agent!.isNotEmpty) {
          agent = summary.agent;
        }
      } catch (error) {
        // The chips are a nicety: a session that will not describe itself still
        // opens, with whatever the list already told us.
        debugPrint('session lookup failed: $error');
      }
      if (!mounted) return;
      setState(() {
        _timeline = Timeline(messages: messages);
        _model = model;
        _agent = agent;
        _loading = false;
      });
      _scrollToEnd();
      _listen();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  void _listen() {
    _subscription ??= ref
        .read(liveEventsProvider)
        ?.stream
        .events
        .where((event) => event.sessionId == widget.sessionId)
        .listen(_onEvent);
  }

  void _onEvent(ServerEvent event) {
    final next = applyEvent(_timeline, event, sessionId: widget.sessionId);
    final grew = next.messages.length != _timeline.messages.length;
    setState(() => _timeline = next);
    if (grew) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final api = ref.read(apiProvider);
    if (api == null) return;

    setState(() => _sending = true);
    _controller.clear();
    try {
      await api.sendPrompt(
        widget.sessionId,
        text,
        directory: widget.directory,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _stop() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      await api.interrupt(widget.sessionId, directory: widget.directory);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _pickModel() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await showModelPicker(
      context,
      sessionId: widget.sessionId,
      current: _model,
      directory: widget.directory,
      onSelected: (model) async {
        try {
          await api.setModel(
            widget.sessionId,
            model,
            directory: widget.directory,
          );
          if (!mounted) return;
          setState(() => _model = model);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Model set to ${model.id}'
                '${model.variant == null ? '' : ' (${model.variant})'}',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(content: Text('Could not switch model: $error')),
          );
          rethrow;
        }
      },
    );
  }

  Future<void> _pickAgent() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await showAgentPicker(
      context,
      sessionId: widget.sessionId,
      current: _agent,
      directory: widget.directory,
      onSelected: (agentId) async {
        try {
          await api.setAgent(
            widget.sessionId,
            agentId,
            directory: widget.directory,
          );
          if (!mounted) return;
          setState(() => _agent = agentId);
          messenger.showSnackBar(
            SnackBar(
              content: Text('Agent set to $agentId'),
              duration: const Duration(seconds: 2),
            ),
          );
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(content: Text('Could not switch agent: $error')),
          );
          rethrow;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref
        .watch(permissionInboxProvider)
        .where((p) => p.sessionId == widget.sessionId)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            // Agent and model both live here, so the row scrolls rather than overflowing
                // on a narrow screen with a long model name.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_timeline.running) ...[
                        Text(
                          'working…',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      GestureDetector(
                        onTap: _pickAgent,
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Pill(
                              label: _agent ?? 'pick an agent',
                              dense: true,
                              icon: Icons.smart_toy_outlined,
                              color: _agent == null
                                  ? Theme.of(context).colorScheme.outline
                                  : null,
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              Icons.unfold_more,
                              size: 13,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _pickModel,
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // A session that never ran still needs a way in.
                            Pill(
                              label: _model?.id ?? 'pick a model',
                              dense: true,
                              color: _model == null
                                  ? Theme.of(context).colorScheme.outline
                                  : null,
                            ),
                            if (_model?.variant != null) ...[
                              const SizedBox(width: 4),
                              Pill(
                                label: _model!.variant!,
                                dense: true,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ],
                            const SizedBox(width: 4),
                            Icon(
                              Icons.unfold_more,
                              size: 14,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        actions: [
          if (_timeline.running)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Reload history',
            onPressed: _loading
                ? null
                : () {
                    setState(() => _loading = true);
                    _load();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (pending.isNotEmpty)
            _InlinePermission(
              request: pending.first,
              onAnswer: (reply) async {
                final api = ref.read(apiProvider);
                if (api == null) return;
                await api.replyToPermission(
                  pending.first.sessionId,
                  pending.first.id,
                  reply.name,
                  directory: widget.directory,
                );
                ref.invalidate(permissionInboxProvider);
              },
            ),
          Expanded(child: _body()),
          _Composer(
            controller: _controller,
            busy: _sending,
            running: _timeline.running,
            onSend: _send,
            onStop: _stop,
          ),
        ],
      ),
    );
  }

  /// True when this assistant turn continues the previous one with the same
  /// agent and model, which is what a tool-call sequence looks like.
  static bool _isRedundantHeader(List<ChatMessage> messages, int index) {
    final current = messages[index];
    if (current is! AssistantMessage || index == 0) return false;
    final previous = messages[index - 1];
    return previous is AssistantMessage &&
        previous.agent == current.agent &&
        previous.modelId == current.modelId;
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Cannot open this session',
        message: _error,
        action: FilledButton.tonal(
          onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _load();
          },
          child: const Text('Retry'),
        ),
      );
    }

    final visible = _timeline.messages
        .where((m) => m is! UnknownMessage || m.isVisible)
        .toList(growable: false);
    if (visible.isEmpty) {
      return const EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: 'Start the conversation',
        message: 'Ask something below. Approval prompts arrive here too.',
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: visible.length + 1,
      itemBuilder: (context, index) {
        if (index == visible.length) return _UsageFooter(timeline: _timeline);
        final message = visible[index];
        return MessageBlock(
          message: message,
          suppressHeader: _isRedundantHeader(visible, index),
        );
      },
    );
  }
}

// --- messages ---------------------------------------------------------------

class MessageBlock extends StatelessWidget {
  const MessageBlock({super.key, required this.message, this.suppressHeader = false});

  final ChatMessage message;

  /// The server emits one assistant message per tool call, so the agent and
  /// model would otherwise repeat above every card. The list decides when the
  /// header is redundant.
  final bool suppressHeader;

  @override
  Widget build(BuildContext context) {
    return switch (message) {
      UserMessage(:final text) => _UserBubble(text: text),
      SystemMessage(:final text) => _Note(text: text),
      final AssistantMessage m => _AssistantTurn(
        message: m,
        showHeader: !suppressHeader,
      ),
      final UnknownMessage m => _Note(text: m.text ?? m.kind),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, left: 44),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              height: 1.45,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

/// Centred, quiet annotation. Used for system lines and for structural events
/// such as an aborted step, which are not failures.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.message, required this.showHeader});

  final AssistantMessage message;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = message.parts.where((p) {
      if (p is TextPart) return p.text.trim().isNotEmpty;
      if (p is ReasoningPart) return p.text.trim().isNotEmpty;
      return true;
    }).toList(growable: false);

    final waiting = parts.isEmpty && message.error == null;
    final showHeader = this.showHeader &&
        parts.isNotEmpty &&
        (message.agent.isNotEmpty || message.modelId.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 2),
              child: Row(
                children: [
                  if (message.agent.isNotEmpty)
                    Pill(label: message.agent, dense: true),
                  if (message.agent.isNotEmpty && message.modelId.isNotEmpty)
                    const SizedBox(width: 6),
                  if (message.modelId.isNotEmpty)
                    Flexible(
                      child: Pill(
                        label: message.modelId,
                        dense: true,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
            ),
          if (waiting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          for (final part in parts) ...[
            switch (part) {
              TextPart(:final text) => _RichText(text: text),
              ReasoningPart(:final text) => _Reasoning(text: text),
              ToolPart() => _ToolCard(tool: part),
            },
            const SizedBox(height: 4),
          ],
          if (message.error != null)
            _ErrorNote(message: message.error!, aborted: message.isAborted),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message, required this.aborted});

  final String message;
  final bool aborted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = aborted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            aborted ? Icons.info_outline : Icons.error_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal markdown: paragraphs, bullets, headings, fenced code and inline
/// spans. A full renderer is a dependency this app does not need.
class _RichText extends StatelessWidget {
  const _RichText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocks = <Widget>[];

    for (final chunk in _splitBlocks(text)) {
      final trimmed = chunk.trim();
      if (trimmed.isEmpty) continue;

      final fence = RegExp(
        r'^```(\w*)\n?([\s\S]*?)(?:```)?$',
      ).firstMatch(trimmed);
      if (fence != null) {
        blocks.add(
          _CodeBlock(
            language: (fence.group(1) ?? '').toLowerCase(),
            code: (fence.group(2) ?? '').trimRight(),
          ),
        );
        continue;
      }

      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              heading.group(2) ?? '',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
        continue;
      }

      final lines = trimmed.split('\n');
      if (lines.length > 1 && _isList(lines)) {
        blocks.add(_ListBlock(lines: lines));
        continue;
      }

      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _InlineSpan(
            text: trimmed,
            style: theme.textTheme.bodyMedium!.copyWith(
              fontSize: 15,
              height: 1.5,
            ),
            codeStyle: theme.textTheme.bodySmall!.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }

  static bool _isList(List<String> lines) => lines.every(
    (l) => RegExp(
      r'^\s*([-*•]|\d+\.)\s+',
    ).hasMatch(l),
  );

  static List<String> _splitBlocks(String text) =>
      text.split(RegExp(r'\n{2,}')).toList(growable: false);
}

class _ListBlock extends StatelessWidget {
  const _ListBlock({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 8),
                  child: _bullet(line, theme),
                ),
                Expanded(
                  child: _InlineSpan(
                    text: _stripMarker(line),
                    style: theme.textTheme.bodyMedium!.copyWith(
                      fontSize: 15,
                      height: 1.45,
                    ),
                    codeStyle: theme.textTheme.bodySmall!.copyWith(
                      fontFamily: 'monospace',
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bullet(String line, ThemeData theme) {
    final match = RegExp(r'^\s*([-*•]|\d+\.)').firstMatch(line);
    final marker = match?.group(1) ?? '-';
    if (marker == '-') {
      return Text(
        '•',
        style: theme.textTheme.bodyMedium?.copyWith(
          height: 1.1,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Text(
      marker,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  static String _stripMarker(String line) =>
      line.replaceFirst(RegExp(r'^\s*([-*•]|\d+\.)\s+'), '');
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});

  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Code copied'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                code,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders `code`, **bold** and *italic* spans without pulling in a markdown
/// dependency.
class _InlineSpan extends StatelessWidget {
  const _InlineSpan({
    required this.text,
    required this.style,
    required this.codeStyle,
  });

  final String text;
  final TextStyle style;
  final TextStyle codeStyle;

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(children: _parse(text, 0)), style: style);
  }

  static final _pattern = RegExp(
    r'(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)',
  );

  List<InlineSpan> _parse(String input, int depth) {
    if (depth > 4) return [TextSpan(text: input)];
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _pattern.allMatches(input)) {
      if (match.start > last) {
        spans.add(TextSpan(text: input.substring(last, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: codeStyle,
          ),
        );
      } else if (token.startsWith('**')) {
        // A span with children must not also carry text: Flutter renders the
        // text first and then the children, which duplicates the content.
        spans.add(
          TextSpan(
            style: const TextStyle(fontWeight: FontWeight.w600),
            children: _parse(
              token.substring(2, token.length - 2),
              depth + 1,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      last = match.end;
    }
    if (last < input.length) {
      spans.add(TextSpan(text: input.substring(last)));
    }
    return spans;
  }
}

class _Reasoning extends StatelessWidget {
  const _Reasoning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(left: 26, bottom: 8),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            Icons.psychology_alt_outlined,
            size: 16,
            color: theme.colorScheme.outline,
          ),
          title: Text(
            'Reasoning',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.tool});

  final ToolPart tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color, status) = switch (tool.status) {
      ToolStatus.completed => (
        Icons.check_circle_outline,
        Colors.green.shade600,
        'done',
      ),
      ToolStatus.error => (Icons.error_outline, scheme.error, 'failed'),
      ToolStatus.running => (
        Icons.play_circle_outline,
        scheme.primary,
        'running',
      ),
      ToolStatus.pending => (Icons.more_horiz, scheme.outline, 'queued'),
    };

    final hasDetail = tool.input.isNotEmpty || tool.output.isNotEmpty;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          shape: const Border(),
          collapsedShape: const Border(),
          enabled: hasDetail,
          leading: Icon(icon, size: 16, color: color),
          title: Row(
            children: [
              Text(
                tool.name,
                style: theme.textTheme.labelLarge?.copyWith(height: 1.2),
              ),
              const SizedBox(width: 8),
              Pill(label: status, dense: true, color: color),
            ],
          ),
          subtitle: tool.error == null
              ? Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _summarise(tool),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tool.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
          children: [
            if (tool.output.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    tool.output,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _summarise(ToolPart tool) {
    if (tool.error != null) return tool.error!;
    if (tool.input.isEmpty) return tool.output;
    final parts = tool.input.entries.take(3).map((e) {
      final value = e.value;
      final rendered = value is String
          ? (value.length > 48 ? '${value.substring(0, 48)}…' : value)
          : '$value';
      return '${e.key}=${rendered.isEmpty ? '""' : rendered}';
    });
    return parts.join('  ');
  }
}

class _UsageFooter extends StatelessWidget {
  const _UsageFooter({required this.timeline});

  final Timeline timeline;

  @override
  Widget build(BuildContext context) {
    final tokens = timeline.tokens;
    if (tokens == null && timeline.cost == 0) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4, left: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (tokens != null) ...[
            Pill(label: 'in ${formatTokens(tokens.input)}', dense: true),
            Pill(label: 'out ${formatTokens(tokens.output)}', dense: true),
            if (tokens.cacheRead > 0)
              Pill(
                label: 'cache ${formatTokens(tokens.cacheRead)}',
                dense: true,
                icon: Icons.bolt,
              ),
          ],
          if (timeline.cost > 0)
            Pill(
              label: formatCost(timeline.cost),
              dense: true,
              icon: Icons.payments_outlined,
            ),
        ],
      ),
    );
  }
}

class _InlinePermission extends StatelessWidget {
  const _InlinePermission({required this.request, required this.onAnswer});

  final PermissionRequest request;
  final Future<void> Function(PermissionReply reply) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Colors.orange.shade700;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_maybe_outlined, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  request.headline,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (request.resources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 26, bottom: 2),
              child: Text(
                request.resources.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onAnswer(PermissionReply.reject),
                  child: const Text('Deny'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onAnswer(PermissionReply.always),
                  child: const Text('Always'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => onAnswer(PermissionReply.once),
                  child: const Text('Allow'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.running,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool busy;
  final bool running;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Message the agent…',
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHigh,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 46,
                child: running
                    ? IconButton.filledTonal(
                        onPressed: onStop,
                        tooltip: 'Stop',
                        icon: const Icon(Icons.stop_rounded),
                      )
                    : IconButton.filled(
                        onPressed: busy ? null : onSend,
                        tooltip: 'Send',
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}