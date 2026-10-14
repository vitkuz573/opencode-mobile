import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/api.dart';
import '../data/app_log.dart';
import '../data/events.dart';
import '../data/models.dart';
import '../data/pairing.dart';
import '../data/stats.dart';
import 'local_server.dart';
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

/// The log the settings screen reads.
///
/// Mirrored to a file under the app's own directory, so it survives the app
/// being closed. The file is set as soon as the platform answers where that
/// directory is; until then the log lives in memory as it always did, which
/// covers everything the person holding the phone can see.
final appLogProvider = Provider<AppLog>((ref) {
  final log = AppLog();
  unawaited(() async {
    try {
      final support = (await getApplicationSupportDirectory()).path;
      log.file = File('$support/app.log');
      log.info('app', 'log opened at $support/app.log');
    } catch (error) {
      // A log with nowhere to be written is still a log on screen.
      log.warn('app', 'could not open a log file: $error');
    }
  }());
  return log;
});

/// Bumped whenever the log changes, so watchers rebuild.
///
/// The buffer is a mutable ring, which Riverpod cannot see through. Riverpod 3
/// dropped `StateProvider`, so this is a plain Notifier rather than the obvious
/// `StateProvider<int>`.
class AppLogRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final appLogRevisionProvider =
    NotifierProvider<AppLogRevision, int>(AppLogRevision.new);

/// The log, exposed through a provider so widgets rebuild when it grows.
final logProvider = Provider<AppLog>((ref) {
  ref.watch(appLogRevisionProvider);
  return ref.read(appLogProvider);
});

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
    // No auto-connect: the launch screen is a choice, not a resumption. A
    // server that opens itself on startup is a server the user did not ask
    // for, so every launch starts disconnected and the saved list is what
    // remembers, not what connects.
    final profiles = await ref.read(profileStoreProvider).loadAll();
    return ConnectionState(knownProfiles: profiles);
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

  Future<bool> connect(ServerProfile stored) async {
    // A server that lives in this phone mints a new password every time it
    // starts, so the one saved against its profile is always the previous one.
    // While that server is up the password it is actually using is already
    // known, and the stale one is a 401 against a server working perfectly
    // well. Nothing is started here: only the credential is corrected.
    final profile = await _withLiveLocalPassword(stored) ?? stored;
    final log = ref.read(appLogProvider);
    log.info('net', 'connecting to ${profile.displayHost} '
        '(${profile.authMode.name})');
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
      log.info('net', 'connected to ${stamped.displayHost}, '
          'server ${info.version}');
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
      log.error(
        'net',
        'connect failed: ${error.message} (${error.statusCode ?? 'no status'})',
      );
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

  /// The same profile carrying the password the phone's server is using now.
  ///
  /// Returns null for every other server, and for the phone's own server when
  /// it is not running or the stored password is already the live one.
  Future<ServerProfile?> _withLiveLocalPassword(ServerProfile stored) async {
    if (stored.authMode != AuthMode.basic) return null;
    if (!PairingLink.isLoopback(stored.baseUrl)) return null;
    // The device check is asynchronous, and until it lands the provider says
    // nothing about a server that is very much running.
    final local = ref.read(localServerProvider.notifier);
    await local.ensureLoaded();
    final live = local.state.status;
    final password = live.password;
    if (!live.isRunning || password == null) return null;
    if (password == stored.secret) return null;
    return stored.copyWith(secret: password);
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
    ref.read(appLogProvider).info('net', 'disconnected');
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
    ref.read(appLogProvider).info('net', 'forgot ${profile.displayHost}');
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

  final log = ref.read(appLogProvider);
  final revision = ref.read(appLogRevisionProvider.notifier);
  // Reconnects are the usual reason a session "froze", and they were invisible
  // from inside the app. Recorded at debug level so the default view stays
  // about things that matter.
  stream.status.listen((status) {
    final detail = status.message;
    log.debug(
      'sse',
      detail == null || detail.isEmpty
          ? status.status.name
          : '${status.status.name}: $detail',
    );
    revision.bump();
  });

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
  // A project created, renamed or removed elsewhere (TUI, another client)
  // arrives as an event; the REST list below would otherwise stay stale until
  // someone pulls to refresh.
  ref.watch(projectMutationsProvider);
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
  ref.watch(sessionMutationsProvider);
  final api = ref.watch(apiProvider);
  if (api == null) return const [];
  final directory = ref.watch(selectedDirectoryProvider);
  final page = await api.sessions(directory: directory, limit: 100);
  return page.items;
});

/// Structural changes on the event bus that invalidate the REST lists above.
///
/// Sessions and projects are read over REST but announced over SSE; without
/// this, a session created or deleted anywhere but here would not appear or
/// disappear until a manual refresh. Counting is enough — the lists refetch
/// themselves when the count moves.
final sessionMutationsProvider = Provider<int>((ref) {
  var count = 0;
  for (final event in _eventsOf(ref)) {
    if (event.type == Ev.sessionCreated ||
        event.type == Ev.sessionDeleted) {
      count++;
    }
  }
  return count;
});

/// Projects change rarely, but when they do it is always somewhere else.
final projectMutationsProvider = Provider<int>((ref) {
  var count = 0;
  for (final event in _eventsOf(ref)) {
    if (event.type == Ev.projectUpdated) count++;
  }
  return count;
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
///
/// Two passes over the log: collect the answers first, then the questions.
/// A single pass would keep a request asked before its answer, and event
/// order on a replayed log is not something to bet the inbox on.
final permissionInboxProvider = Provider<List<PermissionRequest>>((ref) {
  final events = _eventsOf(ref);
  final answered = <String>{};
  for (final event in events) {
    if (event.type == Ev.permissionReplied) {
      final id = event.data['requestID'];
      if (id is String) answered.add(id);
    }
  }
  final open = <PermissionRequest>[];
  for (final event in events) {
    if (event.type != Ev.permissionAsked) continue;
    final request = event.asPermissionRequest;
    if (request != null && !answered.contains(request.id)) {
      open.add(request);
    }
  }
  open.sort((a, b) => b.id.compareTo(a.id));
  return open;
});

/// Interactive forms that have not been answered yet.
///
/// Same contract as permissions: the agent stalls until someone answers, so
/// an unanswered form is indistinguishable from a stuck model. `form.replied`
/// and `form.cancelled` retire entries; anything else is a new question.
/// Two passes like permissions: order on a replayed log is not to be trusted.
final formInboxProvider = Provider<List<FormRequest>>((ref) {
  final events = _eventsOf(ref);
  final settled = <String>{};
  for (final event in events) {
    if (event.type == Ev.formReplied || event.type == Ev.formCancelled) {
      final id = event.data['id'];
      if (id is String) settled.add(id);
    }
  }
  final open = <FormRequest>[];
  for (final event in events) {
    if (event.type != Ev.formCreated) continue;
    final request = FormRequest.fromEventData(event.data);
    if (request.id.isNotEmpty && !settled.contains(request.id)) {
      open.add(request);
    }
  }
  open.sort((a, b) => b.id.compareTo(a.id));
  return open;
});