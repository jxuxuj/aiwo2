import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/backend_state.dart';

/// The Codex home: the same layout as the DeepSeek one — menu, title and host
/// on the top bar, the model pill on the right, the greeting and the four
/// suggestion cards, the composer with + / mic at the bottom — filled with
/// Codex content.
///
/// It is deliberately not wired to any backend yet: the switch animation and
/// the shell come first, the data adapter next. Nothing here calls the Host.
class CodexHome extends ConsumerWidget {
  const CodexHome({super.key});

  static const _suggestions = <(IconData, String, String, Color)>[
    (Icons.terminal, '跑个命令', '在项目里执行并看输出', Color(0xFF5B8C5A)),
    (Icons.description_outlined, '读这份文件', '让它先理解再动手', Color(0xFF4A6FA5)),
    (Icons.alt_route, '新建分支', '从当前线程分叉', Color(0xFF7A5AA5)),
    (Icons.bug_report_outlined, '查这个报错', '定位并给修复', Color(0xFFA5764A)),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Codex's own shell is dark regardless of the app theme: near-black
    // backdrop, cool grey cards, one accent. Everything below reads the
    // colour scheme, so wrapping once is enough.
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
            backgroundColor: scheme.surface,
            body: SafeArea(
              child: Column(
                children: [
                  _TopBar(onSwitch: () => ref.read(backendProvider.notifier).toggle()),
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
                        Center(child: _Pill(icon: Icons.folder_outlined, label: '在「Codex」中')),
                        const SizedBox(height: 12),
                        Center(
                          child: Wrap(
                            spacing: 12,
                            children: const [
                              _Pill(icon: Icons.build_outlined, label: '标准模式'),
                              _Pill(icon: Icons.shield_outlined, label: '工作区内修改'),
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
                            for (final (icon, title, subtitle, tint) in _suggestions)
                              _SuggestionCard(icon: icon, title: title, subtitle: subtitle, tint: tint),
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
                  _Composer(onUseDeepSeek: () => ref.read(backendProvider.notifier).toggle()),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onSwitch});

  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          IconButton(onPressed: onSwitch, icon: const Icon(Icons.menu), tooltip: '切回 DSH'),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新对话', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text('Codex · 远程', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
          _Pill(icon: Icons.swap_horiz, label: '切回 DSH', onTap: onSwitch),
          const SizedBox(width: 8),
          _Pill(icon: Icons.memory, label: 'Codex'),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.icon, required this.title, required this.subtitle, required this.tint});

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
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
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.onUseDeepSeek});

  final VoidCallback onUseDeepSeek;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _notWired() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这是 Codex 界面外壳，数据还没接上（下一步）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          IconButton.filledTonal(onPressed: _notWired, icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              readOnly: true,
              onTap: _notWired,
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
          IconButton.filled(onPressed: _notWired, icon: const Icon(Icons.mic)),
        ],
      ),
    );
  }
}
