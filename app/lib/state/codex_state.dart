import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/codex/codex_client.dart';
import 'connection_state.dart';
import 'hosts_state.dart';

const _sessionPrefix = 'codex:';

String codexSessionId(String threadId) => '$_sessionPrefix$threadId';

String? codexThreadId(String sessionId) =>
    sessionId.startsWith(_sessionPrefix) ? sessionId.substring(_sessionPrefix.length) : null;

class CodexWorkspaceSelection extends Notifier<Map<HostRef, String>> {
  @override
  Map<HostRef, String> build() => const {};

  void select(String? workspaceId) {
    final host = ref.read(activeHostProvider);
    final updated = {...state};
    if (workspaceId == null) {
      updated.remove(host);
    } else {
      updated[host] = workspaceId;
    }
    state = updated;
  }
}

final codexWorkspaceSelectionProvider = NotifierProvider<CodexWorkspaceSelection, Map<HostRef, String>>(
  CodexWorkspaceSelection.new,
);

final selectedCodexWorkspaceProvider = Provider<Workspace?>((ref) {
  final host = ref.watch(activeHostProvider);
  final id = ref.watch(codexWorkspaceSelectionProvider.select((state) => state[host]));
  if (id == null) return null;
  return ref.watch(codexWorkspaceListProvider).asData?.value.where((item) => item.workspaceId == id).firstOrNull;
});

final selectedCodexCwdProvider = Provider<String?>((ref) => ref.watch(selectedCodexWorkspaceProvider)?.path);

/// One Codex project with the threads that belong to it.
class CodexWorkspace {
  const CodexWorkspace({required this.name, required this.threads, this.id, this.root});

  final String? id;
  final String name;
  final String? root;
  final List<CodexThread> threads;
}

/// Codex projects and their threads, in the shape the drawer needs.
final codexWorkspaceProvider = FutureProvider.autoDispose<List<CodexWorkspace>>((ref) async {
  ref.watch(activeHostProvider);
  final connection = ref.watch(activeConnectionProvider);
  final client = connection.isLoading ? null : connection.asData?.value?.client;
  if (client == null) return const <CodexWorkspace>[];
  final codex = CodexClient(client.carrier);
  List<CodexProject> projects;
  try {
    projects = await codex.listProjects();
  } on DshRemoteException catch (error) {
    if (!const {'METHOD_NOT_ALLOWED', 'METHOD_NOT_FOUND', 'CODEX_UPSTREAM_ERROR'}.contains(error.code)) rethrow;
    projects = const [];
  }
  if (!ref.mounted) return const [];
  final threads = await codex.listThreads(limit: 100);
  final roots = {for (final project in projects) project.id: ?_absolutePath(project.root)};

  if (roots.isEmpty) {
    // Only the Host's exact thread directories authorize fallback workspaces.
    final groups = <String, List<CodexThread>>{};
    for (final thread in threads) {
      if (_absolutePath(thread.cwd) case final path?) {
        groups.putIfAbsent(path, () => []).add(thread);
      }
    }
    return [
      for (final MapEntry(key: path, value: members) in groups.entries)
        CodexWorkspace(
          id: 'cwd:$path',
          name: _folderName(members.first.cwd!),
          root: members.first.cwd,
          threads: members,
        ),
    ];
  }

  final byProject = <String, List<CodexThread>>{};
  for (final thread in threads) {
    final cwd = _absolutePath(thread.cwd);
    String? id = thread.projectId;
    if (!roots.containsKey(id)) {
      String? matchedRoot;
      for (final MapEntry(key: candidateId, value: root) in roots.entries) {
        if (cwd == null || (cwd != root && !cwd.startsWith(root.endsWith('/') ? root : '$root/'))) continue;
        if (matchedRoot == null || root.length > matchedRoot.length) {
          id = candidateId;
          matchedRoot = root;
        }
      }
    }
    if (id != null && roots.containsKey(id)) byProject.putIfAbsent(id, () => []).add(thread);
  }
  return [
    for (final project in projects)
      if (roots.containsKey(project.id))
        CodexWorkspace(
          id: project.id,
          name: project.name,
          root: project.root,
          threads: byProject[project.id] ?? const <CodexThread>[],
        ),
  ];
});

String? _absolutePath(String? path) {
  if (path == null) return null;
  final hasDrive = RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(path);
  final windows = hasDrive || path.startsWith(r'\\') || path.startsWith('//');
  if (!windows && !path.startsWith('/')) return null;
  final normalized = windows ? path.replaceAll('\\', '/').toLowerCase() : path;
  if (normalized == '/' || (hasDrive && normalized.length == 3)) return normalized;
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

String _folderName(String path) =>
    path.split(RegExp(r'[/\\]')).lastWhere((segment) => segment.isNotEmpty, orElse: () => path);

DateTime _threadUpdatedAt(int? timestamp) {
  final value = timestamp ?? 0;
  return DateTime.fromMillisecondsSinceEpoch(value > 100000000000 ? value : value * 1000);
}

final codexWorkspaceListProvider = Provider.autoDispose<AsyncValue<List<Workspace>>>((ref) {
  final source = ref.watch(codexWorkspaceProvider);
  if (source.isLoading) return const AsyncLoading();
  return source.whenData(
    (groups) => [
      for (final group in groups)
        if (group.id != null && group.root != null)
          Workspace(
            workspaceId: group.id!,
            path: group.root!,
            title: group.name,
            sessionIds: [for (final thread in group.threads) codexSessionId(thread.id)],
          ),
    ],
  );
});

final codexSessionListProvider = Provider.autoDispose<AsyncValue<List<SessionSummary>>>((ref) {
  final source = ref.watch(codexWorkspaceProvider);
  if (source.isLoading) return const AsyncLoading();
  return source.whenData((groups) {
    final sessions = <SessionSummary>[
      for (final group in groups)
        for (final thread in group.threads)
          SessionSummary(
            sessionId: codexSessionId(thread.id),
            updatedAt: _threadUpdatedAt(thread.updatedAt),
            running: thread.running,
            blank: false,
            agentAvailable: false,
            cwd: thread.cwd,
            projections: SessionProjections(-1, {'title': thread.title}),
            raw: {'isPinned': thread.isPinned},
          ),
    ];
    return sessions..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  });
});

/// The models the Host's Codex offers.
final codexModelsProvider = FutureProvider.autoDispose<List<(String id, String name)>>((ref) async {
  final client = ref.watch(activeConnectionProvider).value?.client;
  if (client == null) return const <(String, String)>[];
  return CodexClient(client.carrier).listModels();
});
