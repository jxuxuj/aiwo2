part of 'chat_state.dart';

final _codexThreadModelsProvider = Provider((ref) => <(HostRef, String), ModelSelection>{});

typedef _CodexConnection = ({HostRef host, DshClient client, MuxGeneration? generation});

/// Supplies native chat state from the connected Host's Codex thread.
mixin _CodexChat on Notifier<ChatState> {
  String get sessionId;

  bool get _isCodex => codexThreadId(sessionId) != null;
  String get _threadId => codexThreadId(sessionId)!;
  var _codexTranscript = ChatTranscript();
  final _codexLog = <int, SessionLogEvent>{};
  final _uploadedFiles = <int, WorkspaceUploadedFile>{};
  HostRef? _codexHost;
  _CodexConnection? _codexConnection;
  Object? _codexOwner;
  SessionHeader? _codexHeader;
  bool _codexHasMore = false;
  int _codexCursor = -1;
  String? _activeCodexTurn;
  Future<bool>? _codexRefresh;
  ({String text, int imageCount, int afterSeq, DateTime expires})? _codexEcho;
  bool _codexSending = false;

  ChatState _buildCodex() {
    final host = ref.watch(activeHostProvider);
    final client = ref.watch(activeConnectionProvider.select((value) => value.asData?.value?.client));
    if (_codexHost != host) {
      _codexHost = host;
      _codexTranscript = ChatTranscript();
      _codexLog.clear();
      _uploadedFiles.clear();
      _codexHeader = null;
      _codexCursor = -1;
      _codexHasMore = false;
      _activeCodexTurn = null;
      _codexEcho = null;
    }
    final owner = _codexOwner = Object();
    _codexConnection = client == null ? null : (host: host, client: client, generation: client.mux.generation);
    _codexRefresh = null;
    _codexSending = false;
    if (client != null) {
      Timer? poll;
      void startPolling() {
        unawaited(
          Future<void>.microtask(() async {
            if (identical(_codexOwner, owner)) await _refreshCodex();
          }),
        );
        poll = Timer.periodic(const Duration(seconds: 3), (_) {
          if (identical(_codexOwner, owner) && ref.read(appForegroundProvider)) unawaited(_refreshCodex());
        });
      }

      startPolling();
      ref.onCancel(() => poll?.cancel());
      ref.onResume(startPolling);
      final connectionStates = client.mux.states.listen((connectionState) {
        if (!identical(_codexOwner, owner)) return;
        _codexConnection = (host: host, client: client, generation: client.mux.generation);
        if (connectionState == DshConnectionState.connected) unawaited(_refreshCodex());
      });
      ref.onDispose(() {
        _codexOwner = null;
        _codexConnection = null;
        poll?.cancel();
        unawaited(connectionStates.cancel());
      });
    }
    ref.listen(codexSessionListProvider, (_, next) {
      final title = next.value?.where((session) => session.sessionId == sessionId).firstOrNull?.title;
      if (title != null && title != state.title) _publishCodex(title: title);
    });
    final title = ref
        .read(codexSessionListProvider)
        .value
        ?.where((session) => session.sessionId == sessionId)
        .firstOrNull
        ?.title;
    return ChatState(
      items: _codexTranscript.items,
      turns: _codexTranscript.turns,
      title: title,
      model: ref.read(_codexThreadModelsProvider)[(host, sessionId)],
      running: _activeCodexTurn != null,
      hasMoreHistory: _codexHasMore,
      loading: client != null && _codexHeader == null,
    );
  }

  bool _ownsCodex(Object? owner, _CodexConnection connection) =>
      ref.mounted &&
      identical(_codexOwner, owner) &&
      _codexConnection == connection &&
      ref.read(activeHostProvider) == connection.host &&
      identical(ref.read(activeConnectionProvider).asData?.value?.client, connection.client) &&
      identical(connection.client.mux.generation, connection.generation);

  Future<bool> _refreshCodex() async {
    if (_codexRefresh case final existing?) return existing;
    final owner = _codexOwner;
    final connection = _codexConnection;
    if (connection == null || !_ownsCodex(owner, connection)) return false;
    final refresh = _readCodex(owner, connection);
    _codexRefresh = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_codexRefresh, refresh)) _codexRefresh = null;
    }
  }

  Future<bool> _readCodex(Object? owner, _CodexConnection connection) async {
    try {
      final page = await CodexClient(connection.client.carrier).readHistory(_threadId);
      if (!_ownsCodex(owner, connection)) return false;
      final oldest = _codexTranscript.oldestSeq;
      final hadOlder = oldest != null && page.oldestSeq != null && oldest < page.oldestSeq!;
      final nextCursor = page.cursor ?? page.records.lastOrNull?.seq ?? -1;
      final pageStart = page.oldestSeq ?? nextCursor + 1;
      var changed = _codexHeader == null || nextCursor != _codexCursor;
      final obsolete = _codexLog.keys.where((seq) => seq > nextCursor || (!page.hasMore && seq < pageStart)).toList();
      for (final seq in obsolete) {
        _codexLog.remove(seq);
        changed = true;
      }
      changed = _mergeCodexRecords(page.records) || changed;
      _codexHeader = page.header ?? _codexHeader;
      _codexCursor = nextCursor;
      if (!hadOlder || !page.hasMore) _codexHasMore = page.hasMore;
      if (changed) _applyCodexTranscript();
      _activeCodexTurn = page.activeTurnId;
      var pending = state.pending;
      if (_codexEcho case final echo?) {
        final echoed = page.records.whereType<UserMessageEvent>().any(
          (event) =>
              event.seq > echo.afterSeq &&
              event.message.text == echo.text &&
              event.message.parts.whereType<ImagePart>().length == echo.imageCount,
        );
        if (echoed || DateTime.now().isAfter(echo.expires)) {
          _codexEcho = null;
          pending = const [];
          if (echoed) ref.invalidate(codexWorkspaceProvider);
        }
      }
      final model =
          ref.read(_codexThreadModelsProvider)[(connection.host, sessionId)] ??
          (page.model == null ? null : ModelSelection(provider: 'codex', model: page.model!));
      final running = _activeCodexTurn != null || _codexEcho != null;
      final stopping = state.stopping && _activeCodexTurn != null;
      if (changed ||
          state.loading ||
          state.syncError != null ||
          state.running != running ||
          state.stopping != stopping ||
          state.hasMoreHistory != _codexHasMore ||
          (model != null && state.model != model) ||
          !identical(state.pending, pending)) {
        _publishCodex(model: model, pending: pending, clearSyncError: true, stopping: stopping);
      }
      return true;
    } catch (error) {
      if (_ownsCodex(owner, connection)) {
        if (_codexEcho case final echo? when DateTime.now().isAfter(echo.expires)) {
          _codexEcho = null;
          _publishCodex(pending: const []);
        }
        state = state.copyWith(loading: false, syncError: chatErrorText(error, action: appL10n.stateChatHistoryFailed));
      }
      return false;
    }
  }

  bool _mergeCodexRecords(Iterable<SessionLogEvent> records) {
    var changed = false;
    for (final event in records) {
      final existing = _codexLog[event.seq];
      if (existing?.type == event.type && jsonEncode(existing!.data) == jsonEncode(event.data)) continue;
      _codexLog[event.seq] = event;
      changed = true;
    }
    return changed;
  }

  void _applyCodexTranscript() {
    final header = _codexHeader;
    if (header == null) return;
    final ordered = _codexLog.values.toList()..sort((left, right) => left.seq.compareTo(right.seq));
    _codexTranscript.apply(
      SessionSnapshotEvent(
        sessionId: sessionId,
        header: header,
        cursor: _codexCursor,
        events: ordered,
        hasMore: _codexHasMore,
        projections: SessionProjections.empty,
        assistantRevision: null,
      ),
    );
  }

  void _publishCodex({
    String? title,
    ModelSelection? model,
    List<PendingPrompt>? pending,
    bool? stopping,
    bool? loadingOlder,
    bool clearSyncError = false,
  }) {
    state = ChatState(
      items: _codexTranscript.items,
      turns: _codexTranscript.turns,
      title: title ?? state.title,
      model: model ?? state.model,
      running: _activeCodexTurn != null || _codexEcho != null,
      stopping: stopping ?? state.stopping,
      pending: pending ?? state.pending,
      loading: _codexHeader == null && !clearSyncError && state.loading,
      loadingOlder: loadingOlder ?? state.loadingOlder,
      hasMoreHistory: _codexHasMore,
      error: state.error,
      syncError: clearSyncError ? null : state.syncError,
    );
  }

  Future<void> _loadOlderCodex() async {
    final owner = _codexOwner;
    final connection = _codexConnection;
    final oldest = _codexTranscript.oldestSeq;
    if (connection == null || oldest == null || !_codexHasMore || state.loadingOlder) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final page = await CodexClient(connection.client.carrier).readHistory(_threadId, beforeSeq: oldest);
      if (!_ownsCodex(owner, connection)) return;
      _codexHasMore = page.hasMore;
      _mergeCodexRecords(page.records);
      _applyCodexTranscript();
      _publishCodex(loadingOlder: false);
    } catch (error) {
      if (_ownsCodex(owner, connection)) {
        state = state.copyWith(
          loadingOlder: false,
          error: chatErrorText(error, action: appL10n.stateChatHistoryFailed),
        );
      }
    }
  }

  bool _selectCodexModel(ModelSelection selection) {
    final connection = _codexConnection;
    if (connection == null || selection.provider != 'codex') return false;
    ref.read(_codexThreadModelsProvider)[(connection.host, sessionId)] = selection;
    state = state.copyWith(model: selection, clearError: true);
    return true;
  }

  Future<bool> _sendCodex(
    String text,
    List<DraftAttachment> attachments,
    SendMode mode,
    bool verbatim,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  ) async {
    final owner = _codexOwner;
    final connection = _codexConnection;
    if (connection == null || _codexSending || _codexEcho != null || (text.trim().isEmpty && attachments.isEmpty)) {
      return false;
    }
    final turnId = _activeCodexTurn;
    if (turnId != null && (mode == SendMode.queue || mode == SendMode.interrupt)) {
      state = state.copyWith(error: appL10n.stateChatAgentBusy);
      return false;
    }
    final requestId = _requestId();
    final body = verbatim ? text : text.trim();
    final model = state.model?.model;
    final images = [
      for (final attachment in attachments)
        if (attachment.isImage) (bytes: attachment.bytes, mediaType: attachment.mediaType!),
    ];
    final files = [
      for (final attachment in attachments)
        if (!attachment.isImage) attachment,
    ];
    bool current() => _ownsCodex(owner, connection) && deliveryAllowed?.call() != false;
    _codexSending = true;
    state = state.copyWith(
      pending: [PendingPrompt(requestId: requestId, text: body, time: DateTime.now(), attachments: attachments)],
      clearError: true,
    );
    var accepted = false;
    try {
      if (beforeDeliver != null && !await beforeDeliver(requestId)) return false;
      if (!current()) return false;
      final paths = <String>[];
      for (final file in files) {
        final uploaded = await _uploadCodexFile(connection, file);
        if (!current()) return false;
        _uploadedFiles[file.id] = uploaded;
        paths.add('- ${jsonEncode(uploaded.path)}');
      }
      final content = paths.isEmpty
          ? body
          : [if (body.isNotEmpty) body, '${appL10n.stateWorkspaceFilesHint}\n${paths.join('\n')}'].join('\n\n');
      final codex = CodexClient(connection.client.carrier);
      if (_activeCodexTurn == null && _codexCursor >= 0) {
        await codex.resumeThread(_threadId);
        if (!current()) return false;
      }
      final afterSeq = _codexCursor;
      final expected = _activeCodexTurn;
      final newTurn = await codex.sendPrompt(
        _threadId,
        content,
        model: model,
        images: images,
        expectedTurnId: expected,
      );
      accepted = true;
      if (_ownsCodex(owner, connection)) {
        for (final file in files) {
          _uploadedFiles.remove(file.id);
        }
        _activeCodexTurn = newTurn ?? expected;
        _codexEcho = (
          text: content,
          imageCount: images.length,
          afterSeq: afterSeq,
          expires: DateTime.now().add(const Duration(seconds: 15)),
        );
        _publishCodex();
        unawaited(_refreshCodex());
      }
      return true;
    } catch (error) {
      if (_ownsCodex(owner, connection)) {
        state = state.copyWith(error: ChatController._sendFailure(error));
      }
      return false;
    } finally {
      if (identical(_codexOwner, owner)) {
        _codexSending = false;
        if (!accepted) state = state.copyWith(pending: const []);
      }
    }
  }

  Future<WorkspaceUploadedFile> _uploadCodexFile(_CodexConnection connection, DraftAttachment attachment) async {
    try {
      return _uploadedFiles[attachment.id] ??
          await connection.client.uploadWorkspaceFile(sessionId, attachment.bytes, name: attachment.name);
    } catch (error) {
      throw _UploadFailed(error);
    }
  }

  Future<void> _stopCodex() async {
    final owner = _codexOwner;
    final connection = _codexConnection;
    final turn = _activeCodexTurn;
    if (connection == null || turn == null || state.stopping) return;
    state = state.copyWith(stopping: true);
    try {
      await CodexClient(connection.client.carrier).interrupt(_threadId, turn);
      await _refreshCodex();
    } catch (error) {
      if (_ownsCodex(owner, connection)) {
        state = state.copyWith(error: chatErrorText(error, action: appL10n.stateChatStopFailed));
      }
    } finally {
      if (_ownsCodex(owner, connection)) state = state.copyWith(stopping: false);
    }
  }
}
