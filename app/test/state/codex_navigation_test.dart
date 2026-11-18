import 'package:dsh_app/remote/codex/codex_client.dart';
import 'package:dsh_app/state/backend_state.dart';
import 'package:dsh_app/state/codex_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('desktop links use the stored native Codex thread ID', () {
    const id = '01962a3d-a27f-7123-a5b3-993097c06196';
    expect(codexDesktopThreadLink(codexSessionId(id)).toString(), 'codex://threads/$id');
    expect(codexDesktopThreadLink('deepseek-thread'), isNull);
    expect(codexDesktopThreadLink(codexSessionId('')), isNull);
  });

  test('workspace comparisons join ordinary and extended Windows paths', () {
    expect(codexWorkspaceComparisonPath(r'\\?\D:\Work\App'), codexWorkspaceComparisonPath(r'd:\work\app\'));
    expect(codexWorkspaceComparisonPath(r'\\?\UNC\Server\Share'), codexWorkspaceComparisonPath(r'\\server\share'));
    expect(codexWorkspaceComparisonPath(r'\\?\D:\'), 'd:/');
    expect(codexWorkspaceComparisonPath('/home/Work/'), '/home/Work');
    expect(codexWorkspaceComparisonPath('relative/path'), isNull);
  });

  test('switching backends restores their respective session selections', () async {
    final container = ProviderContainer.test();
    await container.read(activeHostProvider.notifier).ready;
    final backend = container.read(backendProvider.notifier);
    container.read(currentSessionProvider.notifier).select('deepseek-thread');

    backend.set(ChatBackend.codex);
    expect(container.read(currentSessionProvider), isNull);
    final codexId = codexSessionId('native-thread');
    container.read(currentSessionProvider.notifier).select(codexId);
    container.read(currentSessionProvider.notifier).select('wrong-backend-thread');
    expect(container.read(currentSessionProvider), codexId);

    backend.set(ChatBackend.deepseek);
    expect(container.read(currentSessionProvider), 'deepseek-thread');
    container.read(currentSessionProvider.notifier).select(codexId);
    expect(container.read(currentSessionProvider), 'deepseek-thread');
    backend.set(ChatBackend.codex);
    expect(container.read(currentSessionProvider), codexId);
    expect(codexThreadId(codexId), 'native-thread');
  });

  test('the shared drawer filters Codex sessions by the selected workspace on that host', () async {
    final container = ProviderContainer.test(
      overrides: [
        codexWorkspaceProvider.overrideWith((ref) async {
          final host = ref.watch(activeHostProvider);
          return [
            CodexWorkspace(
              id: 'project',
              root: '/${host.id}/project',
              name: 'Project',
              threads: [const CodexThread(id: 'current', name: 'Current', updatedAt: 1700000000)],
            ),
            const CodexWorkspace(
              id: 'other',
              root: '/other',
              name: 'Other project',
              threads: [CodexThread(id: 'other', name: 'Other')],
            ),
          ];
        }),
      ],
    );
    final hosts = container.read(activeHostProvider.notifier);
    const first = HostRef.relay('first');
    const second = HostRef.relay('second');
    hosts.select(first);
    container.read(backendProvider.notifier).set(ChatBackend.codex);
    container.listen(drawerScopeProvider, (_, _) {});
    await container.read(codexWorkspaceProvider.future);
    expect(container.read(drawerScopeProvider)?.sessions.length, 2);

    container.read(codexWorkspaceSelectionProvider.notifier).select('project');
    expect(container.read(selectedWorkspaceProvider)?.title, 'Project');
    expect(container.read(selectedCodexCwdProvider), '/first/project');
    expect(container.read(drawerScopeProvider)?.sessions.map((session) => session.sessionId), [
      codexSessionId('current'),
    ]);
    expect(container.read(drawerScopeProvider)?.sessions.single.updatedAt.millisecondsSinceEpoch, 1700000000000);
    final thread = codexSessionId('current');
    container.read(currentSessionProvider.notifier).select(thread);

    hosts.select(second);
    await container.read(codexWorkspaceProvider.future);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(selectedCodexCwdProvider), isNull);
    expect(container.read(drawerScopeProvider)?.sessions.length, 2);
    hosts.select(first);
    await container.read(codexWorkspaceProvider.future);
    expect(container.read(selectedCodexCwdProvider), '/first/project');
    expect(container.read(currentSessionProvider), thread);
  });
}
