import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/api.dart';
import '../data/models.dart';

/// Shows one interactive form and sends the answers.
///
/// The agent stalls until someone answers, so this is shaped like the
/// permission sheet: same modal, same send/error dance, but the body is the
/// form's own fields instead of three fixed replies.
Future<void> showFormSheet(
  BuildContext context, {
  required FormRequest request,
  required OpenCodeApi? api,
  required String? directory,
  VoidCallback? onReplied,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _FormSheet(
      request: request,
      api: api,
      directory: directory,
      onReplied: onReplied,
    ),
  );
}

class _FormSheet extends StatefulWidget {
  const _FormSheet({
    required this.request,
    required this.api,
    required this.directory,
    this.onReplied,
  });

  final FormRequest request;
  final OpenCodeApi? api;
  final String? directory;
  final VoidCallback? onReplied;

  @override
  State<_FormSheet> createState() => _FormSheetState();
}

class _FormSheetState extends State<_FormSheet> {
  final _textControllers = <String, TextEditingController>{};
  final _answers = <String, Object?>{};
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final field in widget.request.fields) {
      if (field.isToggle) {
        _answers[field.key] = false;
      } else if (field.defaultValue != null && !field.isMulti) {
        _answers[field.key] = field.defaultValue;
        _textControllers[field.key] = TextEditingController(
          text: field.defaultValue,
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(FormInput field) =>
      _textControllers.putIfAbsent(
        field.key,
        () => TextEditingController(
          text: _answers[field.key] is String
              ? _answers[field.key]! as String
              : '',
        ),
      );

  bool get _valid {
    for (final field in widget.request.fields) {
      if (!field.required) continue;
      final answer = _answers[field.key];
      if (field.isMulti) {
        if (answer is! List || answer.isEmpty) return false;
      } else if (field.isToggle) {
        continue; // A toggle always has a position.
      } else {
        final text = answer is String
            ? answer
            : _controllerFor(field).text;
        if (text.trim().isEmpty) return false;
        if (field.isNumeric && double.tryParse(text.trim()) == null) {
          return false;
        }
      }
    }
    return true;
  }

  Map<String, Object?> _collect() {
    final answer = <String, Object?>{};
    for (final field in widget.request.fields) {
      final stored = _answers[field.key];
      if (field.isMulti) {
        if (stored is List && stored.isNotEmpty) {
          answer[field.key] = List<String>.from(stored);
        }
      } else if (field.isToggle) {
        answer[field.key] = stored is bool ? stored : false;
      } else {
        final text = stored is String && stored.isNotEmpty
            ? stored
            : _controllerFor(field).text.trim();
        if (text.isNotEmpty) answer[field.key] = text;
      }
    }
    return answer;
  }

  Future<void> _send() async {
    final api = widget.api;
    if (api == null) {
      setState(() => _error = 'Not connected');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await api.replyToForm(
        widget.request.sessionId,
        widget.request.id,
        _collect(),
        directory: widget.directory,
      );
      widget.onReplied?.call();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    final messenger = ScaffoldMessenger.of(context);
    if (uri == null) {
      messenger.showSnackBar(SnackBar(content: Text(url)));
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) messenger.showSnackBar(SnackBar(content: Text(url)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(url)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.quiz_outlined, color: Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    request.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'The agent is waiting on your answers.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final field in request.fields) ...[
                    _FieldInput(
                      field: field,
                      controller: _controllerFor(field),
                      answer: _answers[field.key],
                      onChanged: (value) => setState(() {
                        if (value == null) {
                          _answers.remove(field.key);
                        } else {
                          _answers[field.key] = value;
                        }
                      }),
                      onOpenLink: _openLink,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sending || !_valid ? null : _send,
                child: Text(_sending ? 'Sending…' : 'Send answers'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One field. Unknown kinds fall back to text: answering approximately beats
/// refusing to render.
class _FieldInput extends StatelessWidget {
  const _FieldInput({
    required this.field,
    required this.controller,
    required this.answer,
    required this.onChanged,
    required this.onOpenLink,
  });

  final FormInput field;
  final TextEditingController controller;
  final Object? answer;
  final ValueChanged<Object?> onChanged;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Object? current = answer;
    final label = StringBuffer(field.title ?? field.key);
    if (field.required) label.write(' *');
    final header = Text(label.toString(), style: theme.textTheme.bodyMedium
        ?.copyWith(fontWeight: FontWeight.w600));

    Widget input;
    if (field.isExternal) {
      input = _ExternalRow(field: field, onOpenLink: onOpenLink);
    } else if (field.isToggle) {
      input = Row(
        children: [
          Expanded(child: header),
          Switch.adaptive(
            value: current is bool ? current : false,
            onChanged: (value) => onChanged(value),
          ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          input,
          if (field.description != null) _Hint(text: field.description!),
        ],
      );
    } else if (field.isMulti) {
      final selected = current is List
          ? current.whereType<String>().toSet()
          : <String>{};
      input = Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final option in field.options)
            FilterChip(
              label: Text(option.label),
              selected: selected.contains(option.value),
              onSelected: (on) {
                final next = <String>{...selected};
                if (on) {
                  next.add(option.value);
                } else {
                  next.remove(option.value);
                }
                onChanged(next.toList(growable: false));
              },
            ),
        ],
      );
    } else if (field.isOptions) {
      final selected = current is String ? current : null;
      input = Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final option in field.options)
            ChoiceChip(
              label: Tooltip(
                message: option.description ?? '',
                child: Text(option.label),
              ),
              selected: selected == option.value,
              onSelected: (on) =>
                  onChanged(on ? option.value : null),
            ),
        ],
      );
    } else {
      input = TextField(
        controller: controller,
        keyboardType: field.isNumeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        autocorrect: false,
        decoration: InputDecoration(
          hintText: field.placeholder,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (_) => onChanged(controller.text),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!field.isToggle) ...[header, const SizedBox(height: 6)],
        input,
        if (field.description != null) _Hint(text: field.description!),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ExternalRow extends StatelessWidget {
  const _ExternalRow({required this.field, required this.onOpenLink});

  final FormInput field;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    // An external field points somewhere instead of asking something. The key
    // doubles as the address when the payload names no URL of its own.
    final url = field.defaultValue ?? field.key;
    return Row(
      children: [
        const Icon(Icons.open_in_new, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            field.title ?? url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: () => onOpenLink(url),
          child: const Text('Open'),
        ),
      ],
    );
  }
}
