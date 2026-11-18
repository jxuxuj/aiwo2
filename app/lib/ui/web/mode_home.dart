// The home in the chosen 界面 (lib/state/ui_mode_state.dart) — the native shell
// or the official web page — and the quiet switch for the drawer. A switch
// cross-fades and lands on the same conversation on the same host: the web page
// opens the native conversation; the native shell opens what the page reported
// last (WebHome keeps currentSessionProvider current).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/backend_state.dart';
import '../../state/codex_state.dart';
import '../../state/sessions_state.dart';
import '../../state/ui_mode_state.dart';
import '../modes/mode_switch.dart';
import '../shell/home_shell.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_home.dart';
import 'web_target.dart';

/// The app's home in the chosen 界面.
class ModeHome extends ConsumerStatefulWidget {
  const ModeHome({super.key, this.native, this.web});

  /// Stand-ins for the two homes (tests).
  @visibleForTesting
  final Widget? native;
  @visibleForTesting
  final Widget Function(DshWebTarget? initial)? web;

  @override
  ConsumerState<ModeHome> createState() => _ModeHomeState();
}

class _ModeHomeState extends ConsumerState<ModeHome> {
  UiMode? _shown;
  DshWebTarget? _handoff;

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(uiModeProvider);
    if (!mode.loaded) {
      // Read back with the rest of the settings: no frame of the other home.
      return const AppBackdrop(child: SizedBox.expand());
    }
    final backend = ref.watch(backendProvider);
    final shown = backend == ChatBackend.codex ? UiMode.native : mode.mode;
    if (_shown == UiMode.native && shown == UiMode.web) {
      // Switched from the native interface: its conversation (or its new
      // chat) opens in the page. A cold start in web mode lands where the
      // page itself left off.
      final id = ref.read(currentSessionProvider);
      _handoff = id == null || codexThreadId(id) != null
          ? const DshWebTarget(newSession: true)
          : DshWebTarget(sessionId: id);
    }
    _shown = shown;
    final Widget home = shown == UiMode.web
        ? KeyedSubtree(
            key: const ValueKey(UiMode.web),
            child: widget.web?.call(_handoff) ?? WebHome(initial: _handoff),
          )
        : KeyedSubtree(key: const ValueKey(UiMode.native), child: widget.native ?? const HomeShell());
    // A launch into 伙伴 or 酒馆 opens that page over the home first.
    return ModeLaunch(
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.page),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        child: home,
      ),
    );
  }
}

/// A round key for switching the native backend or making the web view the home.
class WebModeKey extends ConsumerWidget {
  const WebModeKey({super.key, this.size = 36, this.tier = GlassTier.chrome, this.switchBackend = false});

  final double size;
  final GlassTier tier;
  final bool switchBackend;

  static String get tooltip => appL10n.webSwitchToWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = switchBackend ? ref.watch(backendProvider) : null;
    return GlassIconButton(
      icon: AppIcons.swap,
      tooltip: switch (backend) {
        ChatBackend.codex => '切换到 DeepSeek',
        ChatBackend.deepseek => '切换到 Codex',
        null => context.l10n.webSwitchToWeb,
      },
      size: size,
      tier: tier,
      onPressed: switchBackend
          ? () => ref.read(backendProvider.notifier).toggle()
          : () => unawaited(ref.read(uiModeProvider.notifier).set(UiMode.web)),
    );
  }
}
