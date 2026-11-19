import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteRpcException;
import 'package:image/image.dart' as image;

typedef _PromptImage = ({Uint8List bytes, String mediaType});

// The secure Remote frame is 4 MiB. Keep the prompt under 3 MiB after base64
// and leave room within that for the RPC envelope and attachment framing.
const _inlinePromptBudget = 3 * 1024 * 1024;
const _promptEnvelopeReserve = 16 * 1024;

// Only levels accepted by the Remote Host's turn/start method can be selected.
const _remoteReasoningEfforts = {'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'};

String? codexApprovalReviewer(Object? value) => switch (value) {
  'user' => 'user',
  'auto_review' || 'guardian_subagent' => 'auto_review',
  _ => null,
};

int _base64Size(int bytes) => ((bytes + 2) ~/ 3) * 4;

Future<List<_PromptImage>> _fitInlineImages(List<_PromptImage> images, String text) async {
  if (images.isEmpty) return images;
  final budget = _inlinePromptBudget - _promptEnvelopeReserve - utf8.encode(jsonEncode(text)).length;
  final size = images.fold(0, (total, entry) => total + _base64Size(entry.bytes.length));
  if (size <= budget) return images;
  return Isolate.run(() => _resizeInlineImages(images, budget));
}

List<_PromptImage> _resizeInlineImages(List<_PromptImage> images, int budget) {
  // Allot the remaining bytes to smaller originals first. Write each result
  // back to its original position so the message keeps the picker order.
  final order = images.asMap().entries.toList()..sort((a, b) => a.value.bytes.length.compareTo(b.value.bytes.length));
  final resized = List<_PromptImage>.of(images);
  var remaining = budget;
  for (var index = 0; index < order.length; index++) {
    final entry = order[index];
    final share = remaining ~/ (order.length - index);
    final fitted = _base64Size(entry.value.bytes.length) <= share
        ? entry.value
        : _resizeInlineImage(entry.value.bytes, (share ~/ 4) * 3);
    resized[entry.key] = fitted;
    remaining -= _base64Size(fitted.bytes.length);
  }
  return resized;
}

_PromptImage _resizeInlineImage(Uint8List bytes, int budget) {
  const tooLarge = DshRemoteException('FRAME_TOO_LARGE', 'The images exceed the inline Codex prompt size.');
  if (budget <= 0) throw tooLarge;
  final decoded = image.decodeImage(bytes, frame: 0);
  if (decoded == null) throw tooLarge;
  final pixels = decoded.exif.imageIfd.hasOrientation && decoded.exif.imageIfd.orientation != 1
      ? image.bakeOrientation(decoded)
      : decoded;
  final originalEdge = math.max(pixels.width, pixels.height);
  for (var edge = math.min(originalEdge, 2048); edge > 0; edge = edge * 2 ~/ 3) {
    final scaled = edge == originalEdge
        ? pixels
        : image.copyResize(
            pixels,
            width: math.max(1, pixels.width * edge ~/ originalEdge),
            height: math.max(1, pixels.height * edge ~/ originalEdge),
            interpolation: image.Interpolation.linear,
          );
    if (pixels.hasAlpha) {
      final png = image.encodePng(scaled);
      if (png.length <= budget) return (bytes: png, mediaType: 'image/png');
      continue;
    }
    for (final quality in const [85, 70, 55]) {
      final jpeg = image.encodeJpg(scaled, quality: quality);
      if (jpeg.length <= budget) return (bytes: jpeg, mediaType: 'image/jpeg');
    }
  }
  throw tooLarge;
}

String? _nonEmptyString(Object? value) => value is String && value.isNotEmpty ? value : null;

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
  return null;
}

/// One Codex thread as the Host's `thread/list` reports it.
///
/// The Host sanitises the App Server response to exactly these fields, so a
/// missing field means the Host did not have it 鈥?never guess a default that
/// looks like real content.
class CodexThread {
  const CodexThread({
    required this.id,
    this.name,
    this.preview,
    this.cwd,
    this.updatedAt,
    this.projectId,
    this.running = false,
    this.isPinned = false,
  });

  final String id;
  final String? name;
  final String? preview;
  final String? cwd;
  final int? updatedAt;
  final String? projectId;
  final bool running;
  final bool isPinned;

  /// A title worth showing: the user's name, else the first line of the
  /// preview, else the id so an entry is never blank.
  String get title {
    final named = name?.trim();
    if (named != null && named.isNotEmpty) return named;
    final previewed = preview?.trim();
    if (previewed != null && previewed.isNotEmpty) return previewed.split('\n').first;
    return id;
  }

