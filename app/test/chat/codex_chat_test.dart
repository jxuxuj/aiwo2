import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/codex_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CodexHost extends DshCarrier implements WorkspaceUploadCarrier {
  final uploads = <String>[];
  final prompts = <List<Object?>>[];
  bool rejectFirstPrompt = false;
  bool rejectUpload = false;

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
      case 'dsh/sessionHistory':
        expect(args['threadId'], 'thread');
        return {
          'header': {'id': 'codex:thread'},
          'cursor': -1,
          'records': <Object?>[],
          'hasMore': false,
        };
      case 'turn/start':
        expect(args['threadId'], 'thread');
        expect(args['model'], 'selected-model');
        expect(args.containsKey('effort'), isFalse);
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

Future<ChatController> _chat(_CodexHost host) async {
  final client = DshClient.withCarrier(host);
  addTearDown(client.close);
  final container = ProviderContainer(
    overrides: [activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: false)))],
  );
  addTearDown(container.dispose);
  final chat = chatProvider(codexSessionId('thread'));
  container.listen(chat, (_, _) {});
  final controller = container.read(chat.notifier);
  expect(await controller.resync(), isTrue);
  expect(await controller.setModel(const ModelSelection(provider: 'codex', model: 'selected-model')), isTrue);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uploads files before sending the actual Host path and inline image, reusing the upload on retry', () async {
    final host = _CodexHost()..rejectFirstPrompt = true;
    final controller = await _chat(host);
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
    final controller = await _chat(host);
    final file = DraftAttachment(name: 'notes.txt', bytes: Uint8List.fromList([10, 20]));

    expect(await controller.send('Read the file', attachments: [file]), isFalse);
    expect(host.prompts, isEmpty);
  });
}
