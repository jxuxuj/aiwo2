import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/backend_state.dart';

/// A static Codex workspace for the shell. Real data is wired later; this is
/// the shape the drawer renders so the layout can be judged first.
class _FakeWorkspace {
  const _FakeWorkspace(this.name, this.threads);

  final String name;
  final List<String> threads;
}

const _fakeWorkspaces = <_FakeWorkspace>[
  _FakeWorkspace('电商agent', ['修一下库存同步的竞态', '把导出改成流式写', '给订单表加索引']),
  _FakeWorkspace('自动视频产出', ['字幕时间轴偏移了 0.3 秒', '批量转码脚本报错']),
  _FakeWorkspace('deepseek设定', ['看看工作区', '讲讲 Git rebase']),
  _FakeWorkspace('其他', ['一次性清理临时文件']),
];

const _models = <(String, String)>[
  ('Codex 5.1', '默认，速度和能力平衡'),
  ('Codex 5.1 Max', '更慢，复杂重构用'),
  ('Codex Mini', '快，适合小改动'),
];

/// The Codex shell: the same layout as the DeepSeek home — drawer on the left
/// (brand, search, filters, workspaces, host footer), top bar with the model
/// pill, greeting and suggestion cards, composer at the bottom.
///
/// Dark on purpose: Codex's own surface is near-black. Nothing here calls the
/// Host yet; the connection and its data layer stay intact behind it.
class CodexHome extends ConsumerStatefulWidget {
  const CodexHome({super.key});

  @override
  ConsumerState<CodexHome> createState() => _CodexHomeState();
}