  static List<CodexThread> parseList(Object? result) {
    if (result is! Map) return const <CodexThread>[];
    final data = result['data'];
    if (data is! List) return const <CodexThread>[];
    final threads = <CodexThread>[];
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      final status = item['status'];
      threads.add(
        CodexThread(
          id: id,
          name: _nonEmptyString(item['name']),
          preview: _nonEmptyString(item['preview']),
          cwd: _nonEmptyString(item['cwd']),
          updatedAt: _integer(item['updatedAt']),
          projectId: _nonEmptyString(item['projectId']),
          running: status is Map && status['type'] == 'active',
          isPinned: item['isPinned'] == true,
        ),
      );
    }
    return threads;
  }
}

/// One Codex project (the Host's "workspace") and the directories it covers.
class CodexProject {
  const CodexProject({required this.id, required this.name, this.root});

  final String id;
  final String name;
  final String? root;

  static List<CodexProject> parseList(Object? result) {
    if (result is! Map) return const <CodexProject>[];
    final data = result['data'];
    if (data is! List) return const <CodexProject>[];
    final projects = <CodexProject>[];
    for (final item in data) {
      if (item is! Map) continue;
      final id = item['id'];
      final name = item['name'];
      if (id is! String || name is! String) continue;
      String? root;
      final roots = item['roots'];
      if (roots is List) {
        for (final entry in roots) {
          if (entry is Map && entry['path'] is String) {
            root = entry['path'] as String;
            break;
          }
        }
      }
      projects.add(CodexProject(id: id, name: name, root: root));
    }
    return projects;
  }
}

