import 'dart:async';
import 'dart:io' show SocketException;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import '../analytics/analytics_events.dart';
import '../analytics/analytics_screen_view.dart';
import '../analytics/app_analytics.dart';
import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../data/match_repository.dart';
import '../data/persistence_hooks.dart';
import '../data/settings_repository.dart';
import '../diagnostics/crash_log.dart';
import '../engine/engine_provider.dart';
import '../lan/join_qr_code.dart';
import '../lan/lan_transport.dart';
import '../lan/qr_payload.dart';
import '../lan/qr_scanner.dart';
import '../net/net_match_controller.dart';
import '../tutor/tutor_service.dart';
import 'game_screen.dart';

/// How often the JOIN tab sweeps for hosts while it is on screen.
const Duration _probeInterval = Duration(seconds: 3);

/// How long one sweep listens for answers. Comfortably inside [_probeInterval]
/// so sweeps never overlap.
const Duration _probeTimeout = Duration(seconds: 2);

/// "Play Nearby": two devices on the same Wi-Fi, no internet and no account.
///
/// HOST sets the match up, binds the server, shows a four-digit room code and
/// waits. JOIN finds hosts by UDP probe (or takes an address typed by hand) and
/// presents the code. Both tabs end the same way: a [NetMatchController] — the
/// same one online play uses — and a [GameScreen], with the local side pinned to
/// the bottom of the board.
///
/// ## Who owns what
///
/// This screen owns the LINK: a [HostSession] (server + beacon + match log) or a
/// [GuestSession] (one socket) is created here and torn down here — on "Stop
/// hosting", on a failed join, when the game screen is popped, and in `dispose`.
///
/// It does NOT own the transport. `session.controller()` builds a
/// [SocketTransport] over the link and hands it to the controller, which disposes
/// it; this screen only ever disposes the controller and then stops the session,
/// in that order. See `lan_transport.dart` for the three-owner split.
///
/// ## The room code is the only secret
///
/// Discovery advertises presence only — a name and a port. The four digits are
/// spoken across the table, and they are what authorises the guest, so this
/// screen shows them large on the host and asks for them on the guest. See
/// [HostBeacon].
class LanScreen extends StatefulWidget {
  const LanScreen({super.key});

  @override
  State<LanScreen> createState() => _LanScreenState();
}

class _LanScreenState extends State<LanScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_onTab);
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  /// The JOIN tab only probes while it is the visible one — a background sweep
  /// every three seconds is pure battery on a screen nobody is looking at.
  void _onTab() {
    if (_tabs.index == _index) return;
    setState(() => _index = _tabs.index);
  }

  @override
  // See [HomeScreen] for why every screen splits build/_build.
  Widget build(BuildContext context) => AnalyticsScreenView(
        name: AnalyticsScreens.lan,
        child: _build(context),
      );

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Play Nearby'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Host'), Tab(text: 'Join')],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabs,
          children: [
            const _HostTab(),
            _JoinTab(active: _index == 1),
          ],
        ),
      ),
    );
  }
}

// --- host --------------------------------------------------------------------

/// Set the match up, start serving, and wait for someone to present the code.
class _HostTab extends ConsumerStatefulWidget {
  const _HostTab();

  @override
  ConsumerState<_HostTab> createState() => _HostTabState();
}

class _HostTabState extends ConsumerState<_HostTab> {
  int _matchLength = 5;
  bool _cubeless = false;
  bool _starting = false;

  HostSession? _session;
  String? _localAddress;
  String? _error;

