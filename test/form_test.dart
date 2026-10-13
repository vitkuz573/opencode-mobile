import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/data/events.dart';
import 'package:opencode_mobile/src/data/models.dart';
import 'package:opencode_mobile/src/state/providers.dart';
import 'package:opencode_mobile/src/ui/form_sheet.dart';

Map<String, Object?> formEvent({
  required String id,
  String sessionId = 'ses_x',
  String title = 'Pick one',
  List<Map<String, Object?>> fields = const [
    {
      'key': 'color',
      'type': 'string',
      'title': 'Color',
      'required': true,
      'options': [
        {'value': 'red', 'label': 'Red'},
        {'value': 'blue', 'label': 'Blue'},
      ],
    },
    {'key': 'verbose', 'type': 'boolean', 'title': 'Verbose'},
  ],
}) => {
  'type': Ev.formCreated,
  'created': 1,
  'data': {
    'form': {'id': id, 'sessionID': sessionId, 'title': title, 'fields': fields},
  },
};

ServerEvent asEvent(Map<String, Object?> json) =>
    ServerEvent.fromJson(json);

void main() {
  group('FormRequest', () {
    test('reads the form out of the event envelope', () {
      final request = FormRequest.fromEventData(
        formEvent(id: 'frm_1')['data']! as Map<String, Object?>,
      );

      expect(request.id, 'frm_1');
      expect(request.sessionId, 'ses_x');
      expect(request.title, 'Pick one');
      expect(request.fields, hasLength(2));
      expect(request.fields.first.key, 'color');
      expect(request.fields.first.options.map((o) => o.value), [
        'red',
        'blue',
      ]);
      expect(request.fields.last.isToggle, isTrue);
    });

    test('a form without fields or title still parses', () {
      final request = FormRequest.fromEventData(const {
        'form': {'id': 'frm_2', 'sessionID': 'ses_y'},
      });

      expect(request.id, 'frm_2');
      expect(request.title, 'Question');
      expect(request.fields, isEmpty);
    });

    test('fields without keys are dropped', () {
      final request = FormRequest.fromEventData(const {
        'form': {
          'id': 'frm_3',
          'sessionID': 'ses_x',
          'fields': [
            {'type': 'string'},
            {'key': 'ok', 'type': 'string'},
          ],
        },
      });

      expect(request.fields.map((f) => f.key), ['ok']);
    });

    test('unknown field kinds stay answerable as text', () {
      final request = FormRequest.fromEventData(const {
        'form': {
          'id': 'frm_4',
          'sessionID': 'ses_x',
          'fields': [
            {'key': 'weird', 'type': 'date-time-picker-9000'},
          ],
        },
      });

      expect(request.fields.single.isOptions, isFalse);
      expect(request.fields.single.isToggle, isFalse);
    });
  });

  group('formInboxProvider', () {
    ProviderContainer containerWith(List<ServerEvent> events) {
      final container = ProviderContainer(
        overrides: [eventsProvider.overrideWithValue(AsyncData(events))],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('open forms are listed', () async {
      final container = containerWith([
        asEvent(formEvent(id: 'frm_1')),
        asEvent(formEvent(id: 'frm_2')),
      ]);

      await container.read(eventsProvider.future);
      final inbox = container.read(formInboxProvider);
      expect(inbox.map((f) => f.id), containsAll(['frm_1', 'frm_2']));
    });

    test('replies and cancellations retire entries', () async {
      ServerEvent settled(String type, String id) => asEvent({
        'type': type,
        'created': 2,
        'data': {'id': id, 'sessionID': 'ses_x'},
      });

      final container = containerWith([
        asEvent(formEvent(id: 'frm_1')),
        asEvent(formEvent(id: 'frm_2')),
        settled(Ev.formReplied, 'frm_1'),
        settled(Ev.formCancelled, 'frm_2'),
      ]);

      await container.read(eventsProvider.future);
      expect(container.read(formInboxProvider), isEmpty);
    });

    test('a reply before the creation still retires it', () async {
      final container = containerWith([
        asEvent({
          'type': Ev.formReplied,
          'created': 1,
          'data': {'id': 'frm_9', 'sessionID': 'ses_x'},
        }),
        asEvent(formEvent(id: 'frm_9')),
      ]);

      await container.read(eventsProvider.future);
      expect(container.read(formInboxProvider), isEmpty);
    });
  });

  group('form sheet', () {
    Future<void> openSheet(
      WidgetTester tester, {
      List<Map<String, Object?>>? fields,
    }) async {
      final request = FormRequest.fromEventData(
        formEvent(id: 'frm_1', fields: fields ?? const [])['data']!
            as Map<String, Object?>,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFormSheet(
                context,
                request: request,
                api: null,
                directory: null,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('renders every field kind', (tester) async {
      await openSheet(
        tester,
        fields: const [
          {'key': 'name', 'type': 'string', 'title': 'Name', 'required': true},
          {'key': 'loud', 'type': 'boolean', 'title': 'Loud'},
          {
            'key': 'tags',
            'type': 'multiselect',
            'title': 'Tags',
            'options': [
              {'value': 'a', 'label': 'A'},
              {'value': 'b', 'label': 'B'},
            ],
          },
        ],
      );

      expect(find.text('Name *'), findsOneWidget);
      expect(find.text('Loud'), findsOneWidget);
      expect(find.text('Tags'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(find.text('Send answers'), findsOneWidget);
    });

    testWidgets('submit waits for required fields', (tester) async {
      await openSheet(
        tester,
        fields: const [
          {'key': 'name', 'type': 'string', 'title': 'Name', 'required': true},
        ],
      );

      FilledButton submit() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send answers'),
      );
      expect(submit().onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();

      expect(submit().onPressed, isNotNull);
    });
  });
}
