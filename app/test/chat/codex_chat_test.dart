import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/backend_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/codex_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CodexHost extends DshCarrier implements WorkspaceUploadCarrier {
  final uploads = <String>[];
  final prompts = <List<Object?>>[];
  final resumptions = <Map<String, Object?>>[];
  final releases = <Map<String, Object?>>[];
  bool rejectFirstPrompt = false;
  bool rejectUpload = false;
  bool materialized = false;
  bool activeTurn = false;
  bool rejectPermission = false;
  String? reportedPermission = 'workspace-write';
  String? expectedEffort;
  Completer<void>? releaseStarted;
  Completer<void>? releaseReply;

  @override
  String get kind => 'codex-test';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsWorkspaceUpload => true;

  @override
  int get maxWorkspaceUploadBytes => 20 * 1024 * 1024;

  @override
  Future<WorkspaceUploadedFile> uploadWorkspaceFile(String sessionId, List<int> bytes, {required String name}) async {
    expect(sessionId, 'codex:thread');
    expect(bytes, [10, 20]);
    if (rejectUpload) throw const DshRemoteException('UPLOAD_LIMIT', 'Upload rejected');
    uploads.add(name);
    return WorkspaceUploadedFile(name: 'notes (1).txt', path: './notes (1).txt', bytes: bytes.length);
  }

  @override
  Future<Object?> rawCall(String method, Object? params, {Duration? timeout}) async {
    expect(method, 'codex.app.call');
    final request = params as Map<String, Object?>;
    final args = request['params'] as Map<String, Object?>;
    switch (request['method']) {
      case 'project/list':
      case 'thread/list':
        return {'data': <Object?>[]};
      case 'model/list':
        return {
          'data': [
            {
              'model': 'selected-model',
              'displayName': 'Selected model',
              'isDefault': true,
              'defaultReasoningEffort': 'low',
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'low'},
                {'reasoningEffort': 'high'},
              ],
            },
          ],
        };
      case 'dsh/sessionHistory':
        expect(args['threadId'], 'thread');
        return {
          'header': {'id': 'codex:thread'},
          'cursor': materialized ? 1 : -1,
          'records': <Object?>[],
          'hasMore': false,
          'permissionPreset': reportedPermission,
          if (activeTurn) 'activeTurnId': 'active-turn',
        };
      case 'thread/resume':
        resumptions.add(args);
        if (args['permissionPreset'] case final String value when !rejectPermission) {
          reportedPermission = value;
        }
        final full = reportedPermission == 'danger-full-access';
        return {
          'thread': {'id': 'thread'},
          'sandbox': full ? 'danger-full-access' : 'workspace-write',
          'approvalPolicy': full ? 'never' : 'on-request',
        };
      case 'thread/unsubscribe':
        releases.add(args);
        releaseStarted?.complete();
        await releaseReply?.future;
        return {'status': 'unsubscribed'};
      case 'turn/start':
        expect(args['threadId'], 'thread');
        expect(args['model'], 'selected-model');
        expect(args['effort'], expectedEffort);
        if (expectedEffort == null) expect(args.containsKey('effort'), isFalse);
        expect(args.containsKey('permissionPreset'), isFalse);
        prompts.add(args['input'] as List<Object?>);
        if (rejectFirstPrompt && prompts.length == 1) {
          throw const DshRemoteException('CODEX_UPSTREAM_ERROR', 'Rejected turn');
        }
        return {
          'turn': {'id': 'turn'},
        };
    }
    throw StateError('Unexpected Codex method ${request['method']}');
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      throw StateError('DeepSeek RPC called for a Codex chat: $endpoint');

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('DeepSeek mux opened for a Codex chat');

  @override
  Future<void> close() async {}
}

