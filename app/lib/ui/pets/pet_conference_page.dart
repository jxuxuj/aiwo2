import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_conference.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../../remote/codex/codex_client.dart';
import '../../state/backend_state.dart';
import '../../state/codex_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../shell/page_frame.dart';
import 'pet_picker.dart';

Future<void> showPetConferences(BuildContext context) {
  final navigator = Navigator.of(context);
  navigator.pop();
  return navigator.push(MaterialPageRoute<void>(builder: (_) => const PetConferencePage()));
}

class PetConferencePage extends ConsumerWidget {
  const PetConferencePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final rooms = ref.watch(petConferencesProvider);
    return AppPage.list(
      title: l10n.conferenceTitle,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: FilledButton.icon(
            onPressed: rooms.hasValue
                ? () {
                    unawaited(
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _CreateConference())),
                    );
                  }
                : null,
            icon: const Icon(Icons.add),
            label: Text(l10n.conferenceCreate),
          ),
        ),
        const SizedBox(height: 12),
        ...rooms.when(
          loading: () => const [Center(child: CircularProgressIndicator())],
          error: (_, _) => [Text(l10n.conferenceHistoryError)],
          data: (rooms) => [
            if (rooms.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Text(l10n.conferenceEmpty, textAlign: TextAlign.center),
              ),
            for (final room in rooms)
              Card(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: Text(room.title),
                  subtitle: Text(
                    room.deleting
                        ? l10n.conferenceDeletePending
                        : !room.ready
                        ? l10n.conferenceSetupPending
                        : '${room.deepseek.title} · ${room.codex.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => unawaited(
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ConferenceRoom(room.id))),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

typedef _SourceKey = ({HostRef host, ChatBackend backend});

final _conferenceSources = FutureProvider.autoDispose.family<List<ConferenceParticipant>?, _SourceKey>((
  ref,
  key,
) async {
  final client = ref.watch(connectionForHostProvider(key.host)).asData?.value?.client;
  if (client == null) return null;
  return switch (key.backend) {
    ChatBackend.deepseek => [
      for (final session in await client.listSessions())
        if (!session.blank && !session.running && !session.isSubagent && session.sessionId.isNotEmpty)
          ConferenceParticipant(key.host, session.sessionId, session.title ?? session.sessionId),
    ],
    ChatBackend.codex => [
      for (final thread in await CodexClient(client.carrier).listThreads())
        if (!thread.running) ConferenceParticipant(key.host, thread.id, thread.title),
    ],
  };
}, retry: (_, _) => null);

class _CreateConference extends ConsumerStatefulWidget {
  const _CreateConference();

  @override
  ConsumerState<_CreateConference> createState() => _CreateConferenceState();
}

class _CreateConferenceState extends ConsumerState<_CreateConference> {
  final _title = TextEditingController();
  final _hosts = <ChatBackend, HostRef>{};
  final _sources = <ChatBackend, ConferenceParticipant>{};
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final deepseek = _sources[ChatBackend.deepseek];
    final codex = _sources[ChatBackend.codex];
    if (_saving || deepseek == null || codex == null) return;
    setState(() => _saving = true);
    final title = _title.text.trim();
    final id = uuidV4();
    try {
      await ref
          .read(petConferencesProvider.notifier)
          .create(
            PetConference(
              id: id,
              title: title.isEmpty ? context.l10n.conferenceTitle : title,
              deepseek: deepseek,
              codex: codex,
            ),
          );
      if (mounted) {
        unawaited(
          Navigator.of(context)
              .pushReplacement(MaterialPageRoute<void>(builder: (_) => _ConferenceRoom(id, prepareOnOpen: true))),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.conferenceHistoryError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final active = ref.watch(activeHostProvider);
    final ssh = ref.watch(hostsProvider.select((hosts) => hosts.ssh));
    final relay = ref.watch(relayAccountProvider).asData?.value;
    final remote = {
      if (!active.isLocal) active,
      for (final host in ssh) HostRef.ssh(host.id),
      if (relay?.signedIn == true)
        for (final host in relay!.hosts) HostRef.relay(host.id, name: host.name),
    };
    final hosts = {
      ChatBackend.deepseek: {if (!active.isLocal) active, HostRef.local, ...remote},
      ChatBackend.codex: remote,
    };
    final canCreate =
        !_saving && ChatBackend.values.every((backend) => hosts[backend]!.contains(_sources[backend]?.host));
    final scheme = Theme.of(context).colorScheme;
    return AppPage.list(
      title: l10n.conferenceCreate,
      subtitle: Text(l10n.conferenceSetupIntro),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                enabled: !_saving,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l10n.conferenceName,
                  prefixIcon: const Icon(Icons.edit_outlined),
                  counterText: '',
                  filled: true,
                  fillColor: scheme.surfaceContainerLow,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              for (final backend in ChatBackend.values) ...[
                _sourcePicker(backend, hosts[backend]!),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                onPressed: canCreate ? _create : null,
                icon: const Icon(Icons.forum_outlined, size: 21),
                label: Text(l10n.conferenceCreate),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourcePicker(ChatBackend backend, Set<HostRef> options) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _hosts[backend];
    final host = options.contains(selected) ? selected : options.firstOrNull;
    final key = host == null ? null : (host: host, backend: backend);
    final sources = key == null
        ? const AsyncData<List<ConferenceParticipant>?>(null)
        : ref.watch(_conferenceSources(key));
    final chosen = _sources[backend];
    final source = chosen?.host == host ? chosen : null;
    final hostNames = {
      for (final option in options)
        option: ref.watch(hostNameProvider(option)) ?? (option.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost),
    };
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 16, 6),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: backend == ChatBackend.deepseek ? scheme.tertiaryContainer : scheme.primaryContainer,
                  ),
                  child: _ConferenceAvatar(backend, side: 44),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(backend.label, style: theme.textTheme.titleMedium)),
                if (source != null) Icon(Icons.check_circle_outline, color: scheme.primary, size: 20),
              ],
            ),
          ),
          if (host != null)
            PopupMenuButton<HostRef>(
              enabled: !_saving && options.length > 1,
              tooltip: l10n.conferenceChooseHost,
              initialValue: host,
              onSelected: (value) => setState(() {
                if (value == host) return;
                _hosts[backend] = value;
                _sources.remove(backend);
              }),
              itemBuilder: (_) => [
                for (final option in options)
                  PopupMenuItem(
                    value: option,
                    child: Text(hostNames[option]!, overflow: TextOverflow.ellipsis),
                  ),
              ],
              child: ListTile(
                dense: true,
                leading: Icon(host.isLocal ? Icons.smartphone_outlined : Icons.computer_outlined),
                title: Text(hostNames[host]!, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: options.length > 1 ? const Icon(Icons.expand_more, size: 20) : null,
              ),
            ),
          Divider(height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant),
          sources.when(
            loading: () => ListTile(
              dense: true,
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(l10n.conferenceLoadingChats),
              trailing: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (_, _) => ListTile(
              leading: Icon(Icons.cloud_off_outlined, color: scheme.error),
              title: Text(l10n.conferenceLoadChatsError),
              trailing: IconButton(
                tooltip: l10n.commonRetry,
                onPressed: () => ref.invalidate(_conferenceSources(key!)),
                icon: const Icon(Icons.refresh),
              ),
            ),
            data: (items) {
              final hasChoices = items?.isNotEmpty == true;
              return ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  items == null
                      ? l10n.conferenceHostOffline
                      : items.isEmpty
                      ? l10n.conferenceNoChats
                      : l10n.conferenceChooseChat,
                  style: hasChoices ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall,
                ),
                subtitle: source == null ? null : Text(source.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: hasChoices ? const Icon(Icons.chevron_right, size: 20) : null,
                onTap: !_saving && hasChoices ? () => _pickSource(backend, items!) : null,
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickSource(ChatBackend backend, List<ConferenceParticipant> choices) async {
    final chosen = await Navigator.of(context).push(
      MaterialPageRoute<ConferenceParticipant>(
        builder: (_) => _SourcePage(backend: backend, choices: choices),
      ),
    );
    if (mounted && chosen != null) {
      setState(() {
        _hosts[backend] = chosen.host;
        _sources[backend] = chosen;
      });
    }
  }
}

class _SourcePage extends StatefulWidget {
  const _SourcePage({required this.backend, required this.choices});

  final ChatBackend backend;
  final List<ConferenceParticipant> choices;

  @override
  State<_SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<_SourcePage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final choices = widget.choices.where((item) => item.title.toLowerCase().contains(_query)).toList();
    return AppPage(
      title: '${widget.backend.label} · ${context.l10n.conferenceChooseChat}',
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          sliver: SliverToBoxAdapter(
            child: TextField(
              onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: context.l10n.conferenceSearch,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverList.builder(
            itemCount: choices.length,
            itemBuilder: (context, index) => ListTile(
              leading: const Icon(Icons.chat_bubble_outline, size: 20),
              title: Text(choices[index].title, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).pop(choices[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConferenceRoom extends ConsumerStatefulWidget {
  const _ConferenceRoom(this.id, {this.prepareOnOpen = false});

  final String id;
  final bool prepareOnOpen;

  @override
  ConsumerState<_ConferenceRoom> createState() => _ConferenceRoomState();
}

class _ConferenceRoomState extends ConsumerState<_ConferenceRoom> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _unsavedBranches = <ChatBackend, String>{};
  final _failures = <ChatBackend, Object>{};
  bool _busy = false;

  PetConference? get _room => ref.read(petConferencesProvider).value?.where((room) => room.id == widget.id).firstOrNull;
  PetConferences get _store => ref.read(petConferencesProvider.notifier);

  DshClient? _client(ConferenceParticipant participant) =>
      ref.read(connectionForHostProvider(participant.host)).asData?.value?.client;

  @override
  void initState() {
    super.initState();
    if (widget.prepareOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final room = mounted ? _room : null;
        if (room != null) unawaited(_prepare(room));
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _start() => setState(() {
    _busy = true;
    _failures.clear();
  });

  void _error(ChatBackend backend, Object error) {
    if (mounted) setState(() => _failures[backend] = error);
  }

  void _done() {
    if (mounted) setState(() => _busy = false);
  }

  void _historyError() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.conferenceHistoryError)));
    }
  }

  Future<void> _prepare(PetConference room) async {
    if (_busy || room.ready || room.deleting) return;
    _start();
    try {
      final pending = ChatBackend.values.where((backend) => room.participant(backend).branch == null);
      final branches = <ChatBackend, ConferenceBranch>{};
      for (final backend in pending) {
        try {
          final client = _client(room.participant(backend));
          if (client == null) throw const _ConferenceOffline();
          branches[backend] = ConferenceBranch(backend, client);
        } catch (error) {
          _error(backend, error);
          return;
        }
      }
      for (final entry in branches.entries) {
        final backend = entry.key;
        try {
          final participant = room.participant(backend);
          if (!mounted || !identical(_client(participant), entry.value.client)) throw const _ConferenceOffline();
          final id = _unsavedBranches[backend] ??= await entry.value.fork(participant.source);
          if (!mounted) return;
          await _store.saveBranch(room.id, backend, id);
          _unsavedBranches.remove(backend);
        } catch (error) {
          _error(backend, error);
          return;
        }
      }
    } finally {
      _done();
    }
  }

  Future<void> _send(PetConference room) async {
    final message = _input.text.trim();
    if (_busy || !room.ready || room.deleting || message.isEmpty) return;
    final clients = {for (final backend in ChatBackend.values) backend: _client(room.participant(backend))};
    if (clients.values.any((client) => client == null)) return;
    _start();
    try {
      final store = _store;
      await store.append(room.id, ConferenceMessage(null, message));
      if (!mounted) return;
      _input.clear();
      _scrollToLatest();
      await runConferenceRound(
        message: message,
        current: () => mounted,
        firstPeer: room.messages.where((message) => message.author == null).length.isEven
            ? ChatBackend.deepseek
            : ChatBackend.codex,
        reply: (backend, prompt) async {
          final participant = room.participant(backend);
          final client = clients[backend]!;
          bool current() => mounted && identical(_client(participant), client);
          if (!current()) throw const _ConferenceOffline();
          final answer = await ConferenceBranch(backend, client).reply(participant.branch!, prompt, current);
          if (!current()) throw const _ConferenceOffline();
          return answer;
        },
        publish: (message) async {
          await store.append(room.id, message);
          _scrollToLatest();
        },
        reportError: _error,
      );
    } catch (_) {
      _historyError();
    } finally {
      _done();
    }
  }

  void _scrollToLatest() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        unawaited(
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> _delete(PetConference room) async {
    if (_busy) return;
    final l10n = context.l10n;
    if (!room.deleting) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.conferenceDelete),
          content: Text(l10n.conferenceDeleteConfirm),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.conferenceCancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.conferenceDelete)),
          ],
        ),
      );
      if (!mounted || !identical(room, _room) || confirmed != true) return;
    }
    _start();
    try {
      final store = _store;
      // Save any fork the Host returned before a previous local write failed.
      for (final entry in _unsavedBranches.entries.toList()) {
        await store.saveBranch(room.id, entry.key, entry.value);
        _unsavedBranches.remove(entry.key);
      }
      if (!mounted) return;
      final registered = _room!;
      await store.beginDeletion(room.id);
      for (final backend in ChatBackend.values) {
        if (!mounted) return;
        final participant = registered.participant(backend);
        if (participant.branch == null || registered.deleted.contains(backend)) continue;
        try {
          final client = _client(participant);
          if (client == null) throw const _ConferenceOffline();
          await ConferenceBranch(backend, client).archive(participant);
          await store.markDeleted(room.id, backend);
        } catch (error) {
          _error(backend, error);
        }
      }
      await store.finishDeletion(room.id);
      if (mounted && _room == null) {
        _done();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    } catch (_) {
      _historyError();
    } finally {
      _done();
    }
  }

  void _openBranch(PetConference room, ChatBackend backend) {
    final participant = room.participant(backend);
    final branch = participant.branch;
    if (branch == null || room.deleting || _busy) return;
    ref.read(backendProvider.notifier).set(backend);
    ref.read(activeHostProvider.notifier).select(participant.host);
    ref.read(currentSessionProvider.notifier).select(backend == ChatBackend.codex ? codexSessionId(branch) : branch);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final room = ref.watch(petConferencesProvider).value?.where((room) => room.id == widget.id).firstOrNull;
    if (room == null) return Scaffold(appBar: AppBar(title: Text(l10n.conferenceTitle)));
    final connected = {
      for (final backend in ChatBackend.values)
        backend: ref.watch(connectionForHostProvider(room.participant(backend).host)).asData?.value != null,
    };
    final canSend = room.ready && !room.deleting && !_busy && connected.values.every((value) => value);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(room.title),
          actions: [
            if (!_busy)
              IconButton(
                tooltip: l10n.conferenceDelete,
                icon: const Icon(Icons.archive_outlined),
                onPressed: () => _delete(room),
              ),
          ],
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppPage.contentWidth),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        for (final backend in ChatBackend.values)
                          Expanded(
                            child: TextButton.icon(
                              onPressed: room.participant(backend).branch == null || room.deleting || _busy
                                  ? null
                                  : () => _openBranch(room, backend),
                              icon: _ConferenceAvatar(backend, side: 32),
                              label: Text(backend.label),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_busy) const LinearProgressIndicator(),
                  Expanded(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: room.messages.isEmpty ? 1 : room.messages.length,
                      itemBuilder: (context, index) => room.messages.isEmpty
                          ? Text(l10n.conferenceIntro, textAlign: TextAlign.center)
                          : _ConferenceBubble(room.messages[index]),
                    ),
                  ),
                  if (room.deleting || !room.ready)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => room.deleting ? _delete(room) : _prepare(room),
                        child: Text(room.deleting ? l10n.conferenceRetryDelete : l10n.conferencePrepare),
                      ),
                    ),
                  for (final entry in _failures.entries)
                    _status(switch (entry.value) {
                      _ConferenceOffline() => l10n.conferenceConnectHost(entry.key.label),
                      ConferenceAwaitingBranch() => l10n.conferenceBranchAction(entry.key.label),
                      _ =>
                        room.deleting
                            ? l10n.conferenceDeleteError(entry.key.label)
                            : l10n.conferenceReplyError(entry.key.label),
                    }),
                  if (_failures.isEmpty && room.ready && !room.deleting)
                    for (final entry in connected.entries)
                      if (!entry.value) _status(l10n.conferenceConnectHost(entry.key.label)),
                  if (room.ready && !room.deleting)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _input,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: 8000,
                              decoration: InputDecoration(hintText: l10n.conferenceInput, counterText: ''),
                            ),
                          ),
                          IconButton.filled(
                            onPressed: canSend ? () => _send(room) : null,
                            tooltip: l10n.conferenceSend,
                            icon: const Icon(Icons.arrow_upward),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(String message) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
    child: Text(message, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _ConferenceOffline implements Exception {
  const _ConferenceOffline();
}

class _ConferenceAvatar extends ConsumerWidget {
  const _ConferenceAvatar(this.backend, {this.side = 44});

  final ChatBackend backend;
  final double side;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packId = ref.watch(petPackIdProvider(backend));
    final pack = ref.watch(petPackProvider(packId)).value;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: side,
      child: pack == null
          ? CircleAvatar(
              backgroundColor: scheme.surfaceContainerHighest,
              foregroundColor: scheme.onSurfaceVariant,
              child: Text(backend.label.substring(0, 1)),
            )
          : PetPreview(pack: pack, side: side),
    );
  }
}

class _ConferenceBubble extends StatelessWidget {
  const _ConferenceBubble(this.message);

  final ConferenceMessage message;

  @override
  Widget build(BuildContext context) {
    final author = message.author;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: author == null ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (author != null) ...[_ConferenceAvatar(author), const SizedBox(width: 8)],
          Flexible(
            child: Column(
              crossAxisAlignment: author == null ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (author != null)
                  Text(author.label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: switch (author) {
                      null => scheme.primaryContainer,
                      ChatBackend.deepseek => scheme.surfaceContainerHigh,
                      ChatBackend.codex => scheme.secondaryContainer,
                    },
                  ),
                  child: SelectableText(message.text),
                ),
              ],
            ),
          ),
          if (author == null) const SizedBox(width: 12),
        ],
      ),
    );
  }
}
