import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/models.dart';

void main() {
  group('agent parsing', () {
    test('reads what /api/agent returns', () {
      // Shape taken from a live GET /api/agent on 2026-10-13.
      final agent = AgentInfo.fromJson({
        'id': 'build',
        'name': 'Build',
        'mode': 'primary',
        'hidden': false,
        'description': 'The default agent. Executes tools based on...',
        'color': 'blue',
        'request': <String, Object?>{},
        'permissions': <String, Object?>{},
      });

      expect(agent.id, 'build');
      expect(agent.name, 'Build');
      expect(agent.mode, AgentMode.primary);
      expect(agent.hidden, isFalse);
      expect(agent.description, startsWith('The default agent'));
      expect(agent.color, 'blue');
    });

    test('classifies subagents', () {
      final agent = AgentInfo.fromJson({
        'id': 'explore',
        'name': 'Explore',
        'mode': 'subagent',
        'hidden': false,
      });

      expect(agent.mode, AgentMode.subagent);
    });

    test('an unknown mode is not treated as primary', () {
      // Being strict here is the point: anything unrecognised stays out of the
      // picker rather than being offered as a conversation partner.
      final agent = AgentInfo.fromJson({
        'id': 'x',
        'name': 'X',
        'mode': 'primaryish',
        'hidden': false,
      });

      expect(agent.mode, AgentMode.other);
      expect(agent.isSelectable, isFalse);
    });

    test('survives missing fields', () {
      final agent = AgentInfo.fromJson(const {'id': 'bare'});

      expect(agent.id, 'bare');
      expect(agent.name, '');
      expect(agent.mode, AgentMode.other);
      expect(agent.hidden, isFalse);
      expect(agent.description, '');
      expect(agent.color, isNull);
    });
  });

  group('which agents are offered', () {
    AgentInfo agent(String id, AgentMode mode, {bool hidden = false}) =>
        AgentInfo(id: id, name: id, mode: mode, hidden: hidden);

    test('keeps visible primary agents', () {
      final agents = selectableAgents([
        agent('build', AgentMode.primary),
        agent('plan', AgentMode.primary),
      ]);

      expect(agents.map((a) => a.id), ['build', 'plan']);
    });

    test('drops subagents and hidden bookkeeping agents', () {
      final agents = selectableAgents([
        agent('build', AgentMode.primary),
        agent('general', AgentMode.subagent),
        agent('explore', AgentMode.subagent),
        agent('compaction', AgentMode.primary, hidden: true),
        agent('title', AgentMode.primary, hidden: true),
      ]);

      expect(agents.map((a) => a.id), ['build']);
    });

    test('sorts by display name, case-insensitively', () {
      final agents = selectableAgents([
        AgentInfo(id: 'b', name: 'build', mode: AgentMode.primary, hidden: false),
        AgentInfo(id: 'a', name: 'Plan', mode: AgentMode.primary, hidden: false),
        AgentInfo(id: 'c', name: 'apply', mode: AgentMode.primary, hidden: false),
      ]);

      expect(agents.map((a) => a.name), ['apply', 'build', 'Plan']);
    });

    test('an empty server answer yields an empty list', () {
      expect(selectableAgents(const []), isEmpty);
    });

    test('falls back to the id when the name is blank', () {
      final agent = AgentInfo.fromJson({
        'id': 'mystery',
        'name': '',
        'mode': 'primary',
        'hidden': false,
      });

      expect(agent.isSelectable, isTrue);
    });
  });

  group('session agent', () {
    test('is read off the session summary', () {
      final session = SessionSummary.fromJson({
        'id': 'ses_1',
        'agent': 'plan',
      });

      expect(session.agent, 'plan');
    });

    test('a session that never ran has no agent', () {
      // The server picks the default on the first turn, so an absent agent is
      // normal rather than something to render as an error.
      final session = SessionSummary.fromJson({'id': 'ses_2'});

      expect(session.agent, isNull);
    });
  });
}