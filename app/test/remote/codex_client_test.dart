import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/remote/codex/codex_client.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteRpcException;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

class _Carrier extends DshCarrier {
  _Carrier(this.answer);

  final Object? Function(String method, Map<String, Object?> params, bool transfer) answer;
  final calls = <(String, Map<String, Object?>, bool)>[];

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  Future<Object?> _request(String method, Object? params, bool transfer) async {
    expect(method, 'codex.app.call');
    final envelope = params as Map<String, Object?>;
    final codexMethod = envelope['method'] as String;
    final codexParams = envelope['params'] as Map<String, Object?>;
    calls.add((codexMethod, codexParams, transfer));
    return answer(codexMethod, codexParams, transfer);
  }

  @override
  Future<Object?> rawCall(String method, Object? params, {Duration? timeout}) => _request(method, params, false);

  @override
  Future<Object?> rawCallChunked(String method, Object? params, {Duration? timeout, bool forceChunked = false}) {
    expect(forceChunked, isTrue);
    return _request(method, params, true);
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) => throw UnimplementedError();

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

Map<String, Object?> _event(int seq, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'type': type, 'seq': seq, 'time': 1794995470000, 'data': data},
};

void main() {
  test('decodes the Codex Plus short and weekly usage windows', () async {
    final carrier = _Carrier((method, params, _) {
      expect(method, 'account/rateLimits/read');
      expect(params, isEmpty);
      return {
        'rateLimitsByLimitId': {
          'codex': {
            'planType': 'plus',
            'primary': {'usedPercent': 72, 'windowDurationMins': 300, 'resetsAt': 1795068129},
            'secondary': {'usedPercent': 43, 'windowDurationMins': 10080},
          },
        },
      };
    });
    final usage = await CodexClient(carrier).readUsage();
    expect(usage.plan, 'plus');
    expect(usage.windows.map((window) => window.durationMinutes), [300, 10080]);
    expect(usage.windows.map((window) => window.usedPercent), [72, 43]);
    expect(usage.windows.first.resetsAt?.millisecondsSinceEpoch, 1795068129000);
  });

  test('uses the server-confirmed reviewer and parses a pending phone approval', () async {
    final carrier = _Carrier((method, params, _) {
      expect(params['threadId'], 'thread-1');
      if (method == 'dsh/approvalReviewer/set') {
        expect(params['approvalsReviewer'], 'auto_review');
        return {
          'thread': {'id': 'thread-1'},
          'approvalsReviewer': 'guardian_subagent',
        };
      }
      return {
        'approvals': [
          {'requestHandle': 'handle', 'method': 'item/commandExecution/requestApproval', 'command': 'echo ok'},
        ],
      };
    });
    final client = CodexClient(carrier);
    expect((await client.setApprovalsReviewer('thread-1', 'auto_review')).approvalsReviewer, 'auto_review');
    final history = await client.readHistory('thread-1', sessionId: 'codex:thread-1');
    expect(history.approvals.single.eventId, 'handle');
    expect(history.approvals.single.raw['command'], 'echo ok');
  });
  test('starts a turn inline with the selected model, text and image data', () async {
    final carrier = _Carrier(
      (_, _, _) => {
        'turn': {'id': 'turn-1'},
      },
    );
    final turnId = await CodexClient(carrier).sendPrompt(
      'thread-1',
      'Describe these',
      model: 'gpt-codex',
      reasoningEffort: 'high',
      images: [
        (bytes: Uint8List.fromList([1, 2, 3]), mediaType: 'image/png'),
        (bytes: Uint8List.fromList([4, 5]), mediaType: 'image/jpeg'),
      ],
    );

    expect(turnId, 'turn-1');
    final (method, params, transfer) = carrier.calls.single;
    expect(method, 'turn/start');
    expect(transfer, isFalse);
    expect(params, {
      'threadId': 'thread-1',
      'model': 'gpt-codex',
      'effort': 'high',
      'input': [
        {'type': 'image', 'mediaType': 'image/png', 'data': 'AQID'},
        {'type': 'image', 'mediaType': 'image/jpeg', 'data': 'BAU='},
        {'type': 'text', 'text': 'Describe these'},
      ],
    });
  });

  test('steers the active turn inline without a model override', () async {
    final carrier = _Carrier((_, _, _) => const {});
    final turnId = await CodexClient(carrier).sendPrompt(
      'thread-1',
      'More context',
      model: 'next-model',
      reasoningEffort: 'xhigh',
      expectedTurnId: 'turn-live',
    );

    expect(turnId, 'turn-live');
    final (method, params, transfer) = carrier.calls.single;
    expect(method, 'turn/steer');
    expect(transfer, isFalse);
    expect(params, {
      'threadId': 'thread-1',
      'expectedTurnId': 'turn-live',
      'input': [
        {'type': 'text', 'text': 'More context'},
      ],
    });
  });

  test('rejects an effort without an explicit model before starting a turn', () async {
    final carrier = _Carrier((_, _, _) => throw StateError('Unexpected request'));
    await expectLater(
      CodexClient(carrier).sendPrompt('thread-1', 'Use the effort', reasoningEffort: 'low'),
      throwsArgumentError,
    );
    expect(carrier.calls, isEmpty);
  });

  test('fits oversized pictures into the inline budget while retaining small originals', () async {
    final large = image.encodePng(image.Image(width: 1024, height: 900), level: 0);
    expect(large.length, greaterThan(2600000));
    final carrier = _Carrier((_, _, _) => {'turnId': 'turn-1'});
    final id = await CodexClient(carrier).sendPrompt(
      'thread-1',
      'Compare these',
      images: [
        (bytes: large, mediaType: 'image/png'),
        (bytes: Uint8List.fromList([1, 2, 3]), mediaType: 'image/gif'),
      ],
    );

    expect(id, 'turn-1');
    final (_, params, transfer) = carrier.calls.single;
    expect(transfer, isFalse);
    expect(utf8.encode(jsonEncode(params)).length, lessThan(3 * 1024 * 1024));
    final input = params['input'] as List<Map<String, Object?>>;
    expect(input[0]['mediaType'], 'image/jpeg');
    final decoded = image.decodeJpg(base64Decode(input[0]['data'] as String));
    expect(decoded?.width, 1024);
    expect(decoded?.height, 900);
    expect(input[1], {'type': 'image', 'mediaType': 'image/gif', 'data': 'AQID'});
  });

  test('resumes an existing thread without turn or permission parameters', () async {
    final carrier = _Carrier((_, _, _) => const {});
    final settings = await CodexClient(carrier).resumeThread('thread-1');
    expect(settings.threadId, 'thread-1');
    expect(settings.permissionPreset, isNull);
    final (method, params, transfer) = carrier.calls.single;
    expect(method, 'thread/resume');
    expect(params, {'threadId': 'thread-1'});
    expect(transfer, isFalse);
  });

  test('starts a thread with its selected preset and returns the Host-confirmed settings', () async {
    final carrier = _Carrier(
      (_, _, _) => {
        'thread': {'id': 'thread-1'},
        'model': 'gpt-codex',
        'reasoningEffort': 'medium',
        'approvalPolicy': 'never',
        'sandbox': {'type': 'dangerFullAccess'},
      },
    );

    final settings = await CodexClient(carrier)
        .startThread(r'C:\work\one', model: 'gpt-codex', permissionPreset: 'workspace-write');

    expect(settings?.threadId, 'thread-1');
    expect(settings?.model, 'gpt-codex');
    expect(settings?.reasoningEffort, 'medium');
    expect(settings?.permissionPreset, 'danger-full-access');
    final (method, params, transfer) = carrier.calls.single;
    expect(method, 'thread/start');
    expect(params, {'cwd': r'C:\work\one', 'model': 'gpt-codex', 'permissionPreset': 'workspace-write'});
    expect(transfer, isFalse);
  });

  test('parses an existing thread permission change only when both policies match', () async {
    var approval = 'on-request';
    final carrier = _Carrier(
      (_, _, _) => {
        'thread': {'id': 'thread-1'},
        'threadSettings': {
          'sandboxPolicy': {'type': 'workspaceWrite'},
          'approvalPolicy': approval,
          'model': 'gpt-codex',
          'effort': 'high',
        },
      },
    );
    final client = CodexClient(carrier);

    final settings = await client.resumeThread('thread-1', permissionPreset: 'workspace-write');
    expect(settings.model, 'gpt-codex');
    expect(settings.reasoningEffort, 'high');
    expect(settings.permissionPreset, 'workspace-write');
    expect(carrier.calls.single.$1, 'thread/resume');
    expect(carrier.calls.single.$2, {'threadId': 'thread-1', 'permissionPreset': 'workspace-write'});
    expect(carrier.calls.single.$3, isFalse);

    approval = 'never';
    final customPair = await client.resumeThread('thread-1', model: 'gpt-codex', permissionPreset: 'workspace-write');
    expect(customPair.permissionPreset, isNull);
    expect(carrier.calls.last.$2, {
      'threadId': 'thread-1',
      'model': 'gpt-codex',
      'permissionPreset': 'workspace-write',
    });
  });

  test('detaches only the requested thread through the Host', () async {
    final carrier = _Carrier((_, _, _) => {'status': 'unsubscribed'});
    await CodexClient(carrier).unsubscribeThread('thread-1');
    final (method, params, transfer) = carrier.calls.single;
    expect(method, 'thread/unsubscribe');
    expect(params, {'threadId': 'thread-1'});
    expect(transfer, isFalse);
  });

  test('reports a safe Host failure and never retries sending a turn', () async {
    final carrier = _Carrier((_, _, _) {
      throw const RemoteRpcException('RESPONSE_TOO_LARGE', 'private payload', details: {'data': 'private payload'});
    });

    await expectLater(
      CodexClient(carrier).sendText('thread-1', 'private payload'),
      throwsA(
        isA<DshRemoteException>()
            .having((error) => error.code, 'code', 'RESPONSE_TOO_LARGE')
            .having((error) => error.toString(), 'diagnostic', isNot(contains('private payload')))
            .having((error) => error.details.containsKey('data'), 'payload in details', isFalse),
      ),
    );
    expect(carrier.calls.single.$3, isFalse);
  });

  test('reads every project, thread and model page using the cursor', () async {
    final carrier = _Carrier((method, params, _) {
      return switch ((method, params['cursor'])) {
        ('project/list', null) => {
          'data': [
            {
              'id': 'p1',
              'name': 'Project one',
              'roots': [
                {'path': r'C:\work\one'},
              ],
            },
          ],
          'nextCursor': 'projects-2',
        },
        ('project/list', 'projects-2') => {
          'data': [
            {'id': 'p2', 'name': 'Project two'},
          ],
        },
        ('thread/list', null) => {'data': [], 'nextCursor': 'threads-2'},
        ('thread/list', 'threads-2') => {
          'data': [
            {
              'id': 't1',
              'preview': 'A first message\nThe second line',
              'status': {'type': 'active'},
              'isPinned': true,
            },
            {'id': 't1', 'name': 'Duplicate'},
            {'id': 't2', 'name': 'Another conversation'},
          ],
          'nextCursor': null,
        },
        ('model/list', null) => {
          'data': [
            {
              'id': 'catalog-entry',
              'model': 'gpt-codex',
              'displayName': 'Codex',
              'description': 'Coding model',
              'isDefault': true,
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'low', 'description': 'Fast answers'},
                {'reasoningEffort': 'high', 'description': 'More deliberation'},
                {'reasoningEffort': 'persistent'},
              ],
              'defaultReasoningEffort': 'high',
            },
          ],
          'nextCursor': 'models-2',
        },
        ('model/list', 'models-2') => {
          'data': [
            {
              'id': 'another-model',
              'defaultReasoningEffort': 'medium',
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'low'},
              ],
            },
            {'id': 'hidden-model', 'hidden': true},
          ],
        },
        _ => throw StateError('Unexpected cursor'),
      };
    });
    final client = CodexClient(carrier);

    final projects = await client.listProjects();
    expect(projects.map((project) => project.id), ['p1', 'p2']);
    expect(projects.first.root, r'C:\work\one');
    final threads = await client.listThreads(limit: 2, archived: true, searchTerm: ' A ');
    expect(threads.map((thread) => thread.title), ['A first message', 'Another conversation']);
    expect(threads.map((thread) => thread.running), [true, false]);
    expect(threads.map((thread) => thread.isPinned), [true, false]);
    final models = await client.listModels();
    expect(models.map((model) => (model.id, model.name)), [('gpt-codex', 'Codex'), ('another-model', 'another-model')]);
    final primary = models.first;
    expect(primary.isDefault, isTrue);
    expect(primary.description, 'Coding model');
    expect(primary.defaultEffort, 'high');
    expect(primary.efforts.map((effort) => effort.id), ['low', 'high']);
    expect(primary.efforts.first.description, 'Fast answers');
    expect(models.last.defaultEffort, isNull);
    expect(carrier.calls.where((call) => call.$1 == 'thread/list').last.$2, {
      'limit': 2,
      'sortKey': 'recency_at',
      'sortDirection': 'desc',
      'archived': true,
      'searchTerm': 'A',
      'cursor': 'threads-2',
    });
    expect(carrier.calls.last.$2, {'limit': 50, 'includeHidden': false, 'cursor': 'models-2'});
  });

  test('keeps stable sequence, model and attachment references across history pages', () async {
    final carrier = _Carrier(
      (_, _, _) => {
        'header': {'id': 'codex:thread-1', 'version': 1, 'model': 'gpt-codex', 'reasoningEffort': 'high'},
        'cursor': 12,
        'nextTurn': 3,
        'activeTurnId': 'turn-live',
        'permissionPreset': 'workspace-write',
        'hasMore': true,
        'records': [
          _event(4, 'turn/start', {'turn': 2}),
          _event(5, 'user/message', {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Explain'},
              {
                'type': 'image',
                'attachment': {
                  'attachmentId': 'image-1',
                  'mediaType': 'image/png',
                  'bytes': 3,
                  'width': 15,
                  'height': 8,
                },
                'data': 'AQID',
                'url': 'data:image/png;base64,AQID',
              },
            ],
            'source': {'kind': 'user'},
          }),
          _event(6, 'assistant/message', {
            'turn': 2,
            'step': 1,
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'reasoning', 'text': 'Private reasoning block'},
                {'type': 'text', 'text': 'Code:\n```dart\nvoid main() {}\n```'},
              ],
              'source': {'kind': 'model', 'provider': 'codex', 'model': 'gpt-codex'},
            },
          }),
        ],
      },
    );
    final history = await CodexClient(carrier).readHistory('thread-1', maxMessages: 20, beforeSeq: 9, throughSeq: 12);

    expect(carrier.calls.single.$2, {'threadId': 'thread-1', 'maxMessages': 20, 'beforeSeq': 9, 'throughSeq': 12});
    expect(history.header?.id, 'codex:thread-1');
    expect(history.model, 'gpt-codex');
    expect(history.reasoningEffort, 'high');
    expect(history.activeTurnId, 'turn-live');
    expect(history.permissionPreset, 'workspace-write');
    expect(history.cursor, 12);
    expect(history.oldestSeq, 4);
    expect(history.nextTurn, 3);
    expect(history.hasMore, isTrue);
    expect(history.records.map((event) => event.seq), [4, 5, 6]);
    expect(history.messages.map((message) => message.seq), [5, 6]);
    final user = history.messages.first;
    expect(user.fromUser, isTrue);
    expect(user.text, 'Explain');
    expect(user.attachmentIds, ['image-1']);
    expect(user.attachments.single.width, 15);
    expect(user.attachments.single.mediaType, 'image/png');
    expect(history.records[1].data.toString(), isNot(contains('AQID')));
    final assistant = history.messages.last;
    expect(assistant.text, 'Code:\n```dart\nvoid main() {}\n```');
    expect(assistant.reasoning, 'Private reasoning block');
    expect(assistant.model, 'gpt-codex');
  });

  test('moves an oversized read to the transfer protocol and decodes the requested attachment', () async {
    final carrier = _Carrier((_, _, transfer) {
      if (!transfer) throw const RemoteRpcException('RESPONSE_TOO_LARGE', 'Request a smaller page');
      return {
        'attachment': {'attachmentId': 'image-1'},
        'data': 'AQID',
      };
    });

    expect(await CodexClient(carrier).fetchAttachment('thread-1', 'image-1'), [1, 2, 3]);
    expect(carrier.calls.map((call) => call.$3), [false, true]);
    expect(carrier.calls.last.$1, 'dsh/sessionAttachment');
    expect(carrier.calls.last.$2, {'threadId': 'thread-1', 'attachmentId': 'image-1'});
  });
}