  /// True from the moment a guest joins until the game screen has been pushed,
  /// so a presence flap cannot open two boards.
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    final settings =
        ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
    _matchLength = settings.defaultMatchLength;
  }

  @override
  void dispose() {
    // Leaving the screen releases the port, the beacon and the match log.
    // dispose cannot wait, and there is nobody left to tell if the socket
    // refuses to close — but the crash log still wants to know.
    final leaving = _session?.stop();
    if (leaving != null) recordFailures(leaving, source: 'lan-stop-hosting');
    _session = null;
    super.dispose();
  }

  // --- hosting ---------------------------------------------------------------

  Future<void> _startHosting() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final transport = ref.read(nearbyTransportProvider);
      final session = await transport.startHosting(
        config: MatchConfig(length: _matchLength, cubeless: _cubeless),
        name: transport.deviceName,
      );
      if (!mounted) {
        await session.stop();
        return;
      }
      setState(() => _session = session);
      session.guestConnected.addListener(_onGuestPresence);
      // Cosmetic: the card shows the address so a guest can type it. If the
      // lookup fails the card simply omits it and the QR code still works.
      recordFailures(_lookupAddress(transport), source: 'lan-local-address');
      // A guest may already have claimed the slot between the bind and here.
      _onGuestPresence();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _hostErrorText(e));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _lookupAddress(NearbyTransport transport) async {
    final address = await transport.localAddress();
    if (!mounted) return;
    setState(() => _localAddress = address);
  }

  /// Stop serving and return to the setup form.
  Future<void> _stopHosting() async {
    final session = _session;
    if (session == null) return;
    session.guestConnected.removeListener(_onGuestPresence);
    _session = null;
    if (mounted) {
      setState(() {
        _localAddress = null;
        _launching = false;
      });
    } else {
      _launching = false;
    }
    await session.stop();
  }

  void _onGuestPresence() {
    final session = _session;
    if (session == null || _launching) return;
    if (!session.guestConnected.value) return;
    _launching = true;
    // Cleared on EVERY exit — success, failure and throw alike. It used to be
    // cleared only where the launch succeeded, so the bail below (a controller
    // that never became ready) latched it forever and no later presence flap
    // could open a board: the same "stuck true" shape as the drops this
    // transport has been bitten by twice.
    unawaited(_launch(session).catchError((Object e, StackTrace stack) {
      // Nobody awaits this — it is fired from a presence listener — so a throw
      // on the way to the board (a history row that will not insert, a
      // teardown that fails) had no owner. The host is still hosting, so it
      // goes to the same slot a controller that never became ready uses.
      CrashLog.instance.record(e, stack: stack, source: 'lan-host-launch');
      if (mounted) setState(() => _error = _launchErrorText(e));
    }).whenComplete(() => _launching = false));
  }

  /// Build the host's controller, wait for game 1 to fold, and open the board.
  Future<void> _launch(HostSession session) async {
    final settings = await _launchSettings(ref);
    if (!mounted || !identical(_session, session)) return;
    final repo = ref.read(matchRepositoryProvider);
    final side = session.localSide;
    // The local seat is 'human', the peer 'remote' — the same shape online
    // matches use, under a distinct 'lan' mode so history can tell them apart.
    final matchIdFuture = repo.startMatch(
      matchLength: session.config.length,
      mode: 'lan',
      whiteType: side == Player.white ? 'human' : 'remote',
      blackType: side == Player.black ? 'human' : 'remote',
    );
    ref.read(appAnalyticsProvider).logMatchStarted(
          mode: AnalyticsModes.lan,
          matchLength: session.config.length,
          cubeless: session.config.cubeless,
          // The tutor default is the user's setting (see _openGame), read
          // once for the whole launch above.
          tutor: settings.networkedTutorEnabled,
        );
    final controller = session.controller(
      persistence: RepositoryPersistence(repo, matchIdFuture),
    );
    unawaited(controller.playMatch());
    // The "connecting…" wait, measured on BOTH peers: the host's clock starts
    // when the guest is already attached, the guest's when the handshake has
    // just succeeded, and in each case it ends when the first synchronized
    // state has folded. That gap is the one a user reads as "is it stuck?".
    await ref
        .read(appPerformanceProvider)
        .trace(PerfTraces.lanConnect, () => controller.ready);
    if (!mounted || !identical(_session, session) || !controller.isReady) {
      // `ready` also completes when the controller gives up, leaving isReady
      // false and the reason on `error` — read it BEFORE disposing. Silently
      // stopping the spinner left the host staring at a room code that would
      // never open a board, with nothing said about why.
      final failure = controller.error;
      final live = mounted && identical(_session, session);
      controller.disposeController();
      if (live && failure != null) {
        setState(() => _error = _launchErrorText(failure));
      }
      return;
    }
    await _openGame(
      context: context,
      ref: ref,
      controller: controller,
      matchIdFuture: matchIdFuture,
      settings: settings,
      opponentLabel: _shortName(session.guestName),
    );
    // Back from the game: the controller goes first (and takes its transport
    // with it), then the port, the beacon and the match log; the tab resets to
    // its form.
    controller.disposeController();
    await _stopHosting();
  }

  /// A controller that never became ready — the link died inside the handshake,
  /// or the guest went away again before the first state folded. The host is
  /// still hosting, so the copy points at the retry that actually exists.
  String _launchErrorText(Object e) {
    final reason = e is TransportException ? e.message : '$e';
    return 'The game could not be started: $reason. The other device can try '
        'joining again.';
  }

  String _hostErrorText(Object e) => e is SocketException
      ? 'Could not start hosting — the port is already in use. '
          'Close any other copy of AIGammon and try again.'
      : 'Could not start hosting. Check your Wi-Fi connection and try again.';

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return _TabBody(
      children: _session == null ? _setup() : _waiting(_session!),
    );
  }

  List<Widget> _setup() {
    final theme = Theme.of(context);
    return [
      _SectionCard(
        title: 'Host a game',
        children: [
          Text(
            'Both devices must be on the same Wi-Fi. This one deals the dice '
            'and keeps the score.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
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
            onSelectionChanged:
                _starting ? null : (s) => setState(() => _matchLength = s.first),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Play without cube'),
            subtitle: const Text('No doubling cube this match'),
            value: _cubeless,
            onChanged:
                _starting ? null : (v) => setState(() => _cubeless = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _starting ? null : _startHosting,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: _starting
                ? const _ButtonSpinner()
                : const Text('Start hosting'),
          ),
          if (_error != null) _ErrorRow(_error!),
        ],
      ),
    ];
  }

  List<Widget> _waiting(HostSession session) {
    final theme = Theme.of(context);
    final address = _localAddress;
    return [
      _SectionCard(
        title: 'Waiting for a player',
        children: [
          // The QR code is the fast path and the text below it is the reliable
          // one. Both are shown, always: scanning needs two devices that can be
          // pointed at each other, which a tabletop setup (one phone flat on
          // the table, two players either side) frequently is not.
          if (address != null) ...[
            JoinQrCode(
              payload: QrJoinPayload(
                address: address,
                port: session.port,
                code: session.roomCode,
              ),
            ),
            const SizedBox(height: 20),
          ],
          Text('Room code', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Center(
            child: SelectableText(
              session.roomCode,
              style: theme.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 10,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Tell the other player this code. It is what lets them in — the '
            'app never sends it over the network.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _AddressRow(address: _localAddress, port: session.port),
          const SizedBox(height: 20),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Waiting for a player…'),
            ],
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () =>
                recordFailures(_stopHosting(), source: 'lan-stop-hosting'),
            child: const Text('Stop hosting'),
          ),
          if (_error != null) _ErrorRow(_error!),
        ],
      ),
    ];
  }
}

/// Where the other device should knock when discovery cannot find this one.
class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.address, required this.port});

  final String? address;
  final int port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (address == null) {
      // No address to show (no Wi-Fi answer, enumeration refused). Discovery is
      // still running, so this is a hint rather than a dead end.
      return Text(
        'Ask the other device to look for nearby games. Listening on port '
        '$port.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      );
    }
    return Column(
      children: [
        Text('On this network', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SelectableText(
              '$address:$port',
              style: theme.textTheme.titleMedium,
            ),
            IconButton(
              tooltip: 'Copy address',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: '$address:$port'));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied')),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}

// --- join --------------------------------------------------------------------

/// Where the JOIN tab is in its flow.
enum _JoinPhase {
  /// Sweeping for hosts, with the manual-entry form underneath.
  browsing,

  /// A host is picked; the room code is being typed.
  code,

  /// Connecting (or waiting out a busy room, or reporting a terminal failure).
  connecting,
}

/// One host to connect to, from either the discovered list or the manual form.
class _Target {
  const _Target({required this.name, required this.address, required this.port});

  final String name;
  final String address;
  final int port;
}

/// Find a host, present the code, and open the board.
class _JoinTab extends ConsumerStatefulWidget {
  const _JoinTab({required this.active});

  /// Whether this tab is the visible one — probing runs only while it is.
  final bool active;

  @override
  ConsumerState<_JoinTab> createState() => _JoinTabState();
}

class _JoinTabState extends ConsumerState<_JoinTab> {
  _JoinPhase _phase = _JoinPhase.browsing;

  final List<DiscoveredHost> _hosts = [];
  bool _probing = false;
  Timer? _sweep;

  _Target? _target;
  final _codeController = TextEditingController();
  final _addressController = TextEditingController();
  final _portController = TextEditingController(text: '$defaultMatchPort');
  final _manualCodeController = TextEditingController();

  GuestSession? _session;
  StreamSubscription<GuestConnectionState>? _statesSub;
  GuestConnectionState _linkState = const GuestConnectionState.connecting();
  String? _failure;
  String? _formError;

  /// Whatever the last scan had to say — a foreign code, a refused camera —
  /// shown under the scan button rather than under the typing form.
  String? _scanError;

  /// True while a scanner route is open. A second tap on the button (or a
  /// double tap registered as two) must not push a second camera, and the
  /// scanner's own latch cannot see the taps that got it there.
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _startSweeping();
  }

  @override
  void didUpdateWidget(_JoinTab old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      _startSweeping();
    } else {
      _stopSweeping();
    }
  }

  @override
  void dispose() {
    _stopSweeping();
    _releaseSession();
    _codeController.dispose();
    _addressController.dispose();
    _portController.dispose();
    _manualCodeController.dispose();
    super.dispose();
  }

  // --- discovery -------------------------------------------------------------

  void _startSweeping() {
    _sweep?.cancel();
    _sweep = Timer.periodic(
        _probeInterval, (_) => recordFailures(_probe(), source: 'lan-probe'));
    // A microtask, not a direct call: this runs from initState and from
    // didUpdateWidget, where the first thing [_probe] does — setState — is not
    // yet legal.
    scheduleMicrotask(() {
      if (mounted) recordFailures(_probe(), source: 'lan-probe');
    });
  }

  void _stopSweeping() {
    _sweep?.cancel();
    _sweep = null;
  }

  /// One sweep. Overlapping sweeps are skipped rather than queued, and results
  /// are dropped unless the list is still what the user is looking at.
  Future<void> _probe() async {
    if (_probing || _phase != _JoinPhase.browsing) return;
    setState(() => _probing = true);
    List<DiscoveredHost> found;
    try {
      found = await ref
          .read(nearbyTransportProvider)
          .discover(timeout: _probeTimeout);
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      if (_phase != _JoinPhase.browsing) return;
      _hosts
        ..clear()
        ..addAll(found);
    });
  }

  // --- connecting ------------------------------------------------------------

  void _pick(DiscoveredHost host) {
    _codeController.clear();
    setState(() {
      _target = _Target(
          name: host.name, address: host.address, port: host.port);
      _phase = _JoinPhase.code;
      _failure = null;
      _formError = null;
    });
  }

  void _backToBrowsing() {
    setState(() {
      _phase = _JoinPhase.browsing;
      _target = null;
      _failure = null;
      // Whatever the last scan said is about a scan that is over.
      _scanError = null;
    });
    if (widget.active) _startSweeping();
  }

  /// Validate and start the connection for the currently picked host.
  void _connectPicked() {
    final code = _codeController.text.trim();
    if (!_validCode(code)) {
      setState(() => _formError = 'Enter the 4-digit code from the other '
          'device.');
      return;
    }
    _startConnect(_target!, code);
  }

  /// Validate and start the connection for the typed-in address.
  void _connectManual() {
    final address = _addressController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final code = _manualCodeController.text.trim();
    if (address.isEmpty) {
      setState(() => _formError = 'Enter the address shown on the other '
          'device.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _formError = 'Enter a port between 1 and 65535.');
      return;
    }
    if (!_validCode(code)) {
      setState(() => _formError = 'Enter the 4-digit code from the other '
          'device.');
      return;
    }
    _startConnect(_Target(name: address, address: address, port: port), code);
  }

  bool _validCode(String code) => validRoomCode(code);

  // --- scanning --------------------------------------------------------------

  /// Open the camera, and if it comes back with one of our codes, join.
  ///
  /// The scanned target is written into the manual-entry fields on the way
  /// past. That is not decoration: if the join then fails (the host stopped, the
  /// code is stale) the user is left looking at exactly what was scanned, in
  /// fields they can correct by hand. Scanning is a shortcut through the manual
  /// path, not a separate one.
  Future<void> _scan() async {
    if (_scanning || _phase != _JoinPhase.browsing) return;
    _scanning = true;
    try {
      final outcome = await ref.read(qrScannerProvider).scan(context);
      if (!mounted) return;
      switch (outcome) {
        case QrScanCancelled():
          // Backed out on purpose. Nothing to report — and nothing left over
          // either: a message about the LAST scan ("that was not an AIGammon
          // code") is stale the moment a new scan is opened, and leaving it
          // under the button makes a deliberate cancellation look like a
          // failure.
          if (_scanError != null) setState(() => _scanError = null);
        case QrScanUnavailable(:final message):
          // No camera, or no permission. The typing form below is untouched and
          // still works — that is the whole point of saying this here.
          setState(() => _scanError = message);
        case QrScanCode(:final raw):
          final payload = tryDecodeQrJoin(raw);
          if (payload == null) {
            setState(() => _scanError = 'That QR code is not an AIGammon game. '
                'Scan the one on the other device\'s Host screen.');
            return;
          }
          _addressController.text = payload.address;
          _portController.text = '${payload.port}';
          _manualCodeController.text = payload.code;
          setState(() {
            _scanError = null;
            _formError = null;
          });
          _startConnect(
            _Target(
              name: payload.address,
              address: payload.address,
              port: payload.port,
            ),
            payload.code,
          );
      }
    } catch (e, stack) {
      // The scanner is a platform channel and a camera: it can fail in ways
      // the QrScanUnavailable result does not cover. The user tapped Scan and
      // is owed an answer, and the typing form below still works.
      CrashLog.instance.record(e, stack: stack, source: 'lan-scan');
      if (mounted) {
        setState(() => _scanError = 'The scanner could not be opened. '
            'Enter the address and code below instead.');
      }
    } finally {
      // Guards the ROUTE, so it is released as soon as the route is gone —
      // long before the join it may have started finishes.
      _scanning = false;
    }
  }

  /// Fires [_connect] from a tap. The three entry points — a discovered host,
  /// a typed address, a scanned code — all land here so the join has exactly
  /// one error owner.
  ///
  /// [_connect] guards the handshake itself, but everything around it (opening
  /// the socket, and the launch that follows a successful welcome) could still
  /// throw into nobody: this is a tap, not an await. The connecting card is
  /// where a join failure belongs, and it already carries Try again and Back.
  void _startConnect(_Target target, String code) {
    unawaited(_connect(target, code).catchError((Object e, StackTrace stack) {
      CrashLog.instance.record(e, stack: stack, source: 'lan-join');
      _releaseSession();
      if (mounted) setState(() => _failure = _joinErrorText(e));
    }));
  }

  Future<void> _connect(_Target target, String code) async {
    _stopSweeping();
    final transport = ref.read(nearbyTransportProvider);
    final session = transport.join(
      address: target.address,
      port: target.port,
      code: code,
      name: transport.deviceName,
    );
    _session = session;
    _statesSub = session.states.listen((s) {
      if (mounted) setState(() => _linkState = s);
    });
    setState(() {
      _target = target;
      _phase = _JoinPhase.connecting;
      _failure = null;
      _formError = null;
      _linkState = session.state;
    });
    try {
      await session.welcome;
    } catch (e) {
      // Release FIRST, then report: a dead session must not outlive the message
      // about it, and the retry button rebuilds from a clean slate.
      final message = _joinErrorText(e);
      _releaseSession();
      if (!mounted) return;
      setState(() => _failure = message);
      return;
    }
    if (!mounted || !identical(_session, session)) {
      recordFailures(session.dispose(), source: 'lan-release');
      return;
    }
    await _launch(session);
  }

  /// Drop the current session, synchronously.
  ///
  /// The teardown itself is fire-and-forget. Waiting on it would buy nothing —
  /// there is no failure mode a user could act on — and it would make the UI
  /// hostage to a socket close. (It is also untestable: a broadcast
  /// subscription's `cancel()` future does not complete under the widget
  /// tester's clock, so an awaiting screen would simply never repaint.) What
  /// MUST happen now is that this screen stops treating the session as live.
  void _releaseSession() {
    final session = _session;
    final sub = _statesSub;
    _session = null;
    _statesSub = null;
    if (sub != null) recordFailures(sub.cancel(), source: 'lan-release');
    if (session != null) {
      recordFailures(session.dispose(), source: 'lan-release');
    }
  }

  /// Build the guest's controller and open the board.
  Future<void> _launch(GuestSession session) async {
    final settings = await _launchSettings(ref);
    if (!mounted || !identical(_session, session)) return;
    final repo = ref.read(matchRepositoryProvider);
    final side = session.localSide;
    final matchIdFuture = repo.startMatch(
      matchLength: session.config.length,
      mode: 'lan',
      whiteType: side == Player.white ? 'human' : 'remote',
      blackType: side == Player.black ? 'human' : 'remote',
    );
    ref.read(appAnalyticsProvider).logMatchStarted(
          mode: AnalyticsModes.lan,
          matchLength: session.config.length,
          cubeless: session.config.cubeless,
          // The tutor default is the user's setting (see _openGame), read
          // once for the whole launch above.
          tutor: settings.networkedTutorEnabled,
        );
    final controller = session.controller(
      persistence: RepositoryPersistence(repo, matchIdFuture),
    );
    unawaited(controller.playMatch());
    // The "connecting…" wait, measured on BOTH peers: the host's clock starts
    // when the guest is already attached, the guest's when the handshake has
    // just succeeded, and in each case it ends when the first synchronized
    // state has folded. That gap is the one a user reads as "is it stuck?".
    await ref
        .read(appPerformanceProvider)
        .trace(PerfTraces.lanConnect, () => controller.ready);
    if (!mounted || !identical(_session, session) || !controller.isReady) {
      // As on the host side: the reason lives on `error` and dies with the
      // controller, so it is read first and shown on the connecting card, which
      // already carries a Try-again and a Back.
      final failure = controller.error;
      final live = mounted && identical(_session, session);
      controller.disposeController();
      _releaseSession();
      if (live && failure != null) {
        setState(() => _failure = _joinErrorText(failure));
      }
      return;
    }
    await _openGame(
      context: context,
      ref: ref,
      controller: controller,
      matchIdFuture: matchIdFuture,
      settings: settings,
      opponentLabel: _shortName(_target?.name),
    );
    controller.disposeController();
    _releaseSession();
    if (!mounted) return;
    _backToBrowsing();
  }

  /// Turn a handshake failure into something a person can act on.
  String _joinErrorText(Object e) {
    final reason = e is GuestHandshakeException ? e.reason : '$e';
    final lower = reason.toLowerCase();
    if (lower.contains('code')) {
      return 'Wrong room code. Check the four digits on the other device.';
    }
    if (lower.contains('version') || lower.contains('protocol')) {
      return 'The other device is running a different version of AIGammon.';
    }
    if (lower.contains('handshake required')) {
      return 'That device did not answer the way AIGammon does. Check the '
          'address and port.';
    }
    return 'Could not join: $reason';
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return _TabBody(
      children: switch (_phase) {
        _JoinPhase.browsing => [
            _scanCard(),
            const SizedBox(height: 16),
            _hostsCard(),
            const SizedBox(height: 16),
            _manualCard(),
          ],
        _JoinPhase.code => [_codeCard()],
        _JoinPhase.connecting => [_connectingCard()],
      },
    );
  }

  /// The fast path: the host's screen carries everything this device needs, so
  /// point the camera at it and skip both the search and the typing.
  Widget _scanCard() {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Scan the host',
      children: [
        Text(
          'The other device shows a QR code on its Host screen. Scanning it '
          'fills in the address and the room code for you.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => recordFailures(_scan(), source: 'lan-scan'),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR code'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (_scanError != null) _ErrorRow(_scanError!),
      ],
    );
  }

  Widget _hostsCard() {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Nearby games',
      children: [
        if (_hosts.isEmpty && _probing)
          const _StatusRow(text: 'Looking for nearby games…')
        else if (_hosts.isEmpty)
          Text(
            'No games found yet. Make sure the other device is hosting and '
            'both are on the same Wi-Fi — or enter its address below.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else
          for (final host in _hosts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_other),
              title: Text(host.name),
              subtitle: Text('${host.address}:${host.port}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pick(host),
            ),
        if (_hosts.isNotEmpty && _probing)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: _StatusRow(text: 'Still looking…'),
          ),
      ],
    );
  }

  Widget _manualCard() {
    final theme = Theme.of(context);
    return _SectionCard(
      title: 'Enter address',
      children: [
        Text(
          'Automatic discovery does not work on every network (and on iOS it '
          'may be blocked entirely). The host screen shows this device what to '
          'type.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _addressController,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.20',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _manualCodeController,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Room code',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _connectManual(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _connectManual,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Connect'),
        ),
        if (_formError != null) _ErrorRow(_formError!),
      ],
    );
  }

  Widget _codeCard() {
    final theme = Theme.of(context);
    final target = _target!;
    return _SectionCard(
      title: 'Join ${target.name}',
      children: [
        Text(
          'Enter the 4-digit code shown on the other device.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 8),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Room code',
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _connectPicked(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _connectPicked,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Connect'),
        ),
        TextButton(
          onPressed: _backToBrowsing,
          child: const Text('Back'),
        ),
        if (_formError != null) _ErrorRow(_formError!),
      ],
    );
  }

  Widget _connectingCard() {
    final target = _target!;
    final failure = _failure;
    return _SectionCard(
      title: 'Joining ${target.name}',
      children: [
        if (failure != null) ...[
          _ErrorRow(failure),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => setState(() {
              _phase = _JoinPhase.code;
              _failure = null;
            }),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Try again'),
          ),
          TextButton(
            onPressed: _backToBrowsing,
            child: const Text('Back'),
          ),
        ] else ...[
          _StatusRow(text: _linkText()),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {
              _releaseSession();
              _backToBrowsing();
            },
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }

  /// What the link is doing, in the user's terms. A busy room is NOT an error:
  /// the host is mid-match (or still reaping a half-open socket from a previous
  /// guest), and the client keeps retrying on its own.
  String _linkText() => switch (_linkState.status) {
        GuestConnectionStatus.busy => 'Room in use — waiting…',
        GuestConnectionStatus.reconnecting => 'Lost the connection — retrying…',
        GuestConnectionStatus.connected => 'Connected — starting the match…',
        GuestConnectionStatus.failed => 'Could not join.',
        GuestConnectionStatus.connecting => 'Connecting…',
      };
}

// --- shared ------------------------------------------------------------------

/// The settings a launch runs on: read ONCE, at the top of `_launch`, and
/// AWAITED rather than peeked at.
///
/// Both tabs pass this one snapshot on to the analytics event and to
/// [_openGame], so the tutor flag that is reported and the board that is built
/// cannot disagree. Awaited, because nothing on this screen watches the stream:
/// a peek would hand out the defaults for as long as the first value is in
/// flight, and Nearby is the FASTEST board to reach from a cold start — two
/// taps — so that window is precisely where a user's "tutor off" would be
/// ignored. A settings store that cannot be read at all falls back to the
/// defaults, the same as everywhere else.
///
/// (The host tab's `initState` still peeks, deliberately: it seeds the
/// match-length selector, which the user then looks at and can change before it
/// means anything.)
Future<AppSettings> _launchSettings(WidgetRef ref) async {
  try {
    return await ref.read(settingsProvider.future);
  } catch (_) {
    return AppSettings.defaults;
  }
}

/// Push the game screen with the full production parameter set, pinned to the
/// local side. Shared by both tabs so host and guest get an identical board.
Future<void> _openGame({
  required BuildContext context,
  required WidgetRef ref,
  required NetMatchController controller,
  required Future<int> matchIdFuture,
  required String opponentLabel,
  required AppSettings settings,
}) async {
  // The tutor is local and read-only on the LAN exactly as it is online. It
  // marks BOTH columns of the score sheet — the peer's completed moves are
  // assessed on the same terms as your own — but everything PROSPECTIVE (hints,
  // cube advice) is offered for the local player's own pending decision alone.
  // Retrospective for both, prospective for you: that is what keeps it fair,
  // and why an off-switch can only cost you help. Whether it is built at all is
  // the user's setting — see [AppSettings.networkedTutorEnabled] for what Auto
  // means here — and a null tutor is what turns every tutor surface off on the
  // board.
  final tutor = settings.networkedTutorEnabled
      ? TutorService(ref.read(engineFacadeProvider))
      : null;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => GameScreen(
        key: ValueKey(controller),
        controller: controller,
        orientation: controller.localSide == Player.white
            ? BoardOrientationMode.fixedWhite
            : BoardOrientationMode.fixedBlack,
        tutor: tutor,
        analytics: ref.read(appAnalyticsProvider),
        analyticsMode: AnalyticsModes.lan,
        opponentLabel: opponentLabel,
        opponentDetail: 'Nearby',
        persistedMatchId: matchIdFuture,
        timings: settings.timings,
        interactionOptions: BoardInteractionOptions(
          showHighlights: settings.showHighlights,
          enableDrag: settings.enableDrag,
          enableCombinedTaps: settings.enableCombinedTaps,
        ),
        showScoring: settings.showScoring,
        // A targeted single-column latch, not a save of this long-lived
        // `settings` snapshot — see [latchDragHintShown].
        dragHintShown: settings.dragHintShown,
        onDragHintShown: () => latchDragHintShown(ref),
      ),
    ),
  );
}

/// The header calls the other side by name where there is one, but the score
/// line is tight — so a device name is trimmed to something that fits.
String _shortName(String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return 'Opp';
  // Rune-safe, and ellipsised so a trimmed name reads as trimmed rather than as
  // a differently-spelled one — see [truncateForDisplay].
  return truncateForDisplay(trimmed, 10);
}

/// The common scroll/width frame both tabs sit in.
class _TabBody extends StatelessWidget {
  const _TabBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled card, matching the online screen's sections.
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

/// A spinner and a line of copy — "still working, nothing is wrong".
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Flexible(child: Text(text)),
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
