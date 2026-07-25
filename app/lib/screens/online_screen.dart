import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:online_client/online_client.dart';

import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../data/settings_repository.dart';
import '../engine/engine_provider.dart';
import '../online/online_match_controller.dart';
import '../online/online_providers.dart';
import '../tutor/tutor_service.dart';
import 'game_screen.dart';

/// The online-play entry screen: create a match (share a code, wait for an
/// opponent) or join one by code.
///
/// When [onlineConfigProvider] is `null` the whole feature is unavailable and a
/// friendly not-configured card is shown instead of the create/join cards.
///
/// Both flows end by constructing an [OnlineMatchController], awaiting its
/// [OnlineMatchController.ready] (so [GameScreen] never reads game state before
/// the first opening roll has folded), and pushing [GameScreen]. The board is
/// pinned to the local side: White at the bottom for the creator, Black at the
/// bottom for the joiner.
class OnlineScreen extends ConsumerWidget {
  const OnlineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(onlineConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Play Online')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: config == null
                    ? const _NotConfiguredCard()
                    : const _OnlineBody(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when no online backend is configured for this build.
class _NotConfiguredCard extends StatelessWidget {
  const _NotConfiguredCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Online play isn’t configured in this build',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'This build has no Firebase backend wired up, so create/join '
              'matches are unavailable.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The create + join cards, backed by [matchApiProvider]. Holds all of the
/// flow's transient state (selected length, share code, entered code, in-flight
/// flags, and inline errors).
class _OnlineBody extends ConsumerStatefulWidget {
  const _OnlineBody();

  @override
  ConsumerState<_OnlineBody> createState() => _OnlineBodyState();
}

class _OnlineBodyState extends ConsumerState<_OnlineBody> {
  static const _pollInterval = Duration(seconds: 2);

  // --- Create state ----------------------------------------------------------
  int _matchLength = 5;
  bool _creating = false;
  String? _createdCode;
  String? _createError;

  // --- Join state ------------------------------------------------------------
  final _codeController = TextEditingController();
  bool _joining = false;
  String? _joinError;

  // --- Polling / lifecycle ---------------------------------------------------
  bool _cancelled = false;
  Timer? _pollTimer;

  @override
  void dispose() {
    _cancelWaiting();
    _codeController.dispose();
    super.dispose();
  }

  /// Stops the create-flow polling (a pending wait timer is cancelled so no
  /// timer outlives the screen). No controller exists yet while waiting, so
  /// there is nothing else to release.
  void _cancelWaiting() {
    _cancelled = true;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  String _errorText(Object e) =>
      e is OnlineException ? e.message : 'Something went wrong. Please try again.';

  // --- Create flow -----------------------------------------------------------

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final api = await ref.read(matchApiProvider.future);
      final res = await api.createMatch(_matchLength);
      if (!mounted) return;
      setState(() {
        _createdCode = res.code;
        _cancelled = false;
      });
      unawaited(_pollUntilActive(api, res.matchId));
    } catch (e) {
      if (!mounted) return;
      setState(() => _createError = _errorText(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Polls `fetchMatch` every [_pollInterval] until the match becomes active,
  /// then launches the game as the White (creator) side. Transient fetch
  /// failures surface inline and keep polling; cancelling stops the loop.
  Future<void> _pollUntilActive(MatchApi api, String matchId) async {
    while (mounted && !_cancelled) {
      MatchSnapshot snap;
      try {
        snap = await api.fetchMatch(matchId);
      } catch (e) {
        if (!mounted || _cancelled) return;
        setState(() => _createError = _errorText(e));
        await _wait();
        continue;
      }
      if (!mounted || _cancelled) return;
      if (snap.status == 'active') {
        await _launch(
          api,
          matchId,
          snap,
          localSide: Player.white,
          orientation: BoardOrientationMode.fixedWhite,
        );
        return;
      }
      await _wait();
    }
  }

  /// A cancellable [_pollInterval] delay. [_cancelWaiting] cancels the timer,
  /// leaving the returned future to hang harmlessly (the loop has already exited
  /// via its `mounted`/`_cancelled` checks).
  Future<void> _wait() {
    final completer = Completer<void>();
    _pollTimer = Timer(_pollInterval, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  // --- Join flow -------------------------------------------------------------

  Future<void> _join() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _joinError = 'Enter a match code.');
      return;
    }
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      final api = await ref.read(matchApiProvider.future);
      final matchId = await api.joinMatch(code);
      final snap = await api.fetchMatch(matchId);
      if (!mounted) return;
      await _launch(
        api,
        matchId,
        snap,
        localSide: Player.black,
        orientation: BoardOrientationMode.fixedBlack,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _joinError = _errorText(e));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  // --- Launch ----------------------------------------------------------------

  /// Builds the controller, waits until it is ready, and pushes [GameScreen].
  /// If the screen is torn down (or the controller disposed) before readiness,
  /// the controller is disposed and nothing is pushed.
  Future<void> _launch(
    MatchApi api,
    String matchId,
    MatchSnapshot snapshot, {
    required Player localSide,
    required BoardOrientationMode orientation,
  }) async {
    final controller = OnlineMatchController(
      api: api,
      matchId: matchId,
      localSide: localSide,
      initialSnapshot: snapshot,
    );
    unawaited(controller.playMatch());
    await controller.ready;
    if (!mounted || _cancelled || !controller.isReady) {
      controller.disposeController();
      return;
    }
    // Tutor stays available online; it keys post-move chips on the local side.
    final tutor = TutorService(ref.read(engineFacadeProvider));
    final settings =
        ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameScreen(
          key: ValueKey(controller),
          controller: controller,
          orientation: orientation,
          tutor: tutor,
          animationDuration: settings.hopDuration,
          interactionOptions: BoardInteractionOptions(
            showHighlights: settings.showHighlights,
            enableDrag: settings.enableDrag,
            enableCombinedTaps: settings.enableCombinedTaps,
          ),
          showScoring: settings.showScoring,
        ),
      ),
    );
    // Returned from the game: reset to a fresh create/join view.
    if (mounted) {
      setState(() {
        _createdCode = null;
        _createError = null;
      });
    }
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _createCard(),
        const SizedBox(height: 24),
        _joinCard(),
      ],
    );
  }

  Widget _createCard() {
    final theme = Theme.of(context);
    if (_createdCode != null) return _waitingCard();
    return _SectionCard(
      title: 'Create match',
      children: [
        Text('Match length', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 1, label: Text('1')),
            ButtonSegment(value: 3, label: Text('3')),
            ButtonSegment(value: 5, label: Text('5')),
            ButtonSegment(value: 7, label: Text('7')),
          ],
          selected: {_matchLength},
          onSelectionChanged: _creating
              ? null
              : (s) => setState(() => _matchLength = s.first),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _creating ? null : _create,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _creating
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create'),
        ),
        if (_createError != null) _errorRow(_createError!),
      ],
    );
  }

  Widget _waitingCard() {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Waiting for opponent',
      children: [
        Text('Share this code', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _createdCode!,
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _createdCode!));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Code copied')),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Waiting for opponent…'),
          ],
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () {
            _cancelWaiting();
            setState(() {
              _createdCode = null;
              _createError = null;
            });
          },
          child: const Text('Cancel'),
        ),
        if (_createError != null) _errorRow(_createError!),
      ],
    );
  }

  Widget _joinCard() {
    return _SectionCard(
      title: 'Join match',
      children: [
        TextField(
          controller: _codeController,
          enabled: !_joining,
          textCapitalization: TextCapitalization.characters,
          maxLength: 6,
          decoration: const InputDecoration(
            labelText: 'Match code',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          inputFormatters: [_UpperCaseFormatter()],
          onSubmitted: (_) => _joining ? null : _join(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _joining ? null : _join,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _joining
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Join'),
        ),
        if (_joinError != null) _errorRow(_joinError!),
      ],
    );
  }

  Widget _errorRow(String message) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
  }
}

/// Uppercases everything typed into the join-code field as it is entered.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

/// A titled card wrapper for the create / join / waiting sections.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