/// A model and the selectable reasoning levels reported by the Host.
class CodexModel {
  const CodexModel({
    required this.id,
    required this.name,
    required this.efforts,
    this.description,
    this.defaultEffort,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String? description;
  final List<ReasoningEffort> efforts;
  final String? defaultEffort;
  final bool isDefault;
}

/// The effective settings returned by `thread/start` or `thread/resume`.
class CodexThreadSettings {
  const CodexThreadSettings({
    required this.threadId,
    this.model,
    this.reasoningEffort,
    this.permissionPreset,
    this.approvalsReviewer,
  });

  final String threadId;
  final String? model;
  final String? reasoningEffort;
  final String? permissionPreset;
  final String? approvalsReviewer;

  static CodexThreadSettings? _parse(Object? result, {String? expectedThreadId}) {
    if (result is! Map) return null;
    final thread = result['thread'];
    final reportedId = (thread is Map ? _nonEmptyString(thread['id']) : null) ?? _nonEmptyString(result['id']);
    final threadId = reportedId ?? expectedThreadId;
    if (threadId == null) return null;
    if (expectedThreadId != null && threadId != expectedThreadId) {
      throw const DshProtocolException('thread/resume: unexpected thread id');
    }
    final rawSettings = result['threadSettings'];
    final settings = rawSettings is Map ? rawSettings : const {};
    return CodexThreadSettings(
      threadId: threadId,
      model: _nonEmptyString(result['model']) ?? _nonEmptyString(settings['model']),
      reasoningEffort: _nonEmptyString(result['reasoningEffort']) ?? _nonEmptyString(settings['effort']),
      permissionPreset: _confirmedPermissionPreset(result) ?? _confirmedPermissionPreset(settings),
      approvalsReviewer: codexApprovalReviewer(result['approvalsReviewer'] ?? settings['approvalsReviewer']),
    );
  }

  // Mirrors Host confirmation: each of the sandbox and approval settings can
  // also be used in combinations which the Remote permission picker cannot set.
  static String? _confirmedPermissionPreset(Map settings) {
    final sandbox = settings['sandbox'] ?? settings['sandboxPolicy'];
    final sandboxType = sandbox is Map ? sandbox['type'] : sandbox;
    return switch ((settings['approvalPolicy'], sandboxType)) {
      ('on-request', 'workspace-write' || 'workspaceWrite') => 'workspace-write',
      ('never', 'danger-full-access' || 'dangerFullAccess') => 'danger-full-access',
      _ => null,
    };
  }
}

/// Minimal Codex client over an already-authenticated Remote carrier.
///
/// Calls go out as `codex.app.call` with `{method, params}`; the Host runs
/// them against its own `codex app-server` and answers on the same encrypted
/// session. Only the methods in the Host's fixed allow-list are accepted.
class CodexClient {
  CodexClient(this.carrier);

  final DshCarrier carrier;

  Future<CodexUsage> readUsage() async => CodexUsage.parse(await _call('account/rateLimits/read', const {}));

  Future<void> watchApprovals(String threadId) async {
    try {
      await _call('dsh/approvals/watch', {'threadId': threadId});
    } on DshRemoteException catch (error) {
      if (error.code != 'METHOD_NOT_ALLOWED') rethrow;
    }
  }

  Future<void> respondApproval(String requestHandle, ApprovalDecision decision) async {
    final value = switch (decision) {
      ApprovalDecision.allowOnce => 'accept',
      ApprovalDecision.reject => 'decline',
      ApprovalDecision.pass => 'cancel',
    };
    try {
      await carrier.rawCall('codex.app.respond', {'requestHandle': requestHandle, 'decision': value});
    } on RemoteRpcException catch (error) {
      throw DshRemoteException(error.code, 'Codex Remote could not respond to the approval.');
    }
  }

  Future<CodexThreadSettings> setApprovalsReviewer(String threadId, String reviewer) async {
    final result = await _call('dsh/approvalReviewer/set', {'threadId': threadId, 'approvalsReviewer': reviewer});
    final settings = CodexThreadSettings._parse(result, expectedThreadId: threadId);
    if (settings == null) throw const DshProtocolException('dsh/approvalReviewer/set: invalid settings response');
    return settings;
  }

  Future<Object?> _call(String method, Map<String, Object?> params, {bool allowLargeResponse = false}) async {
    final envelope = <String, Object?>{'method': method, 'params': params};
    try {
      try {
        return await carrier.rawCall('codex.app.call', envelope);
      } on RemoteRpcException catch (error) {
        // Only retry a read that exceeded the secure response frame.
        if (!allowLargeResponse || error.code != 'RESPONSE_TOO_LARGE') rethrow;
        return await carrier.rawCallChunked('codex.app.call', envelope, forceChunked: true);
      }
    } on RemoteRpcException catch (error) {
      throw DshRemoteException(error.code, 'Codex Remote could not complete $method.', {
        'remote': true,
        if (error.retryable) 'retryable': true,
      });
    }
  }

  /// The models the Host's Codex offers.
  Future<List<CodexModel>> listModels({int limit = 50}) =>
      _listAll('model/list', {'limit': limit, 'includeHidden': false}, _parseModels, (model) => model.id);

  static List<CodexModel> _parseModels(Object? result) {
    if (result is! Map) return const [];
    final data = result['data'];
    if (data is! List) return const [];
    final models = <CodexModel>[];
    for (final item in data) {
      if (item is! Map || item['hidden'] == true) continue;
      final id = _nonEmptyString(item['model']) ?? _nonEmptyString(item['id']);
      if (id == null) continue;
      final name = _nonEmptyString(item['displayName']) ?? _nonEmptyString(item['name']) ?? id;
      final rawEfforts = item['supportedReasoningEfforts'];
      final efforts = <String, ReasoningEffort>{};
      if (rawEfforts is List) {
        for (final entry in rawEfforts.whereType<Map>()) {
          final level = _nonEmptyString(entry['reasoningEffort']);
          if (level == null || !_remoteReasoningEfforts.contains(level)) continue;
          efforts.putIfAbsent(level, () => ReasoningEffort(level, level, _nonEmptyString(entry['description'])));
        }
      }
      final defaultEffort = _nonEmptyString(item['defaultReasoningEffort']);
      models.add(
        CodexModel(
          id: id,
          name: name,
          description: _nonEmptyString(item['description']),
          efforts: efforts.values.toList(growable: false),
          defaultEffort: efforts.containsKey(defaultEffort) ? defaultEffort : null,
          isDefault: item['isDefault'] == true,
        ),
      );
    }
    return models;
  }

  /// Codex projects (the Host's workspaces).
  Future<List<CodexProject>> listProjects({int limit = 100}) =>
      _listAll('project/list', {'limit': limit}, CodexProject.parseList, (project) => project.id);

  /// Codex threads, newest first by default.
  Future<List<CodexThread>> listThreads({int limit = 50, bool archived = false, String? searchTerm}) {
    final params = <String, Object?>{
      'limit': limit,
      'sortKey': 'recency_at',
      'sortDirection': 'desc',
      'archived': archived,
      if (searchTerm != null && searchTerm.trim().isNotEmpty) 'searchTerm': searchTerm.trim(),
    };
    return _listAll('thread/list', params, CodexThread.parseList, (thread) => thread.id);
  }

  Future<List<T>> _listAll<T>(
    String method,
    Map<String, Object?> params,
    List<T> Function(Object?) parse,
    String Function(T) idOf,
  ) async {
    final cursors = <String>{};
    final items = <String, T>{};
    String? cursor;
    do {
      final result = await _call(method, {...params, 'cursor': ?cursor}, allowLargeResponse: true);
      for (final item in parse(result)) {
        items.putIfAbsent(idOf(item), () => item);
      }
      cursor = result is Map ? _nonEmptyString(result['nextCursor']) : null;
      if (cursor != null && !cursors.add(cursor)) {
        throw DshProtocolException('$method returned a repeated pagination cursor');
      }
    } while (cursor != null);
    return items.values.toList(growable: false);
  }

  /// One page of a thread's history, oldest first. [beforeSeq] is exclusive.
  Future<CodexHistory> readHistory(
    String threadId, {
    int maxMessages = 60,
    int? beforeSeq,
    int? throughSeq,
    String? sessionId,
  }) async {
    final result = await _call('dsh/sessionHistory', {
      'threadId': threadId,
      'maxMessages': maxMessages,
      'beforeSeq': ?beforeSeq,
      'throughSeq': ?throughSeq,
    }, allowLargeResponse: true);
    return CodexHistory.parse(result, sessionId: sessionId);
  }

  /// Starts a turn with text and inline images, or steers [expectedTurnId].
  Future<String?> sendPrompt(
    String threadId,
    String text, {
    String? model,
    String? reasoningEffort,
    List<({Uint8List bytes, String mediaType})> images = const [],
    String? expectedTurnId,
  }) async {
    final steerTurnId = _nonEmptyString(expectedTurnId);
    final decisionModel = _nonEmptyString(model);
    final effort = _nonEmptyString(reasoningEffort);
    if (steerTurnId == null && effort != null && (decisionModel == null || !_remoteReasoningEfforts.contains(effort))) {
      throw ArgumentError('Codex reasoning effort requires a model and a level supported by the Host');
    }
    final inlineImages = await _fitInlineImages(images, text);
    final input = <Map<String, Object?>>[
      for (final image in inlineImages)
        {'type': 'image', 'mediaType': image.mediaType, 'data': base64Encode(image.bytes)},
      if (text.trim().isNotEmpty) {'type': 'text', 'text': text},
    ];
    if (input.isEmpty) throw ArgumentError('A Codex prompt requires text or an image');
    final result = await _call(steerTurnId == null ? 'turn/start' : 'turn/steer', <String, Object?>{
      'threadId': threadId,
      'input': input,
      if (steerTurnId != null) 'expectedTurnId': steerTurnId else ...{'model': ?decisionModel, 'effort': ?effort},
    });
    if (result is! Map) return steerTurnId;
    final turn = result['turn'];
    return _nonEmptyString(result['turnId']) ?? (turn is Map ? _nonEmptyString(turn['id']) : null) ?? steerTurnId;
  }

  /// Sends a text prompt to [threadId] and starts a turn.
  Future<void> sendText(String threadId, String text, {String? model}) async {
    await sendPrompt(threadId, text, model: model);
  }

  /// Starts a new thread in [cwd], returning the settings the Host applied.
  Future<CodexThreadSettings?> startThread(
    String cwd, {
    String? model,
    String? permissionPreset,
    String? approvalsReviewer,
  }) async {
    final result = await _call('thread/start', {
      'cwd': cwd,
      'model': ?model,
      'permissionPreset': ?permissionPreset,
      'approvalsReviewer': ?approvalsReviewer,
    });
    return CodexThreadSettings._parse(result);
  }

  /// Loads an existing thread or applies an explicit permission change.
  Future<CodexThreadSettings> resumeThread(String threadId, {String? model, String? permissionPreset}) async {
    final result = await _call('thread/resume', {
      'threadId': threadId,
      'model': ?model,
      'permissionPreset': ?permissionPreset,
    });
    final settings = CodexThreadSettings._parse(result, expectedThreadId: threadId);
    if (settings == null) throw const DshProtocolException('thread/resume: invalid settings response');
    return settings;
  }

  /// Detaches this Remote client from the thread through the Host.
  Future<void> unsubscribeThread(String threadId) async {
    await _call('thread/unsubscribe', {'threadId': threadId});
  }

  /// Stops the running turn.
  Future<void> interrupt(String threadId, String turnId) =>
      _call('turn/interrupt', <String, Object?>{'threadId': threadId, 'turnId': turnId});

  /// One image of a thread, decoded from the Host's base64 attachment.
  Future<Uint8List?> fetchAttachment(String threadId, String attachmentId) async {
    final result = await _call('dsh/sessionAttachment', {
      'threadId': threadId,
      'attachmentId': attachmentId,
    }, allowLargeResponse: true);
    if (result is! Map) return null;
    final data = result['data'];
    if (data is! String || data.isEmpty) return null;
    try {
      return base64Decode(data);
    } on FormatException {
      return null;
    }
  }

  /// Sends one inline image and an optional caption.
  Future<void> sendImage(String threadId, Uint8List bytes, String mediaType, {String text = ''}) async {
    await sendPrompt(threadId, text.trim(), images: [(bytes: bytes, mediaType: mediaType)]);
  }

  /// Branches [threadId] into a new thread that keeps its earlier turns.
  Future<String?> fork(String threadId) async {
    final result = await _call('thread/fork', <String, Object?>{'threadId': threadId});
    if (result is Map) {
      final thread = result['thread'];
      if (thread is Map && thread['id'] is String) return thread['id'] as String;
      if (result['id'] is String) return result['id'] as String;
    }
    return null;
  }
}

class CodexUsage {
  const CodexUsage(this.plan, this.windows);

  final String? plan;
  final List<CodexUsageWindow> windows;

  factory CodexUsage.parse(Object? value) {
    if (value is! Map) throw const DshProtocolException('account/rateLimits/read: invalid response');
    final buckets = <String, Object?>{};
    final reported = value['rateLimitsByLimitId'];
    if (reported is Map) {
      for (final entry in reported.entries) {
        if (entry.key is String && entry.value is Map) buckets[entry.key as String] = entry.value;
      }
    }
    final fallback = value['rateLimits'];
    if (fallback is Map) buckets.putIfAbsent('codex', () => fallback);
    final ids = buckets.keys.toList()
      ..sort(
        (a, b) => a == b
            ? 0
            : a == 'codex'
            ? -1
            : b == 'codex'
            ? 1
            : a.compareTo(b),
      );
    final windows = <CodexUsageWindow>[];
    String? plan;
    for (final id in ids) {
      final bucket = buckets[id] as Map;
      plan ??= _nonEmptyString(bucket['planType']);
      final name = _nonEmptyString(bucket['limitName']) ?? (id == 'codex' ? 'Codex' : id);
      for (final key in ['primary', 'secondary']) {
        final window = bucket[key];
        if (window is! Map || window['usedPercent'] is! num) continue;
        final percent = (window['usedPercent'] as num).toDouble();
        if (!percent.isFinite || percent < 0 || percent > 100) continue;
        final reset = _integer(window['resetsAt']);
        windows.add(
          CodexUsageWindow(
            bucketId: id,
            name: name,
            usedPercent: percent,
            durationMinutes: _integer(window['windowDurationMins']),
            resetsAt: reset != null && reset > 0 && reset <= 8640000000000
                ? DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true).toLocal()
                : null,
          ),
        );
      }
    }
    return CodexUsage(plan, List.unmodifiable(windows));
  }
}

class CodexUsageWindow {
  const CodexUsageWindow({
    required this.bucketId,
    required this.name,
    required this.usedPercent,
    this.durationMinutes,
    this.resetsAt,
  });

