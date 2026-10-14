import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    test('claiming exists with an optional body', () {
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

    test('every certificate state the client folds', () {
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
    test('every declared client error status is accounted for', () {
      // Statuses the client must translate or deliberately propagate: any
      // 4xx the service can answer with and the client has never heard of
      // fails this test, which is the point — an unknown failure mode should
      // break the build, not reach a phone as a bare number. Success codes
      // and the Cloudflare range (an edge behaviour, not in the document)
      // are out of scope here.
      const known = {'400', '401', '404', '409'};
      final seen = <String>{};
      for (final entry in operations.entries) {
        final responses = (entry.value as Map)['responses'] as Map?;
        if (responses == null) continue;
        for (final code in responses.keys) {
          if ('$code'.startsWith('4')) seen.add('$code');
        }
      }
      expect(seen.difference(known), isEmpty);
    });
  });
}
