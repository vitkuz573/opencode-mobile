import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/events.dart';
import '../data/models.dart';
import '../data/pairing.dart';
import '../data/stats.dart';
import 'profile_store.dart';

enum ConnectionPhase { idle, connecting, connected, error }

class ConnectionState {
  const ConnectionState({
    this.phase = ConnectionPhase.idle,
    this.profile,
    this.info,
    this.error,
    this.knownProfiles = const [],
  });

  final ConnectionPhase phase;
  final ServerProfile? profile;
  final ServerInfo? info;
  final String? error;
  final List<ServerProfile> knownProfiles;

  bool get isConnected => phase == ConnectionPhase.connected && profile != null;

  ConnectionState copyWith({
    ConnectionPhase? phase,
    ServerProfile? profile,
    ServerInfo? info,
    String? error,
    List<ServerProfile>? knownProfiles,
    bool clearError = false,
  }) => ConnectionState(
    phase: phase ?? this.phase,
    profile: profile ?? this.profile,
    info: info ?? this.info,
    error: clearError ? null : (error ?? this.error),
    knownProfiles: knownProfiles ?? this.knownProfiles,
  );
}

final profileStoreProvider = Provider<ProfileStore>((ref) => ProfileStore());

final connectionProvider =
    AsyncNotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

/// Owns the active connection: loads remembered profiles, probes the server,
/// and remembers what was last used.
class ConnectionController extends AsyncNotifier<ConnectionState> {
  OpenCodeApi? _api;
  String? _apiKey;

  @override
  Future<ConnectionState> build() async {
    final store = ref.read(profileStoreProvider);
    final profiles = await store.loadAll();
    final activeUrl = await store.loadActiveBaseUrl();

    ServerProfile? active;
    for (final profile in profiles) {
      if (profile.baseUrl == activeUrl) active = profile;
    }
    active ??= profiles.isNotEmpty ? profiles.first : null;

    if (active == null) {
      return ConnectionState(knownProfiles: profiles);
    }

    // Try to restore the previous session. A failure is not fatal — the connect
    // screen lets the user retry or edit the profile.
    try {
      final info = await apiFor(active).info();
      // Restoring a previous connection is a connection too: the addresses it
      // advertises are the ones a later pairing link can fall back to.
      await _rememberHosts(info);
      return ConnectionState(
        phase: ConnectionPhase.connected,
        profile: active,
        info: info,
        knownProfiles: profiles,
      );
    } on ApiException catch (error) {
      return ConnectionState(
        phase: ConnectionPhase.error,
        profile: active,
        error: error.message,
        knownProfiles: profiles,
      );
    }
  }

  String _keyOf(ServerProfile profile) =>
      '${profile.baseUrl}|${profile.authMode.name}|${profile.secret}';

  /// One client per distinct profile, so widget rebuilds never open new
  /// connection pools.
  OpenCodeApi apiFor(ServerProfile profile) {
    final key = _keyOf(profile);
    final cached = _api;
    if (cached != null && _apiKey == key) return cached;
    final created = OpenCodeApi.forProfile(profile);
    _api = created;
    _apiKey = key;
    return created;
  }

  Future<bool> connect(ServerProfile profile) async {
    final current = state.value;
    state = AsyncData(
      (current ?? const ConnectionState()).copyWith(
        phase: ConnectionPhase.connecting,
        profile: profile,
        clearError: true,
      ),
    );
    try {
      final info = await apiFor(profile).info();
      // Remember the version and the moment, so the list can show both without
      // reconnecting to each server.
      final existing = (await ref.read(profileStoreProvider).loadAll())
          .firstWhere(
            (p) => p.baseUrl == profile.baseUrl,
            orElse: () => profile,
          );
      final stamped = profile.copyWith(
        label: profile.label.isEmpty ? existing.label : profile.label,
        lastUsedAt: DateTime.now().millisecondsSinceEpoch,
        version: info.version,
      );
      final profiles = await _remember(stamped);
      await _rememberHosts(info);
      await ref.read(profileStoreProvider).saveActiveBaseUrl(stamped.baseUrl);
      state = AsyncData(
        ConnectionState(
          phase: ConnectionPhase.connected,
          profile: stamped,
          info: info,
          knownProfiles: profiles,
        ),
      );
      return true;
    } on ApiException catch (error) {
      state = AsyncData(
        (current ?? const ConnectionState()).copyWith(
          phase: ConnectionPhase.error,
          profile: profile,
          error: error.message,
        ),
      );
      return false;
    }
  }

  Future<void> _rememberHosts(ServerInfo info) {
    return ref
        .read(profileStoreProvider)
        .rememberRemoteHosts(info.urls.where((u) => u.startsWith('https://')));
  }

  Future<List<ServerProfile>> _remember(ServerProfile profile) async {
    final store = ref.read(profileStoreProvider);
    final existing = await store.loadAll();
    final updated = <ServerProfile>[
      profile,
      ...existing.where((p) => p.baseUrl != profile.baseUrl),
    ];
    await store.saveAll(updated);
    return updated;
  }