  final String bucketId;
  final String name;
  final double usedPercent;
  final int? durationMinutes;
  final DateTime? resetsAt;
}

/// One user or assistant message projected from the durable history.
class CodexMessage {
  const CodexMessage({
    required this.fromUser,
    required this.seq,
    required this.time,
    required this.text,
    this.reasoning = '',
    this.attachments = const [],
    this.model,
  });

  final bool fromUser;
  final int seq;
  final DateTime time;
  final String text;
  final String reasoning;
  final List<ImageAttachment> attachments;
  final String? model;

  /// Images that belong to this message, fetched on demand by id.
  List<String> get attachmentIds => [for (final attachment in attachments) attachment.attachmentId];

  static CodexMessage? _fromEvent(SessionLogEvent event) {
    final message = switch (event) {
      UserMessageEvent(:final message) => message,
      AssistantMessageEvent(:final message) => message,
      _ => null,
    };
    if (message == null) return null;
    final attachments = [
      for (final part in message.parts.whereType<ImagePart>())
        if (part.attachment.attachmentId.isNotEmpty) part.attachment,
    ];
    final text = message.text;
    final reasoning = message.reasoning;
    if (text.isEmpty && reasoning.isEmpty && attachments.isEmpty) return null;
    return CodexMessage(
      fromUser: event is UserMessageEvent,
      seq: event.seq,
      time: event.time,
      text: text,
      reasoning: reasoning,
      attachments: attachments,
      model: message.source.model,
    );
  }
}

/// A page of thread history with the paging hints the Host returned.
class CodexHistory {
  const CodexHistory({
    required this.messages,
    required this.hasMore,
    this.records = const [],
    this.header,
    this.cursor,
    this.nextTurn,
    this.activeTurnId,
    this.model,
    this.reasoningEffort,
    this.permissionPreset,
    this.approvalsReviewer,
    this.approvals = const [],
  });

