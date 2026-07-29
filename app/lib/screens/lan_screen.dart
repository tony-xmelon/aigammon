import 'dart:async';
import 'dart:io' show SocketException;

import 'package:backgammon_core/backgammon_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lan_play/lan_play.dart';
import 'package:match_transport/match_transport.dart';

import '../board/board_view.dart';
import '../data/app_settings.dart';
import '../data/match_repository.dart';
import '../data/persistence_hooks.dart';
import '../data/settings_repository.dart';
import '../engine/engine_provider.dart';
import '../lan/lan_transport.dart';
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
  Widget build(BuildContext context) {
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
    // Leaving the screen releases the port, the beacon and the match log. The
    // future is deliberately unawaited: dispose cannot wait, and stop() is
    // self-contained.
    unawaited(_session?.stop());
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
      unawaited(_lookupAddress(transport));
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
    unawaited(_launch(session));
  }

  /// Build the host's controller, wait for game 1 to fold, and open the board.
  Future<void> _launch(HostSession session) async {
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
    final controller = session.controller(
      persistence: RepositoryPersistence(repo, matchIdFuture),
    );
    unawaited(controller.playMatch());
    await controller.ready;
    if (!mounted || !identical(_session, session) || !controller.isReady) {
      controller.disposeController();
      return;
    }
    await _openGame(
      context: context,
      ref: ref,
      controller: controller,
      matchIdFuture: matchIdFuture,
      opponentLabel: _shortName(session.guestName),
    );
    // Back from the game: the controller goes first (and takes its transport
    // with it), then the port, the beacon and the match log; the tab resets to
    // its form.
    controller.disposeController();
    await _stopHosting();
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
    return [
      _SectionCard(
        title: 'Waiting for a player',
        children: [
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
            onPressed: () => unawaited(_stopHosting()),
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
    _sweep = Timer.periodic(_probeInterval, (_) => unawaited(_probe()));
    // A microtask, not a direct call: this runs from initState and from
    // didUpdateWidget, where the first thing [_probe] does — setState — is not
    // yet legal.
    scheduleMicrotask(() {
      if (mounted) unawaited(_probe());
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
    unawaited(_connect(_target!, code));
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
    unawaited(_connect(
      _Target(name: address, address: address, port: port),
      code,
    ));
  }

  bool _validCode(String code) =>
      code.length == 4 && int.tryParse(code) != null;

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
      unawaited(session.dispose());
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
    unawaited(sub?.cancel());
    unawaited(session?.dispose());
  }

  /// Build the guest's controller and open the board.
  Future<void> _launch(GuestSession session) async {
    final repo = ref.read(matchRepositoryProvider);
    final side = session.localSide;
    final matchIdFuture = repo.startMatch(
      matchLength: session.config.length,
      mode: 'lan',
      whiteType: side == Player.white ? 'human' : 'remote',
      blackType: side == Player.black ? 'human' : 'remote',
    );
    final controller = session.controller(
      persistence: RepositoryPersistence(repo, matchIdFuture),
    );
    unawaited(controller.playMatch());
    await controller.ready;
    if (!mounted || !identical(_session, session) || !controller.isReady) {
      controller.disposeController();
      _releaseSession();
      return;
    }
    await _openGame(
      context: context,
      ref: ref,
      controller: controller,
      matchIdFuture: matchIdFuture,
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
            _hostsCard(),
            const SizedBox(height: 16),
            _manualCard(),
          ],
        _JoinPhase.code => [_codeCard()],
        _JoinPhase.connecting => [_connectingCard()],
      },
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

/// Push the game screen with the full production parameter set, pinned to the
/// local side. Shared by both tabs so host and guest get an identical board.
Future<void> _openGame({
  required BuildContext context,
  required WidgetRef ref,
  required NetMatchController controller,
  required Future<int> matchIdFuture,
  required String opponentLabel,
}) async {
  final settings = ref.read(settingsProvider).valueOrNull ?? AppSettings.defaults;
  // The tutor stays available on the LAN exactly as it does online: it keys its
  // post-move chips on the local side, and the peer is a person, not the AI.
  final tutor = TutorService(ref.read(engineFacadeProvider));
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => GameScreen(
        key: ValueKey(controller),
        controller: controller,
        orientation: controller.localSide == Player.white
            ? BoardOrientationMode.fixedWhite
            : BoardOrientationMode.fixedBlack,
        tutor: tutor,
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
        dragHintShown: settings.dragHintShown,
        onDragHintShown: () => ref
            .read(settingsRepositoryProvider)
            .save(settings.copyWith(dragHintShown: true)),
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
