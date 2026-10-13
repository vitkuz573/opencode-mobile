import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
// Flutter has its own ConnectionState (from async.dart); this sheet only needs
// the API provider from our state layer.
import '../state/providers.dart' hide ConnectionState;
import 'widgets.dart';

/// Picks the model and its reasoning effort for a session.
///
/// Reasoning effort is a model *variant*: `space-bunny-free` declares
/// `low, medium, high, xhigh, max`, another model declares only `high`, and a
/// third declares none at all. The server accepts an unknown variant and
/// silently does nothing, so the levels shown always come from the model's own
/// list.
///
/// Two steps instead of a chip row under every model: choose the effort for the
/// model you are on, then choose a model. Repeating the same five chips under
/// fifty-two rows turned the list into noise.
Future<void> showModelPicker(
  BuildContext context, {
  required String sessionId,
  required ModelRef? current,
  required String? directory,
  required Future<void> Function(ModelRef model) onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ModelPicker(
      sessionId: sessionId,
      current: current,
      directory: directory,
      onSelected: onSelected,
    ),
  );
}

class _ModelPicker extends ConsumerStatefulWidget {
  const _ModelPicker({
    required this.sessionId,
    required this.current,
    required this.directory,
    required this.onSelected,
  });

  final String sessionId;
  final ModelRef? current;
  final String? directory;
  final Future<void> Function(ModelRef model) onSelected;

  @override
  ConsumerState<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends ConsumerState<_ModelPicker> {
  late Future<List<ModelInfo>> _models;

  /// The model whose variants the reasoning row describes. Not necessarily the
  /// model the session is on yet - it is the one being edited.
  ModelInfo? _selected;
  String? _busyKey;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _models = _load();
  }

  Future<List<ModelInfo>> _load() async {
    final api = ref.read(apiProvider);
    if (api == null) return const [];
    return api.models(directory: widget.directory);
  }

  Future<void> _apply(ModelInfo model, String? variant) async {
    final carried = variant ?? widget.current?.variant;
    // Carrying the level across is the least surprising thing to do, but only
    // when the new model actually declares that level.
    final target = model.supportsVariant(carried ?? '')
        ? ModelRef(id: model.id, providerID: model.providerID, variant: carried)
        : ModelRef(id: model.id, providerID: model.providerID);

    setState(() {
      _selected = model;
      _busyKey = '${model.key}|${target.variant ?? ''}';
    });
    try {
      await widget.onSelected(target);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  List<ModelInfo> _filter(List<ModelInfo> models) {
    if (_query.trim().isEmpty) return models;
    final q = _query.trim().toLowerCase();
    return models
        .where(
          (m) =>
              m.name.toLowerCase().contains(q) ||
              m.id.toLowerCase().contains(q) ||
              m.providerID.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return FutureBuilder<List<ModelInfo>>(
          future: _models,
          builder: (context, snapshot) {
            final all = snapshot.data ?? const <ModelInfo>[];

            // Default the reasoning row to the session's model as soon as the
            // list arrives, so the first frame is already meaningful.
            final selected = _selected ?? _initialSelection(all);

            if (snapshot.connectionState == ConnectionState.waiting && all.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError && all.isEmpty) {
              return EmptyState(
                icon: Icons.cloud_off,
                title: 'Cannot load models',
                message: '${snapshot.error}',
                action: FilledButton.tonal(
                  onPressed: () => setState(() => _models = _load()),
                  child: const Text('Retry'),
                ),
              );
            }

            final visible = _filter(all);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Model & reasoning',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search models',
                          prefixIcon: Icon(Icons.search, size: 18),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      if (selected != null) ...[
                        const SizedBox(height: 22),
                        _ReasoningSection(
                          model: selected,
                          current: widget.current,
                          busyKey: _busyKey,
                          onPick: (level) => _apply(selected, level),
                        ),
                      ],
                      const SizedBox(height: 22),
                      _SectionLabel(
                        label: _query.trim().isEmpty
                            ? 'All models'
                            : '${visible.length} matching',
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off,
                          title: 'Nothing matches "$_query"',
                        )
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 28),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 2),
                          itemBuilder: (context, index) {
                            final model = visible[index];
                            return _ModelRow(
                              model: model,
                              active: widget.current?.key == model.key,
                              busy:
                                  _busyKey ==
                                  '${model.key}|${widget.current?.variant ?? ''}',
                              onTap: () => _apply(model, null),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  ModelInfo? _initialSelection(List<ModelInfo> models) {
    if (models.isEmpty) return null;
    final current = widget.current;
    if (current == null) return models.first;
    for (final model in models) {
      if (model.key == current.key) return model;
    }
    return models.first;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// Reasoning effort for one model. The label names the model so the row is
/// never ambiguous about what the levels apply to.
class _ReasoningSection extends StatelessWidget {
  const _ReasoningSection({
    required this.model,
    required this.current,
    required this.busyKey,
    required this.onPick,
  });

  final ModelInfo model;
  final ModelRef? current;
  final String? busyKey;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levels = usableVariants(model);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Reasoning',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: Text(
                model.name.isEmpty ? model.id : model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          levels.isEmpty
              ? 'This model has a single setting - no effort levels to choose.'
              : 'Lower levels cost fewer tokens and answer faster.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (levels.isEmpty)
          const SizedBox.shrink()
        else
          Wrap(
            spacing: 7,
            runSpacing: 8,
            children: [
              for (final level in levels)
                _LevelChip(
                  label: level,
                  selected: _isActive(level),
                  busy: busyKey == '${model.key}|$level',
                  onTap: () => onPick(level),
                ),
            ],
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  bool _isActive(String level) {
    if (current?.key != model.key) return false;
    // A session on this model with no explicit level is on the default, which
    // the server reports as absent; show the first level as the closest thing.
    if (current?.variant == null) return level == usableVariants(model).first;
    return current!.variant == level;
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          // No `alignment` here: a Container with alignment expands to the
          // incoming constraints, which stretched every chip full width.
          constraints: const BoxConstraints(minWidth: 54),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Center(
            widthFactor: 1,
            child: busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimary,
                    ),
                  )
                : Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: selected
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.active,
    required this.busy,
    required this.onTap,
  });

  final ModelInfo model;
  final bool active;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.28)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name.isEmpty ? model.id : model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: active ? FontWeight.w600 : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        model.providerID,
                        if (model.contextLimit > 0)
                          '${formatTokens(model.contextLimit)} ctx',
                        if (model.costIn != null && model.costIn! > 0)
                          '\$${model.costIn!.toStringAsFixed(2)}/M in',
                      ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (active)
                Icon(Icons.check_circle, size: 20, color: scheme.primary)
              else if (model.hasVariants)
                Icon(
                  Icons.tune,
                  size: 16,
                  color: scheme.outlineVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}