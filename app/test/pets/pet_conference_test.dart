import 'dart:convert';

import 'package:dsh_app/pets/pet_conference.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/state/backend_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/pets/pet_conference_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each person message reaches both AIs before at most three peer replies', () async {
    final requests = <(ChatBackend, Map<String, Object?>)>[];
    final messages = <ConferenceMessage>[];
    await runConferenceRound(
      message: '一起聊聊',
      reply: (backend, prompt) async {
        final body = jsonDecode(prompt.split('\n').last) as Map<String, Object?>;
        requests.add((backend, body));
        expect(prompt, contains('at most three short sentences'));
        return List.filled(500, '鲸').join();
      },
      publish: (message) async => messages.add(message),
      reportError: (backend, error) => fail('${backend.label} $error'),
      current: () => true,
    );
    expect(requests.map((item) => item.$1), [
      ChatBackend.deepseek,
      ChatBackend.codex,
      ChatBackend.deepseek,
      ChatBackend.codex,
      ChatBackend.deepseek,
    ]);
    expect(requests.every((item) => item.$2['user'] == '一起聊聊'), isTrue);
    expect(requests.take(2).every((item) => !item.$2.containsKey('peerReply')), isTrue);
    expect(requests.skip(2).every((item) => item.$2.containsKey('peerReply')), isTrue);
    expect(messages.length, 5);
    expect(messages.every((item) => item.text.runes.length == conferenceReplyLimit), isTrue);
  });

  test('a peer can stop the discussion and a failed participant does not suppress the other answer', () async {
    final messages = <ConferenceMessage>[];
    var calls = 0;
    await runConferenceRound(
      message: '你好',
      reply: (backend, prompt) async => ++calls == 3 ? conferenceStopToken : backend.label,
      publish: (message) async => messages.add(message),
      reportError: (backend, error) => fail('${backend.label} $error'),
      current: () => true,
    );
    expect(calls, 3);
    expect(messages.map((item) => item.author), ChatBackend.values);

    final failures = <ChatBackend>[];
    messages.clear();
    await runConferenceRound(
      message: '再试一次',
      reply: (backend, prompt) async {
        expect(prompt, isNot(contains('"peerReply"')));
        if (backend == ChatBackend.codex) throw StateError('offline');
        return '你好';
      },
      publish: (message) async => messages.add(message),
      reportError: (backend, _) => failures.add(backend),
      current: () => true,
    );
    expect(failures, [ChatBackend.codex]);
    expect(messages.single.author, ChatBackend.deepseek);
  });

  test('history and individual branch acknowledgments survive reloads', () async {
    SharedPreferences.setMockInitialValues({});
    final firstApp = ProviderContainer();
    await firstApp.read(petConferencesProvider.future);
    final store = firstApp.read(petConferencesProvider.notifier);
    const room = PetConference(
      id: 'meeting',
      title: '例会',
      deepseek: ConferenceParticipant(HostRef.local, 'dsh-source', 'DSH'),
      codex: ConferenceParticipant(HostRef.relay('pc'), 'codex-source', 'Codex'),
    );
    const message = ConferenceMessage(null, '记录下来');
    await store.create(room);
    await store.saveBranch(room.id, ChatBackend.deepseek, 'dsh-branch');
    await expectLater(store.saveBranch(room.id, ChatBackend.codex, room.codex.source), throwsStateError);
    await store.saveBranch(room.id, ChatBackend.codex, 'codex-branch');
    await Future.wait([
      store.append(room.id, message),
      store.append(room.id, const ConferenceMessage(ChatBackend.codex, '我收到了')),
      store.append(room.id, const ConferenceMessage(ChatBackend.deepseek, '我也收到了')),
    ]);
    await store.beginDeletion(room.id);
    await store.markDeleted(room.id, ChatBackend.deepseek);
    await store.finishDeletion(room.id);
    firstApp.dispose();

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    final recovered = (await restarted.read(petConferencesProvider.future)).single;
    expect(recovered.ready, isTrue);
    expect(recovered.deleting, isTrue);
    expect(recovered.deleted, {ChatBackend.deepseek});
    expect(recovered.messages.map((item) => item.text), ['记录下来', '我收到了', '我也收到了']);
    expect(recovered.codex.source, 'codex-source');
    expect(recovered.codex.branch, 'codex-branch');
    final retry = restarted.read(petConferencesProvider.notifier);
    await retry.markDeleted(room.id, ChatBackend.codex);
    await retry.finishDeletion(room.id);
    expect(await restarted.read(petConferencesProvider.future), isEmpty);
  });

  test('DeepSeek and Codex remember distinct pet selections', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    final prefs = first.read(petPrefsProvider.notifier);
    await _waitForPetPrefs(first);
    await prefs.setPack('whale-girl', backend: ChatBackend.deepseek);
    await prefs.setPack('deepy-whale', backend: ChatBackend.codex);
    first.dispose();

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    await _waitForPetPrefs(restarted);
    expect(restarted.read(activePetPackIdProvider), 'whale-girl');
    restarted.read(backendProvider.notifier).set(ChatBackend.codex);
    expect(restarted.read(activePetPackIdProvider), 'deepy-whale');
    expect(restarted.read(petPackIdProvider(ChatBackend.deepseek)), 'whale-girl');
  });

  testWidgets('saved rooms open their conversations without connecting to a host', (tester) async {
    const room = PetConference(
      id: 'saved',
      title: '上次大会',
      deepseek: ConferenceParticipant(HostRef.local, 'dsh-source', 'DSH', branch: 'dsh-branch'),
      codex: ConferenceParticipant(HostRef.relay('pc'), 'codex-source', 'Codex', branch: 'codex-branch'),
      messages: [
        ConferenceMessage(null, '我们已经见过'),
        ConferenceMessage(ChatBackend.deepseek, '第一次回应'),
        ConferenceMessage(ChatBackend.codex, '第二次回应'),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'pet.conferences.v1': jsonEncode([room.toJson()]),
      'pet.pack': 'none',
      'pet.codex.pack': 'none',
    });
    await tester.pumpWidget(
      testApp(
        const PetConferencePage(),
        overrides: [connectionForHostProvider.overrideWith((_, _) => const AsyncData(null))],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('上次大会'));
    await tester.pumpAndSettle();
    expect(find.text('我们已经见过'), findsOneWidget);
    expect(find.text('第一次回应'), findsOneWidget);
    expect(find.text('第二次回应'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.arrow_upward), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward)).onPressed, isNull);
    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pumpAndSettle();
    expect(find.text('移除这场大会及其历史，并归档它创建的两个聊天分支？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('我们已经见过'), findsOneWidget);
  });

  testWidgets('a shared desktop host can create a room and archive both branches without a deletion API', (
    tester,
  ) async {
    usePhoneView(tester);
    const host = HostRef.relay('pc', name: '会议电脑');
    final carrier = _MeetingCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    SharedPreferences.setMockInitialValues({
      ActiveHostController.prefsKey: host.encode(),
      'pet.pack': 'none',
      'pet.codex.pack': 'none',
    });
    await tester.pumpWidget(
      testApp(
        const PetConferencePage(),
        overrides: [
          connectionForHostProvider.overrideWith(
            (_, selected) => AsyncData(
              selected == host
                  ? HostConnection(client: client, isLocal: false, kind: HostKind.relay, hostId: host.id)
                  : null,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '创建大会'));
    await tester.pumpAndSettle();
    expect(find.text('选择对话'), findsNWidgets(2));
    final name = find.byType(TextField);
    expect(tester.getTopLeft(name).dx, greaterThanOrEqualTo(20));
    await tester.enterText(name, '联合大会');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (final (index, label) in ['DeepSeek 原对话', 'Codex 原对话'].indexed) {
      final choose = find.text('选择对话').at(index);
      await tester.ensureVisible(choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    final create = find.widgetWithText(FilledButton, '创建大会');
    await tester.ensureVisible(create);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.text('联合大会'), findsOneWidget);
    expect(carrier.forks, ['dsh-source', 'codex-source']);

    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除大会'));
    await tester.pumpAndSettle();
    expect(carrier.archives, ['dsh-branch', 'codex-branch']);
    expect(find.text('还没有大会'), findsOneWidget);
  });
}

class _MeetingCarrier extends DshCarrier {
  final forks = <String>[];
  final archives = <String>[];

  @override
  String get kind => 'fixture';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'session/list') {
      return const RpcOk({
        'items': [
          {
            'sessionId': 'dsh-source',
            'projections': {'values': {'title': 'DeepSeek 原对话'}},
          },
        ],
      });
    }
    final id = (args['request'] as Map)['sessionId'] as String;
    return switch (endpoint) {
      'session/fork' => RpcOk({'sessionId': _fork(id, 'dsh-branch')}),
      'workspace/archiveSession' => RpcOk({
        'archivedSessionIds': [_archive(id)],
      }),
      _ => throw UnsupportedError(endpoint),
    };
  }

  @override
  Future<Object?> rawCall(String method, Object? params, {Duration? timeout}) async {
    expect(method, 'codex.app.call');
    final request = params as Map;
    final id = (request['params'] as Map)['threadId'];
    return switch (request['method']) {
      'thread/list' => {
        'data': [
          {'id': 'codex-source', 'name': 'Codex 原对话'},
        ],
      },
      'thread/fork' => {
        'thread': {'id': _fork(id as String, 'codex-branch')},
      },
      'thread/archive' => {'archivedId': _archive(id as String)},
      _ => throw UnsupportedError(request['method'] as String),
    };
  }

  String _fork(String id, String child) {
    forks.add(id);
    return child;
  }

  String _archive(String id) {
    archives.add(id);
    return id;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

Future<void> _waitForPetPrefs(ProviderContainer container) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (container.read(petPrefsProvider).loaded) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Pet preferences did not load');
}