Future<(ChatController, ChatState Function())> _chat(_CodexHost host) async {
  final client = DshClient.withCarrier(host);
  addTearDown(client.close);
  final container = ProviderContainer(
    overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: false)))],
  );
  addTearDown(container.dispose);
  final sessionId = codexSessionId('thread');
  container.read(backendProvider.notifier).set(ChatBackend.codex);
  container.read(currentSessionProvider.notifier).select(sessionId);
  final chat = chatProvider(sessionId);
  container.listen(chat, (_, _) {});
  container.listen(codexModelCatalogProvider, (_, _) {});
  final controller = container.read(chat.notifier);
  expect(await controller.resync(), isTrue);
  final catalog = await container.read(codexModelCatalogProvider.future);
  expect(catalog?.defaultSelection?.reasoningEffort, 'low');
  expect(
    await controller.setModel(
      ModelSelection(provider: 'codex', model: 'selected-model', reasoningEffort: host.expectedEffort),
    ),
    isTrue,
  );
  return (controller, () => container.read(chat));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uploads files before sending the actual Host path and inline image, reusing the upload on retry', () async {
    final host = _CodexHost()..rejectFirstPrompt = true;
    final (controller, _) = await _chat(host);
    final file = DraftAttachment(name: 'notes.txt', bytes: Uint8List.fromList([10, 20]));
    final image = DraftAttachment(
      name: 'photo.jpg',
      bytes: Uint8List.fromList([255, 216, 255]),
      mediaType: 'image/jpeg',
    );

    expect(await controller.send('Read the file', attachments: [file, image]), isFalse);
    expect(await controller.send('Read the file', attachments: [file, image]), isTrue);
    expect(host.uploads, ['notes.txt']);
    expect(host.prompts, hasLength(2));
    final expectedInput = unorderedEquals([
      {'type': 'image', 'mediaType': 'image/jpeg', 'data': base64Encode(image.bytes)},
      {'type': 'text', 'text': 'Read the file\n\n${appL10n.stateWorkspaceFilesHint}\n- "./notes (1).txt"'},
    ]);
    expect(host.prompts.first, expectedInput);
    expect(host.prompts.last, expectedInput);
  });

  test('an upload failure sends no prompt', () async {
    final host = _CodexHost()..rejectUpload = true;
    final (controller, _) = await _chat(host);
    final file = DraftAttachment(name: 'notes.txt', bytes: Uint8List.fromList([10, 20]));

    expect(await controller.send('Read the file', attachments: [file]), isFalse);
    expect(host.prompts, isEmpty);
  });

  test('sends the selected effort separately from a confirmed permission change', () async {
    final host = _CodexHost()
      ..materialized = true
      ..expectedEffort = 'high';
    final (controller, state) = await _chat(host);

    expect(
      await controller.setModel(
        const ModelSelection(provider: 'codex', model: 'selected-model', reasoningEffort: 'max'),
      ),
      isFalse,
    );
    expect(await controller.setCodexPermission('danger-full-access'), isTrue);
    expect(state().codexPermission, 'danger-full-access');
    expect(await controller.send('A prompt'), isTrue);
    expect(host.resumptions, [
      {'threadId': 'thread', 'permissionPreset': 'danger-full-access'},
      {'threadId': 'thread', 'model': 'selected-model'},
    ]);
    expect(host.prompts, hasLength(1));
  });

  test('keeps the effective permission when the Host refuses a change', () async {
    final host = _CodexHost()
      ..materialized = true
      ..rejectPermission = true;
    final (controller, state) = await _chat(host);

    expect(await controller.setCodexPermission('danger-full-access'), isFalse);
    expect(state().codexPermission, 'workspace-write');
    expect(state().codexPermissionEditable, isTrue);
  });

  test('does not issue a permission mutation for active or blank conversations', () async {
    for (final (materialized, active) in [(true, true), (false, false)]) {
      final host = _CodexHost()
        ..materialized = materialized
        ..activeTurn = active;
      final (controller, state) = await _chat(host);

      expect(state().codexPermissionEditable, isFalse);
      expect(await controller.setCodexPermission('danger-full-access'), isFalse);
      expect(host.resumptions, isEmpty);
    }
  });

  test('hands off an idle conversation and excludes sending or permission changes during release', () async {
    final host = _CodexHost()
      ..materialized = true
      ..releaseStarted = Completer<void>()
      ..releaseReply = Completer<void>();
    final (controller, state) = await _chat(host);

    final release = controller.releaseCodexForDesktop();
    await host.releaseStarted!.future;
    expect(await controller.send('Concurrent prompt'), isFalse);
    expect(await controller.setCodexPermission('danger-full-access'), isFalse);
    host.releaseReply!.complete();
    expect(await release, isTrue);
    expect(host.releases, [
      {'threadId': 'thread'},
    ]);
    expect(host.prompts, isEmpty);
    expect(host.resumptions, isEmpty);
    expect(state().codexPermissionEditable, isTrue);
  });

  test('leaves an active desktop conversation subscribed', () async {
    final host = _CodexHost()
      ..materialized = true
      ..activeTurn = true;
    final (controller, state) = await _chat(host);

    expect(await controller.releaseCodexForDesktop(), isFalse);
    expect(host.releases, isEmpty);
    expect(state().error, appL10n.stateChatAgentBusy);
  });
}
