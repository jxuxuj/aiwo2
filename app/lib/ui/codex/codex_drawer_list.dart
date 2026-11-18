import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../remote/codex/codex_client.dart';
import '../../state/codex_state.dart';
import '../../state/connection_state.dart';
import '../shell/drawer/session_tile.dart';
import 'codex_thread_page.dart';

/// The drawer's conversation list, showing Codex workspaces and threads.
///
/// It reuses the app's own row widgets ([SessionTile] / [DrawerEyebrow]) so the
/// Codex side looks exactly like the DeepSeek side; only the data source and
/// the tap target differ.
class CodexDrawerList extends ConsumerWidget {
  const CodexDrawerList({super.key, required this.onClose});

  final VoidCallback onClose;

  /// New thread in the first workspace that has a root directory.
  Future<void> _newThread(BuildContext context, WidgetRef ref, List<CodexWorkspace> groups) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) return;
    String? root;
    for (final group in groups) {
      if (group.root != null && group.root!.isNotEmpty) {
        root = group.root;
        break;
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    if (root == null) {
      messenger.showSnackBar(const SnackBar(content: Text('没有可用的工作区目录')));
      return;
    }
    try {
      final id = await CodexClient(client.carrier).startThread(root);
      if (!context.mounted) return;
      if (id == null) {
        messenger.showSnackBar(const SnackBar(content: Text('已创建，但主机没有返回线程 ID')));
        return;
      }
      ref.invalidate(codexWorkspaceProvider);
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => CodexThreadPage(threadId: id, title: '新对话')),
      );
      onClose();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('新建失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspaces = ref.watch(codexWorkspaceProvider);
    return workspaces.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText('Codex 读取失败\n\n$error'),
      ),
      data: (groups) {
        if (groups.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('这台主机上没有 Codex 工作区'),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(codexWorkspaceProvider),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Codex 工作区', style: Theme.of(context).textTheme.labelLarge),
                    ),
                    TextButton.icon(
                      onPressed: () => _newThread(context, ref, groups),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建'),
                    ),
                  ],
                ),
              ),
              for (final group in groups) ...[
                DrawerEyebrow(group.name),
                if (group.threads.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
                    child: Text('（没有线程）', style: TextStyle(fontSize: 12)),
                  ),
                for (final thread in group.threads)
                  SessionTile(
                    title: thread.title,
                    running: false,
                    current: false,
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => CodexThreadPage(threadId: thread.id, title: thread.title),
                        ),
                      );
                      onClose();
                    },
                    onLongPress: null,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