  /// Gives a saved server a name the user picked.
  ///
  /// A blank name is allowed and means "no name": the list falls back to the
  /// host, which is a better default than an empty row.
  Future<void> rename(ServerProfile profile, String label) async {
    final store = ref.read(profileStoreProvider);
    final trimmed = label.trim();
    final updated = (await store.loadAll())
        .map(
          (p) => p.baseUrl == profile.baseUrl
              ? p.copyWith(label: trimmed)
              : p,
        )
        .toList(growable: false);
    await store.saveAll(updated);

    final current = state.value;
    // Keep the live connection pointing at the same profile object, renamed.
    final active = current?.profile;
    state = AsyncData(
      (current ?? const ConnectionState()).copyWith(
        profile: active != null && active.baseUrl == profile.baseUrl
            ? active.copyWith(label: trimmed)
            : active,
        knownProfiles: updated,
      ),
    );
  }

  /// Makes a server the one restored on launch.
  Future<void> setDefault(ServerProfile profile) async {
    await ref.read(profileStoreProvider).saveActiveBaseUrl(profile.baseUrl);
  }

  /// Orders the list the way a person scans it: the server in use first, then
  /// named ones, then the rest, each group by most recent use.
  List<ServerProfile> orderedProfiles() {
    final profiles = state.value?.knownProfiles ?? const <ServerProfile>[];
    final activeUrl = state.value?.profile?.baseUrl;
    final copy = [...profiles];
    copy.sort((a, b) {
      final activeA = a.baseUrl == activeUrl;
      final activeB = b.baseUrl == activeUrl;
      if (activeA != activeB) return activeA ? -1 : 1;
      final namedA = a.isNamed;
      final namedB = b.isNamed;
      if (namedA != namedB) return namedA ? -1 : 1;
      final byUse = b.lastUsedAt.compareTo(a.lastUsedAt);
      if (byUse != 0) return byUse;
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return copy;
  }

  void disconnect() {
    _api = null;
    _apiKey = null;
    state = AsyncData(
      ConnectionState(
        knownProfiles: state.value?.knownProfiles ?? const [],
      ),
    );
  }

  Future<void> forget(ServerProfile profile) async {
    final store = ref.read(profileStoreProvider);
    final remaining = (await store.loadAll())
        .where((p) => p.baseUrl != profile.baseUrl)
        .toList(growable: false);
    await store.saveAll(remaining);
    final wasActive = state.value?.profile?.baseUrl == profile.baseUrl;
    if (wasActive) {
      _api = null;
      _apiKey = null;
    }
    state = AsyncData(
      (state.value ?? const ConnectionState()).copyWith(
        phase: ConnectionPhase.idle,
        profile: wasActive ? null : state.value?.profile,
        knownProfiles: remaining,
        clearError: true,
      ),
    );
  }
}

/// Active client, or `null` when nothing is connected.
final apiProvider = Provider<OpenCodeApi?>((ref) {
  final profile = ref.watch(connectionProvider).value?.profile;
  if (profile == null) return null;
  return ref.read(connectionProvider.notifier).apiFor(profile);
});

/// Owns the single SSE subscription. Screens read from it instead of opening
/// their own: the server pushes every event to every client.
class LiveEvents {
  LiveEvents(this.stream, {this.logLimit = 2000});

  final EventStream stream;

  /// Events are kept so derived state can be rebuilt without a refetch. The
  /// log is capped: a phone session is long, the server is chatty, and nothing
  /// in the UI ever scrolls further back than this.
  final int logLimit;
}

/// One subscription, one accumulating log.
class EventLog {
  EventLog(this.live);

  final LiveEvents live;
  final List<ServerEvent> _events = [];
  final StreamController<List<ServerEvent>> _controller =
      StreamController<List<ServerEvent>>.broadcast();

  StreamSubscription<ServerEvent>? _subscription;
  int _listenerCount = 0;

  Stream<List<ServerEvent>> get snapshots => _controller.stream;

  List<ServerEvent> get events => List.unmodifiable(_events);

  void _attach() {
    if (_listenerCount++ == 0) {
      _subscription = live.stream.events.listen(_onEvent);
    }
    _controller.add(events);
  }

  void _onEvent(ServerEvent event) {
    _events.add(event);
    if (_events.length > live.logLimit) {
      _events.removeRange(0, _events.length - live.logLimit);
    }
    _controller.add(events);
  }

  Future<void> _detach() async {
    if (--_listenerCount <= 0) {
      _listenerCount = 0;
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}

final liveEventsProvider = Provider<LiveEvents?>((ref) {
  final api = ref.watch(apiProvider);
  if (api == null) return null;
  final stream = EventStream(dio: api.raw);
  ref.onDispose(stream.dispose);
  unawaited(stream.start());
  return LiveEvents(stream);
});

final eventLogProvider = Provider<EventLog?>((ref) {
  final live = ref.watch(liveEventsProvider);
  if (live == null) return null;
  final log = EventLog(live);
  ref.onDispose(log.dispose);
  return log;
});

/// Growing snapshot list, so every derived provider can fold the whole log.
final eventsProvider = StreamProvider<List<ServerEvent>>((ref) {
  final log = ref.watch(eventLogProvider);
  if (log == null) return const Stream<List<ServerEvent>>.empty();
  late final StreamController<List<ServerEvent>> controller;
  StreamSubscription<List<ServerEvent>>? subscription;
  controller = StreamController<List<ServerEvent>>.broadcast(
    onListen: () {
      log._attach();
      subscription = log.snapshots.listen(controller.add, onError: controller.addError);
    },
    onCancel: () async {
      await subscription?.cancel();
      await log._detach();
    },
  );
  ref.onDispose(controller.close);
  return controller.stream;
});

final eventStatusProvider = StreamProvider<EventStreamStatus>((ref) {
  final live = ref.watch(liveEventsProvider);
  if (live == null) {
    return Stream.value(
      const EventStreamStatus(StreamStatus.idle, message: 'Not connected'),
    );
  }
  return live.stream.status;
});

/// Addresses this device has already reached on this server.
final remoteHostsProvider = FutureProvider<List<String>>((ref) async {
  final stored = await ref.read(profileStoreProvider).loadRemoteHosts();
  // A profile the user already paired with is, by definition, an address this
  // device reached - useful as a fallback even if nothing was stored yet.
  final fromProfiles = (ref.watch(connectionProvider).value?.knownProfiles ??
          const <ServerProfile>[])
      .map((p) => p.baseUrl)
      .where((url) => url.startsWith('https://'))
      .where((url) => !PairingLink.isLoopback(url));
  return {...stored, ...fromProfiles}.toList(growable: false);
});

final projectsProvider = FutureProvider<List<Project>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return const [];
  return api.projects();
});

// --- usage -----------------------------------------------------------------

/// Which window the usage screen reports on.
class UsageRange extends Notifier<StatsRange> {
  @override
  StatsRange build() => StatsRange.month;

  void select(StatsRange range) => state = range;
}

final usageRangeProvider =
    NotifierProvider<UsageRange, StatsRange>(UsageRange.new);

/// What the server did in the selected window. Refetched whenever the window
/// changes, and never cached beyond that: the numbers move as you work.
final usageProvider = FutureProvider<ServerStats>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return ServerStats.empty;
  final range = ref.watch(usageRangeProvider);
  return api.stats(range: range);
});