  final List<CodexMessage> messages;
  final List<SessionLogEvent> records;
  final SessionHeader? header;
  final bool hasMore;

  /// Latest sequence in the entire history, including for an older page.
  final int? cursor;
  final int? nextTurn;
  final String? activeTurnId;
  final String? model;
  final String? reasoningEffort;
  final String? permissionPreset;
  final String? approvalsReviewer;
  final List<ApprovalRequest> approvals;

  /// Pass this as `beforeSeq` to load the preceding page.
  int? get oldestSeq => records.firstOrNull?.seq;

  static CodexHistory parse(Object? result, {String? sessionId}) {
    if (result is! Map) return const CodexHistory(messages: <CodexMessage>[], hasMore: false);
    final rawRecords = result['records'];
    final records = <SessionLogEvent>[];
    if (rawRecords is List) {
      for (final rawRecord in rawRecords) {
        if (rawRecord is! Map) continue;
        final event = rawRecord['event'];
        if (event is! Map || (_integer(event['seq']) ?? -1) < 0 || _nonEmptyString(event['type']) == null) continue;
        records.add(SessionLogEvent.fromJson(_attachmentReferences(event)));
      }
    }
    final header = result['header'];
    final preset = result['permissionPreset'];
    final rawApprovals = result['approvals'];
    return CodexHistory(
      messages: records.map(CodexMessage._fromEvent).nonNulls.toList(growable: false),
      records: records,
      header: header is Map ? SessionHeader.fromJson(header) : null,
      hasMore: result['hasMore'] == true,
      cursor: _integer(result['cursor']),
      nextTurn: _integer(result['nextTurn']),
      activeTurnId: _nonEmptyString(result['activeTurnId']),
      model: header is Map ? _nonEmptyString(header['model']) : null,
      reasoningEffort: header is Map ? _nonEmptyString(header['reasoningEffort']) : null,
      approvalsReviewer: codexApprovalReviewer(result['approvalsReviewer']),
      approvals: sessionId == null || rawApprovals is! List
          ? const []
          : [
              for (final raw in rawApprovals.whereType<Map>())
                if (_nonEmptyString(raw['requestHandle']) case final id?)
                  ApprovalRequest(
                    eventId: id,
                    sessionId: sessionId,
                    toolName: raw['method'] == 'item/fileChange/requestApproval' ? 'edit' : 'bash',
                    reason: _nonEmptyString(raw['reason']),
                    raw: {'codexApproval': true, 'command': raw['command']},
                  ),
            ],
      permissionPreset: switch (preset) {
        'workspace-write' => 'workspace-write',
        'danger-full-access' => 'danger-full-access',
        _ => null,
      },
    );
  }

  // The Host includes image bytes in some history responses. Keep only the
  // attachment reference in the transcript and fetch bytes when rendering.
  static Map _attachmentReferences(Map event) {
    final data = event['data'];
    if (data is! Map) return event;
    final nestedMessage = data['message'];
    final message = nestedMessage is Map ? nestedMessage : data;
    final content = message['content'];
    if (content is! List || !content.any((part) => part is Map && part['type'] == 'image')) return event;
    final references = {
      ...message,
      'content': [
        for (final part in content)
          if (part is Map && part['type'] == 'image')
            (Map.of(part)
              ..remove('data')
              ..remove('url'))
          else
            part,
      ],
    };
    return {
      ...event,
      'data': nestedMessage is Map ? {...data, 'message': references} : references,
    };
  }
}
