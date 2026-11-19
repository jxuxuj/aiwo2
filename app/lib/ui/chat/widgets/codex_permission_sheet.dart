import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/backend_state.dart';
import '../../../state/chat_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/models_state.dart';
import '../../../state/new_chat_modes.dart';
import '../../../state/sessions_state.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';

String codexApprovalLabel(BuildContext context, String? value) => switch (value) {
  'user' => context.l10n.featuresCodexAskApproval,
  'auto_review' => context.l10n.featuresCodexReviewForMe,
  _ => context.l10n.featuresCodexApprovalTitle,
};

Future<void> showCodexPermissionSheet(BuildContext context, String? sessionId) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (_) => _CodexPermissionSheet(sessionId: sessionId),
  );
}

class _CodexPermissionSheet extends ConsumerStatefulWidget {
  const _CodexPermissionSheet({required this.sessionId});

  final String? sessionId;

  @override
  ConsumerState<_CodexPermissionSheet> createState() => _CodexPermissionSheetState();
}

class _CodexPermissionSheetState extends ConsumerState<_CodexPermissionSheet> {
  late final _scope = ref.read(modelSelectionScopeProvider);
  late final _revision = ref.read(currentSessionProvider.notifier).selectionRevision;
  bool _busy = false;
  bool _retired = false;

  bool get _ownsSheet =>
      mounted &&
      !_retired &&
      ref.read(backendProvider) == ChatBackend.codex &&
      identical(_scope, ref.read(modelSelectionScopeProvider)) &&
      ref.read(currentSessionProvider) == widget.sessionId &&
      ref.read(currentSessionProvider.notifier).selectionRevision == _revision;

  Future<void> _pick(String value) async {
    if (_busy || !_ownsSheet) return;
    setState(() => _busy = true);
    try {
      final sessionId = widget.sessionId;
      if (sessionId == null) {
        final connection = ref.read(activeConnectionProvider).asData?.value;
        if (connection == null || connection.isLocal) return;
        ref.read(pendingCodexNewChatModesProvider.notifier).selectPermission(value);
        return;
      }
      final ok = await ref.read(chatProvider(sessionId).notifier).setCodexApprovalsReviewer(value);
      if (!ok && mounted && _ownsSheet) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l10n.featuresSwitchFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final sessionId = widget.sessionId;
    final connection = ref.watch(activeConnectionProvider).asData?.value;
    final chat = sessionId == null
        ? null
        : ref.watch(
            chatProvider(sessionId)
                .select((state) => (permission: state.codexApprovalsReviewer, editable: state.codexPermissionEditable)),
          );
    final current = sessionId == null ? ref.watch(pendingCodexNewChatModesProvider).permission : chat?.permission;
    ref.watch(currentSessionProvider);
    ref.watch(modelSelectionScopeProvider);
    ref.listen(backendProvider, (_, backend) {
      if (backend != ChatBackend.codex) setState(() => _retired = true);
    });
    final editable = !_busy && _ownsSheet && connection != null && !connection.isLocal && (chat?.editable ?? true);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(l10n.featuresCodexApprovalTitle),
            SheetGroup(
              children: [
                for (final value in codexApprovalReviewers)
                  Semantics(
                    selected: value == current,
                    inMutuallyExclusiveGroup: true,
                    child: ListPageRow(
                      title: codexApprovalLabel(context, value),
                      subtitle: value == 'user' ? l10n.featuresCodexAskApprovalHint : l10n.featuresCodexReviewForMeHint,
                      onTap: editable && value != current ? () => _pick(value) : null,
                      trailing: value == current
                          ? Icon(AppIcons.selected, size: 22, color: colors.primary)
                          : const SizedBox.square(dimension: 22),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