/// The agents this server offers, already reduced to the ones a person can
/// meaningfully pick.
final agentsProvider = FutureProvider<List<AgentInfo>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return const [];
  final directory = ref.watch(selectedDirectoryProvider);
  return selectableAgents(await api.agents(directory: directory));
});

/// Directory the session list is scoped to; `null` means the server default.
class SelectedDirectory extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? directory) => state = directory;
}

final selectedDirectoryProvider =
    NotifierProvider<SelectedDirectory, String?>(SelectedDirectory.new);

final sessionsProvider = FutureProvider<List<SessionSummary>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return const [];
  final directory = ref.watch(selectedDirectoryProvider);
  final page = await api.sessions(directory: directory, limit: 100);
  return page.items;
});

List<ServerEvent> _eventsOf(Ref ref) =>
    ref.watch(eventsProvider).value ?? const <ServerEvent>[];

/// Session ids with a live execution, derived from the event log.
final runningSessionIdsProvider = Provider<Set<String>>((ref) {
  final running = <String>{};
  for (final event in _eventsOf(ref)) {
    switch (event.type) {
      case Ev.executionStarted:
        if (event.sessionId.isNotEmpty) running.add(event.sessionId);
      case Ev.executionSucceeded:
      case Ev.executionInterrupted:
        running.remove(event.sessionId);
    }
  }
  return running;
});

/// Titles learned from live events, so a renamed session updates in place.
final sessionRenamesProvider = Provider<Map<String, String>>((ref) {
  final titles = <String, String>{};
  for (final event in _eventsOf(ref)) {
    if (event.type != Ev.sessionRenamed) continue;
    final id = event.sessionId;
    final title = event.data['title'];
    if (id.isNotEmpty && title is String) titles[id] = title;
  }
  return titles;
});

/// Permission requests that have not been answered yet.
final permissionInboxProvider = Provider<List<PermissionRequest>>((ref) {
  final open = <PermissionRequest>[];
  final answered = <String>{};
  for (final event in _eventsOf(ref)) {
    if (event.type == Ev.permissionAsked) {
      final request = event.asPermissionRequest;
      if (request != null && !answered.contains(request.id)) {
        open.add(request);
      }
    } else if (event.type == Ev.permissionReplied) {
      final id = event.data['requestID'];
      if (id is String) answered.add(id);
    }
  }
  open.sort((a, b) => b.id.compareTo(a.id));
  return open;
});