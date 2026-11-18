import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../remote/codex/codex_client.dart';
import '../../state/codex_state.dart';
import '../../state/connection_state.dart';
import '../chat/widgets/user_bubble.dart';

/// One Codex thread: history, a composer, stop and branch.
///
/// Rendering follows the native chat: the user's turns use the app's own
/// bubble, assistant turns sit on the backdrop and split their text into
/// paragraphs and fenced code blocks with a header and a copy action.
class CodexThreadPage extends ConsumerStatefulWidget {
  const CodexThreadPage({super.key, required this.threadId, this.title});

  final String threadId;
  final String? title;

  @override
  ConsumerState<CodexThreadPage> createState() => _CodexThreadPageState();
}

class _CodexThreadPageState extends ConsumerState<CodexThreadPage> {
  final _controller = TextEditingController();
  Timer? _poll;
  bool _sending = false;

  @override
  void dispose() {
    _poll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  CodexClient? get _client {
    final client = ref.read(activeConnectionProvider).value?.client;
    return client == null ? null : CodexClient(client.carrier);
  }

  void _startPolling() {
    _poll?.cancel();
    var ticks = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || ++ticks > 150) {
        timer.cancel();
        return;
      }
      ref.invalidate(codexHistoryProvider(widget.threadId));
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final client = _client;
    if (text.isEmpty || client == null || _sending) return;
    setState(() => _sending = true);
    try {
      await client.sendText(widget.threadId, text);
      _controller.clear();
      ref.invalidate(codexHistoryProvider(widget.threadId));
      _startPolling();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    final client = _client;
    if (client == null || _sending) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, imageQuality: 90);
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _sending = true);
    try {
      await client.sendImage(widget.threadId, bytes, _mediaTypeOf(picked.path), text: _controller.text);
      _controller.clear();
      ref.invalidate(codexHistoryProvider(widget.threadId));
      _startPolling();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送图片失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _mediaTypeOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  Future<void> _stop(CodexHistory page) async {
    final client = _client;
    final turnId = page.activeTurnId;
    if (client == null || turnId == null) return;
    try {
      await client.interrupt(widget.threadId, turnId);
      ref.invalidate(codexHistoryProvider(widget.threadId));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('中断失败：$error')));
      }
    }
  }

  Future<void> _fork() async {
    final client = _client;
    if (client == null) return;
    try {
      final id = await client.fork(widget.threadId);
      if (!mounted) return;
      if (id == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('分支已创建，但主机没有返回新线程 ID')));
        return;
      }
      ref.invalidate(codexThreadsProvider);
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => CodexThreadPage(threadId: id, title: '分支')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分支失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(codexHistoryProvider(widget.threadId));
    final page = history.value;
    final running = page?.activeTurnId != null;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Codex 线程'),
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(codexHistoryProvider(widget.threadId)),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          IconButton(onPressed: _fork, icon: const Icon(Icons.call_split), tooltip: '创建分支'),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _Body(threadId: widget.threadId, history: history)),
          SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, size: 13, color: scheme.onTertiaryContainer),
                          const SizedBox(width: 4),
                          Text('完全权限', style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer)),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton.filledTonal(onPressed: _sending ? null : _pickImage, icon: const Icon(Icons.add)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: '给 Codex 发消息…',
                            filled: true,
                            fillColor: scheme.surfaceContainerHighest,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (running)
                        IconButton.filledTonal(
                          onPressed: page == null ? null : () => _stop(page),
                          icon: const Icon(Icons.stop),
                          tooltip: '停止',
                        )
                      else
                        IconButton.filled(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send),
                          tooltip: '发送',
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.threadId, required this.history});

  final String threadId;
  final AsyncValue<CodexHistory> history;

  @override
  Widget build(BuildContext context) {
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('读取历史失败\n\n$error')),
      ),
      data: (page) {
        if (page.messages.isEmpty) {
          return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('这个线程还没有可显示的消息')));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: page.messages.length,
          itemBuilder: (context, index) => _Bubble(threadId: threadId, message: page.messages[index]),
        );
      },
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.threadId, required this.message});

  final String threadId;
  final CodexMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = <Widget>[
      for (final id in message.attachmentIds) _AttachmentImage(threadId: threadId, attachmentId: id),
    ];
    if (message.fromUser) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ...images,
          if (message.text.isNotEmpty) UserBubble(text: message.text),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...images,
          if (message.text.isNotEmpty) _RichText(text: message.text),
          _ActionBar(text: message.text),
        ],
      ),
    );
  }
}

/// Paragraphs plus fenced code blocks, the way the native transcript splits
/// an assistant turn.
class _RichText extends StatelessWidget {
  const _RichText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(text);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in blocks)
          if (block.code == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SelectableText(block.text, style: theme.textTheme.bodyLarge),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _CodeBlock(language: block.language, code: block.code!),
            ),
      ],
    );
  }

  static List<_Block> _parse(String source) {
    final blocks = <_Block>[];
    final lines = source.split('\n');
    final buffer = StringBuffer();
    var language = '';
    var inCode = false;
    void flush() {
      final text = buffer.toString().trimRight();
      if (text.trim().isNotEmpty) blocks.add(_Block(text: text));
      buffer.clear();
    }

    for (final line in lines) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        if (!inCode) {
          flush();
          inCode = true;
          language = trimmed.substring(3).trim();
        } else {
          blocks.add(_Block(text: '', code: buffer.toString().trimRight(), language: language));
          buffer.clear();
          inCode = false;
          language = '';
        }
        continue;
      }
      buffer.writeln(line);
    }
    if (inCode) {
      blocks.add(_Block(text: '', code: buffer.toString().trimRight(), language: language));
    } else {
      flush();
    }
    return blocks;
  }
}

class _Block {
  const _Block({required this.text, this.code, this.language = ''});

  final String text;
  final String? code;
  final String language;
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language.isEmpty ? 'text' : language,
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
                    }
                  },
                  icon: const Icon(Icons.copy, size: 14),
                  label: const Text('复制'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget icon(IconData data, String tip, VoidCallback? onTap) => IconButton(
          onPressed: onTap,
          icon: Icon(data, size: 17),
          tooltip: tip,
          color: scheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          padding: EdgeInsets.zero,
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        icon(Icons.copy_all, '复制', () async {
          await Clipboard.setData(ClipboardData(text: text));
        }),
        icon(Icons.ios_share, '分享', null),
        icon(Icons.volume_up_outlined, '朗读', null),
        icon(Icons.hub_outlined, '分支', null),
      ],
    );
  }
}

/// One image of a message, decoded from the Host on demand.
class _AttachmentImage extends ConsumerWidget {
  const _AttachmentImage({required this.threadId, required this.attachmentId});

  final String threadId;
  final String attachmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(codexAttachmentProvider((threadId: threadId, attachmentId: attachmentId)));
    final scheme = Theme.of(context).colorScheme;
    return bytes.when(
      loading: () => Container(
        width: 180,
        height: 120,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (_, __) => const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('[图片加载失败]')),
      data: (data) => data == null
          ? const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('[图片不可用]'))
          : Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(data, width: 220, fit: BoxFit.contain),
              ),
            ),
    );
  }
}
