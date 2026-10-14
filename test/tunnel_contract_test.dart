import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/src/runtime/tunnel/tunnel_api.dart';

/// The tunnel service's OpenAPI document is the contract; the hand-written
/// client is the implementation. Code generation was evaluated and rejected
/// for this surface: five endpoints and fourteen flat schemas do not repay a
/// built_value + build_runner toolchain and fifty generated files, while
/// every interesting behaviour (retries, jitter, polling, fatal errors,
/// the bridge) is not in the spec and stays hand-written either way.
///
/// So the spec rules by test instead of by generation. This file loads the
/// vendored document and asserts everything the client depends on: the
/// operations exist with the right methods and statuses, the payloads carry
/// the fields the client reads, and no error the service declares goes
/// unmapped. Refresh the document and this either passes unchanged or fails
/// pointing at exactly what the service changed:
///
///   curl -s https://opentunnel.xyz/openapi.json -o tool/opentunnel-openapi.json
Map<String, Object?> loadSpec() => (jsonDecode(
  File('tool/opentunnel-openapi.json').readAsStringSync(),
) as Map)
    .cast<String, Object?>();

Map<String, Object?> operationsOf(Map<String, Object?> spec) {
  final paths = (spec['paths'] as Map).cast<String, Object?>();
  final operations = <String, Object?>{};
  for (final entry in paths.entries) {
    final methods = (entry.value as Map).cast<String, Object?>();
    for (final method in methods.entries) {
      if (method.key == 'parameters') continue;
      operations['${method.key.toUpperCase()} ${entry.key}'] = method.value;
    }
  }
  return operations;
}

Object? schemaOf(Map<String, Object?> spec, String ref) {
  const prefix = '#/components/schemas/';
  assert(ref.startsWith(prefix), 'expected a local schema ref: $ref');
  final schemas = (spec['components'] as Map)['schemas'] as Map;
  return schemas[ref.substring(prefix.length)];
}