class _CodexHomeState extends ConsumerState<CodexHome> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String _model = _models.first.$1;
  int _filter = 0;

  static const _filters = ['全部', '运行中', '待确认', '未读'];

  void _notWired(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what：这是外壳，数据下一步接')),
    );
  }

  /// The "+" sheet: the same four ways to bring something in as the DeepSeek
  /// composer. It only shows the choices today; the wiring comes with the
  /// adapter.
  Future<void> _attachSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('添加内容', style: TextStyle(fontWeight: FontWeight.w600))),
            ),
            for (final (icon, title, subtitle) in const [
              (Icons.photo_camera_outlined, '拍照', '直接拍一张给 Codex 看'),
              (Icons.photo_library_outlined, '从相册选', 'PNG / JPEG / WebP / GIF'),
              (Icons.folder_open_outlined, '工作区文件', '引用项目里已有的文件'),
              (Icons.attach_file, '本地文件', '放进工作区后告诉 Codex 路径'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(subtitle),
                onTap: () => Navigator.of(context).pop(title),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null && mounted) _notWired(choice);
  }

  Future<void> _pickModel() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Align(alignment: Alignment.centerLeft, child: Text('选择模型', style: TextStyle(fontWeight: FontWeight.w600))),
            ),
            for (final (name, subtitle) in _models)
              ListTile(
                title: Text(name),
                subtitle: Text(subtitle),
                trailing: name == _model ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(name),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _model = picked);
  }

  @override
  Widget build(BuildContext context) {
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6E8BFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0E1014),
    );
    final base = ThemeData(colorScheme: darkScheme, useMaterial3: true);
    return Theme(
      data: base,
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: scheme.surface,
            drawer: _CodexDrawer(
              filters: _filters,
              selected: _filter,
              onFilter: (index) {
                setState(() => _filter = index);
                Navigator.of(context).pop();
              },
              onClose: () => Navigator.of(context).pop(),
              onSwitch: () => ref.read(backendProvider.notifier).toggle(),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  _TopBar(
                    model: _model,
                    onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                    onModel: _pickModel,
                    onSwitch: () => ref.read(backendProvider.notifier).toggle(),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
                      children: [
                        const SizedBox(height: 40),
                        Center(
                          child: Text(
                            '中午好',
                            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(child: Text('今天想做点什么？', style: theme.textTheme.titleMedium)),
                        const SizedBox(height: 20),
                        Center(child: _Pill(icon: Icons.folder_outlined, label: '在「电商agent」中', onTap: () => _notWired('切换工作区'))),
                        const SizedBox(height: 12),
                        Center(
                          child: Wrap(
                            spacing: 12,
                            children: [
                              _Pill(icon: Icons.build_outlined, label: '标准模式', onTap: () => _notWired('模式')),
                              _Pill(icon: Icons.shield_outlined, label: '工作区内修改', onTap: () => _notWired('权限')),
                            ],
                          ),
                        ),
                        const SizedBox(height: 28),
                        GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.9,
                          children: [
                            for (final (icon, title, subtitle, tint) in const [
                              (Icons.terminal, '跑个命令', '在项目里执行并看输出', Color(0xFF5B8C5A)),
                              (Icons.description_outlined, '读这份文件', '让它先理解再动手', Color(0xFF4A6FA5)),
                              (Icons.alt_route, '新建分支', '从当前线程分叉', Color(0xFF7A5AA5)),
                              (Icons.bug_report_outlined, '查这个报错', '定位并给修复', Color(0xFFA5764A)),
                            ])
                              _SuggestionCard(icon: icon, title: title, subtitle: subtitle, tint: tint, onTap: () => _notWired(title)),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline, size: 16, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '长按侧栏里的对话，可以置顶、改名或归档',
                                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Composer(onAttach: _attachSheet, onNotWired: () => _notWired('发消息')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CodexDrawer extends StatelessWidget {
  const _CodexDrawer({
    required this.filters,
    required this.selected,
    required this.onFilter,
    required this.onClose,
    required this.onSwitch,
  });

  final List<String> filters;
  final int selected;
  final ValueChanged<int> onFilter;
  final VoidCallback onClose;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Drawer(
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'DSH · Codex',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _Pill(icon: Icons.swap_horiz, label: 'DSH', onTap: onSwitch),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                readOnly: true,
                onTap: () {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('搜索：这是外壳，数据下一步接')),
                  );
                },
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: '搜索对话',
                  isDense: true,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.chat_bubble_outline, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text('全部对话', style: theme.textTheme.labelLarge),
                  const Spacer(),
                  Icon(Icons.more_horiz, size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < filters.length; i++)
                    ChoiceChip(
                      label: Text(filters[i]),
                      selected: i == selected,
                      onSelected: (_) => onFilter(i),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            for (final workspace in _fakeWorkspaces) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: Text(
                  workspace.name,
                  style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              for (final thread in workspace.threads)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(thread, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('打开线程：这是外壳，数据下一步接')),
                    );
                  },
                ),
            ],
            const SizedBox(height: 12),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: Icon(Icons.desktop_windows_outlined, size: 18, color: scheme.onSurfaceVariant),
              title: Text('WIN-KDEQU2G0KLK', style: theme.textTheme.bodyMedium),
              subtitle: Text('远程 · P2P 点对点', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              trailing: Icon(Icons.settings, size: 18, color: scheme.onSurfaceVariant),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.model, required this.onMenu, required this.onModel, required this.onSwitch});

  final String model;
  final VoidCallback onMenu;
  final VoidCallback onModel;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      child: Row(
        children: [
          IconButton(onPressed: onMenu, icon: const Icon(Icons.menu), tooltip: '工作区'),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新对话', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'WIN-KDEQU2G0KLK · 远程',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _Pill(icon: Icons.memory, label: model, onTap: onModel),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.labelLarge),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 15, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.icon, required this.title, required this.subtitle, required this.tint, this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 17, color: tint),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.onAttach, required this.onNotWired});

  final VoidCallback onAttach;
  final VoidCallback onNotWired;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          IconButton.filledTonal(onPressed: onAttach, icon: const Icon(Icons.add), tooltip: '添加内容'),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              readOnly: true,
              onTap: onNotWired,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '给 Codex 发消息…',
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: onNotWired, icon: const Icon(Icons.mic), tooltip: '语音'),
        ],
      ),
    );
  }
}
