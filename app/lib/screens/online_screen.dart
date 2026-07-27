import 'dart:async';

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:online_client/online_client.dart';

import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../data/match_repository.dart';
import '../data/persistence_hooks.dart';
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
  bool _cubeless = false;
  bool _creating = false;
  String? _createdCode;
  String? _createError;

  // --- Join state ------------------------------------------------------------
  final _codeController = TextEditingController();
  bool _joining = false;
  String? _joinError;

  // --- Rejoin state ----------------------------------------------------------
  /// The match this device was last in, if any — the resume pointer the online
  /// session store kept across the restart.
  String? _resumeCode;
  bool _rejoining = false;
  String? _rejoinError;

  // --- Polling / lifecycle ---------------------------------------------------
  bool _cancelled = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadResume());
  }

  @override
  void dispose() {
    _cancelWaiting();
    _codeController.dispose();
    super.dispose();
  }

  /// Read the resume pointer written by the last launch. Absent on a fresh
  /// install and after a match finishes, which is the common case — the card
  /// only appears when there really is something to go back to.
  Future<void> _loadResume() async {
    final code = await ref.read(onlineSessionStoreProvider).lastMatchCode();
    if (!mounted || code == null) return;
    setState(() => _resumeCode = code);
  }

  /// Stops the create-flow polling (a pending wait timer is cancelled so no
  /// timer outlives the screen). No controller exists yet while waiting, so
  /// there is nothing else to release.
  void _cancelWaiting() {
    _cancelled = true;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// User-facing copy for a transport failure.
  ///
  /// The typed exceptions carry developer-shaped messages (they name document
  /// paths and statuses), so the three the user can actually hit get their own
  /// line: a mistyped code, a seat someone else took, and a match that is not
  /// ours to look at.
  String _errorText(Object e) {
    if (e is NotFoundException) {
      return 'No match with that code. Check it and try again.';
    }
    if (e is FailedPreconditionException) {
      return 'That match is no longer open — the seat has been taken.';
    }
    if (e is PermissionDeniedException) {
      return 'That match is not open to you.';
    }
    if (e is OnlineException) return e.message;
    return 'Something went wrong. Please try again.';
  }

  // --- Rejoin flow -----------------------------------------------------------

  /// Re-enter a match this device is already a participant of.
  ///
  /// This is the OTHER half of making the uid durable: restoring the identity
  /// is what makes the match readable again, and this is what gets the player
  /// back into it. [MatchApi.joinMatch] deliberately refuses a participant (it
  /// claims the empty seat), so the rejoin path is a plain read plus the seat
  /// the match document already records for us.
  Future<void> _rejoin(String code) async {
    setState(() {
      _rejoining = true;
      _rejoinError = null;
    });
    try {
      final api = await ref.read(matchApiProvider.future);
      final doc = await api.fetchMatch(code);
      if (doc.sideOf(api.uid) == null || doc.isComplete) {
        // Not ours any more (the match ended while we were away, or the stored
        // identity was replaced). Drop the pointer rather than offering a dead
        // door — which takes the whole card with it, so the explanation has to
        // outlive it as a snackbar.
        await _forgetResume();
        _say('That match has finished — nothing left to rejoin.');
        return;
      }
      if (!mounted) return;
      await _launch(api, doc);
    } catch (e) {
      if (e is NotFoundException) await _forgetResume();
      if (!mounted) return;
      setState(() => _rejoinError = _errorText(e));
    } finally {
      if (mounted) setState(() => _rejoining = false);
    }
  }

  /// A transient message for something the user asked for whose UI has just
  /// gone away (see [_rejoin]).
  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _forgetResume() async {
    await ref.read(onlineSessionStoreProvider).forgetMatch();
    if (!mounted) return;
    setState(() => _resumeCode = null);
  }

  // --- Create flow -----------------------------------------------------------

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final api = await ref.read(matchApiProvider.future);
      final doc = await api.createMatch(
        length: _matchLength,
        cubeless: _cubeless,
      );
      if (!mounted) return;
      setState(() {
        _createdCode = doc.code;
        _cancelled = false;
      });
      unawaited(_pollUntilActive(api, doc.code));
    } catch (e) {
      if (!mounted) return;
      setState(() => _createError = _errorText(e));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Polls `fetchMatch` every [_pollInterval] until an opponent has taken the
  /// guest seat, then launches the game as the White (host) side. Transient
  /// fetch failures surface inline and keep polling; cancelling stops the loop.
  Future<void> _pollUntilActive(MatchApi api, String code) async {
    while (mounted && !_cancelled) {
      MatchDoc doc;
      try {
        doc = await api.fetchMatch(code);
      } catch (e) {
        if (!mounted || _cancelled) return;
        setState(() => _createError = _errorText(e));
        await _wait();
        continue;
      }
      if (!mounted || _cancelled) return;
      if (doc.isActive) {
        await _launch(api, doc);
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
      // The join both claims the seat and returns the match as it now stands,
      // so there is nothing to read back.
      MatchDoc doc;
      try {
        doc = await api.joinMatch(code);
      } on FailedPreconditionException {
        // Both seats are taken — which includes the case where one of them is
        // OURS (joinMatch only ever claims the empty seat). Typing your own
        // code back in is a perfectly reasonable way to ask to resume, so read
        // the match and re-enter it if it turns out we are already in it.
        final existing = await api.fetchMatch(code);
        if (existing.sideOf(api.uid) == null || existing.isComplete) rethrow;
        doc = existing;
      }
      if (!mounted) return;
      await _launch(api, doc);
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
  ///
  /// The seat is positional and comes from the match document (host plays white,
  /// guest black), so both flows funnel through here.
  Future<void> _launch(MatchApi api, MatchDoc doc) async {
    final localSide = doc.sideOf(api.uid) ?? Player.white;
    final orientation = localSide == Player.white
        ? BoardOrientationMode.fixedWhite
        : BoardOrientationMode.fixedBlack;
    // Create the local history row for this online match and bind persistence to
    // it. The local seat is 'human'; the opponent is 'remote'. The insert runs
    // fire-and-forget; the controller's hooks await the id before recording a
    // finished game, and the post-match "Match summary" link awaits it too.
    final repo = ref.read(matchRepositoryProvider);
    final matchIdFuture = repo.startMatch(
      matchLength: doc.length,
      mode: 'online',
      whiteType: localSide == Player.white ? 'human' : 'remote',
      blackType: localSide == Player.black ? 'human' : 'remote',
    );
    final controller = OnlineMatchController(
      api: api,
      matchDoc: doc,
      persistence: RepositoryPersistence(repo, matchIdFuture),
    );
    // Remember the match BEFORE playing it: the point of the pointer is to
    // survive a crash or a kill mid-match, which is exactly when nothing later
    // in this method gets to run.
    final store = ref.read(onlineSessionStoreProvider);
    await store.rememberMatch(doc.code);
    if (mounted) setState(() => _resumeCode = doc.code);
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
          // The header names the sides "You … Opp" online (the remote player is
          // not the AI); see GameScreen.opponentLabel.
          opponentLabel: 'Opp',
          persistedMatchId: matchIdFuture,
          timings: settings.timings,
          interactionOptions: BoardInteractionOptions(
            showHighlights: settings.showHighlights,
            enableDrag: settings.enableDrag,
            enableCombinedTaps: settings.enableCombinedTaps,
          ),
          showScoring: settings.showScoring,
          // One-time drag/tap hint: shown on the first human move when drag is on
          // and it has not been shown before. Persist the flag fire-and-forget.
          dragHintShown: settings.dragHintShown,
          onDragHintShown: () => ref
              .read(settingsRepositoryProvider)
              .save(settings.copyWith(dragHintShown: true)),
        ),
      ),
    );
    // Returned from the game. A decided match is nothing to come back to, so
    // the resume pointer goes with it; an unfinished one is left standing so
    // the Rejoin card can offer it.
    final finished = controller.matchOver;
    if (finished) await store.forgetMatch();
    if (mounted) {
      setState(() {
        _createdCode = null;
        _createError = null;
        _rejoinError = null;
        if (finished) _resumeCode = null;
      });
    }
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final resume = _resumeCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resume != null) ...[
          _rejoinCard(resume),
          const SizedBox(height: 24),
        ],
        _createCard(),
        const SizedBox(height: 24),
        _joinCard(),
      ],
    );
  }

  /// Offered only when this device is still carrying a match pointer. The uid
  /// behind it is durable now, so the seat named in that match is still ours.
  Widget _rejoinCard(String code) {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Match in progress',
      children: [
        Text('You were playing match $code.',
            style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _rejoining ? null : () => _rejoin(code),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _rejoining
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Rejoin'),
        ),
        TextButton(
          onPressed: _rejoining ? null : _forgetResume,
          child: const Text('Forget this match'),
        ),
        if (_rejoinError != null) _errorRow(_rejoinError!),
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
        // The cube option is now the HOST's, carried in the match document, and
        // honoured by both peers (in the callable era the cube was
        // server-mediated and there was no online choice to make).
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Play without cube'),
          subtitle: const Text('No doubling cube this match'),
          value: _cubeless,
          onChanged: _creating ? null : (v) => setState(() => _cubeless = v),
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
          // The code IS the match document id: [kCodeLength] characters from
          // [kCodeAlphabet].
          maxLength: kCodeLength,
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