void main() {
  late Map<String, Object?> spec;
  late Map<String, Object?> operations;

  setUpAll(() {
    spec = loadSpec();
    operations = operationsOf(spec);
  });

  group('operations the client depends on', () {
    test('claiming sends the empty object the schema allows', () {
      final claim = operations['POST /api/tunnel'] as Map;
      expect(claim['operationId'], 'tunnel.tunnel.create');
      final content =
          ((claim['requestBody'] as Map)['content'] as Map).cast<String, Object?>();
      final schema =
          ((content['application/json'] as Map)['schema'] as Map)
              .cast<String, Object?>();
      // The service rejects a missing body without explanation; the client
      // always sends the empty object, which the schema must allow.
      expect((schema['required'] as List?) ?? const [], isEmpty);
      expect(claim['responses'], contains('201'));
    });

    test('tunnel lifecycle reads and deletes', () {
      expect(operations, contains('GET /api/tunnel/{id}'));
      expect(operations, contains('DELETE /api/tunnel/{id}'));
    });

    test('certificate request takes a csr and answers 202', () {
      final bind =
          operations['POST /api/tunnel/{id}/certificate'] as Map;
      final content =
          ((bind['requestBody'] as Map)['content'] as Map).cast<String, Object?>();
      final schema =
          ((content['application/json'] as Map)['schema'] as Map)
              .cast<String, Object?>();
      expect(schema['required'], ['csr']);
      expect(bind['responses'], contains('202'));
    });

    test('certificate polling and the bridge address exist', () {
      expect(operations, contains('GET /api/tunnel/{id}/certificate'));
      // The bridge speaks WebSocket on this path; the document types the
      // upgrade as a plain GET, which is all a contract test can assert.
      expect(operations, contains('GET /api/tunnel/{id}/connect'));
    });
  });

  group('payloads the client reads', () {
    test('claim answers tunnel and token', () {
      final claim = operations['POST /api/tunnel'] as Map;
      final content =
          (((claim['responses'] as Map)['201'] as Map)['content'] as Map)
              .cast<String, Object?>();
      final schema =
          ((content['application/json'] as Map)['schema'] as Map)
              .cast<String, Object?>();
      expect(schema['required'], containsAll(['tunnel', 'token']));
    });

    test('tunnel info carries what the client stores', () {
      final info =
          schemaOf(spec, '#/components/schemas/Tunnel_InfoEncoded') as Map;
      final properties = (info['properties'] as Map).cast<String, Object?>();
      expect(
        properties.keys,
        containsAll(['id', 'hostname', 'state', 'certificateID']),
      );
    });

    test('declares every certificate state the client parses', () {
      for (final state in ['Ready', 'Challenge', 'Issuing', 'Failed']) {
        final schema =
            schemaOf(spec, '#/components/schemas/Certificate_State$state'
                    'Encoded') as Map;
        expect(schema['properties'], isNotNull, reason: state);
      }
      final ready =
          schemaOf(spec, '#/components/schemas/Certificate_StateReadyEncoded')
              as Map;
      expect(
        (ready['properties'] as Map).keys,
        containsAll(['certificate', 'chain', 'expiry']),
      );
      // Parsed and stored, never acted on: the service resolves the challenge
      // itself. Asserted here so dropping the fields breaks loudly instead of
      // silently starving whatever the client was keeping them for.
      final challenge =
          schemaOf(spec, '#/components/schemas/Certificate_StateChallengeEncoded')
              as Map;
      expect(
        (challenge['properties'] as Map).keys,
        containsAll(['token', 'key']),
      );
    });

    test('error bodies carry tag and message', () {
      const errors = [
        'InvalidRequestErrorEncoded',
        'HostnameUnavailableErrorEncoded',
        'ServiceUnavailableErrorEncoded',
        'UnauthorizedErrorEncoded',
        'TunnelNotFoundErrorEncoded',
        'CertificateNotFoundErrorEncoded',
        'CertificateInProgressErrorEncoded',
        'InvalidHostnameErrorEncoded',
      ];
      for (final name in errors) {
        final schema = schemaOf(spec, '#/components/schemas/$name') as Map;
        final properties = (schema['properties'] as Map).keys.toSet();
        expect(properties, containsAll(['_tag', 'message']), reason: name);
      }
    });
  });

  group('no unmapped failures', () {
    test('the document declares exactly the failures the client handles', () {
      // Single source of truth, enforced both ways: TunnelApi names what it
      // meets, and this asserts the service declares nothing else. A new
      // failure mode breaks here first and gains its handling in the same
      // change, instead of reaching a phone as a bare number nobody has read.
      final seen = <String>{};
      for (final entry in operations.entries) {
        final responses = (entry.value as Map)['responses'] as Map?;
        if (responses == null) continue;
        for (final code in responses.keys) {
          if ('$code'.startsWith('4')) seen.add('$code');
        }
      }
      expect(
        seen,
        TunnelApi.handledClientErrorStatuses.map((code) => '$code').toSet(),
      );
    });

    test('auth goes where the document says', () {
      // The client relies on this shape: claiming has no token yet, the
      // bridge carries its token in the attach message rather than a header,
      // and everything else authenticates with a bearer token. If the service
      // put bearer on claiming, the first launch would 401 with no test
      // failing — so this asserts the shape instead of assuming it.
      Map<String, Object?> securityOf(String operation) {
        final op = operations[operation] as Map;
        final explicit = op['security'];
        if (explicit is List) {
          return {
            'empty': explicit.isEmpty,
            'bearer': explicit.any(
              (entry) => entry is Map && entry.containsKey('bearer'),
            ),
          };
        }
        return const {'empty': true, 'bearer': false};
      }

      for (final open in [
        'POST /api/tunnel',
        'GET /api/tunnel/{id}/connect',
      ]) {
        expect(securityOf(open), {'empty': true, 'bearer': false}, reason: open);
      }
      for (final guarded in [
        'GET /api/tunnel/{id}',
        'DELETE /api/tunnel/{id}',
        'POST /api/tunnel/{id}/certificate',
        'GET /api/tunnel/{id}/certificate',
      ]) {
        expect(securityOf(guarded)['bearer'], isTrue, reason: guarded);
      }
    });
  });
}
