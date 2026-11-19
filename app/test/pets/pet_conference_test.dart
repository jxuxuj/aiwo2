import 'dart:convert';

import 'package:dsh_app/pets/pet_conference.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/state/backend_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/pets/pet_conference_page.dart';
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
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除此大会的历史和它创建的两个聊天分支？原来的两条对话会保留。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('我们已经见过'), findsOneWidget);
  });
}

Future<void> _waitForPetPrefs(ProviderContainer container) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (container.read(petPrefsProvider).loaded) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Pet preferences did not load');
}
