/*
Copyright 2026 Ylian Saint-Hilaire

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

//
// echolink_proxy_auto_network.dart - Automatic public-proxy EchoLinkNetwork.
//
// Fetches the public EchoLink proxy list, keeps the Ready proxies, shuffles
// them, and tries connecting to each in turn until one authenticates -- so the
// user never has to pick a proxy by hand. Public proxies serve one client at a
// time and a Ready proxy can be taken by someone else in the moment between the
// list snapshot and our connect, so failover across several candidates is
// essential. Once connected it simply delegates to the chosen
// EchoLinkProxyNetwork.
//

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'echolink_network.dart';
import 'echolink_proxy.dart';
import 'echolink_proxy_list.dart';
import 'echolink_proxy_network.dart';

/// Supplies the candidate proxy list (injected so tests avoid real HTTP).
typedef ProxyListProvider = Future<List<EchoLinkProxyListEntry>> Function();

/// Builds a transport for a chosen proxy (injected so tests avoid real sockets).
typedef ProxyNetworkFactory = EchoLinkNetwork Function(
    EchoLinkProxyListEntry entry);

class AutoEchoLinkProxyNetwork implements EchoLinkNetwork {
  final String callsign;
  final String password;

  /// Maximum number of Ready proxies to try before giving up.
  final int maxAttempts;

  final ProxyListProvider _listProvider;
  final ProxyNetworkFactory _proxyFactory;
  final Random _random;

  /// Called with a human-readable note for each connection attempt, so the
  /// manager can surface progress (e.g. to the Debug tab).
  void Function(String message)? onDiagnostic;

  EchoLinkNetwork? _active;
  EchoLinkProxyListEntry? _activeEntry;
  StreamSubscription<EchoLinkDatagram>? _audioSub;
  StreamSubscription<EchoLinkDatagram>? _controlSub;

  final StreamController<EchoLinkDatagram> _audioIn =
      StreamController<EchoLinkDatagram>.broadcast();
  final StreamController<EchoLinkDatagram> _controlIn =
      StreamController<EchoLinkDatagram>.broadcast();

  AutoEchoLinkProxyNetwork({
    required this.callsign,
    this.password = echoLinkProxyPublicPassword,
    this.maxAttempts = 8,
    Duration perAttemptTimeout = const Duration(seconds: 6),
    ProxyListProvider? listProvider,
    ProxyNetworkFactory? proxyFactory,
    Random? random,
  })  : _listProvider = listProvider ?? fetchEchoLinkProxyList,
        _proxyFactory = proxyFactory ??
            ((EchoLinkProxyListEntry e) => EchoLinkProxyNetwork(
                  proxyHost: e.host,
                  proxyPort: e.port,
                  callsign: callsign,
                  password: password,
                  connectTimeout: perAttemptTimeout,
                )),
        _random = random ?? Random();

  /// The proxy that was ultimately connected, if any (for logging/UI).
  EchoLinkProxyListEntry? get connectedProxy => _activeEntry;

  @override
  Stream<EchoLinkDatagram> get audioIn => _audioIn.stream;

  @override
  Stream<EchoLinkDatagram> get controlIn => _controlIn.stream;

  @override
  Future<void> open() async {
    if (_active != null) return;

    final List<EchoLinkProxyListEntry> ready =
        readyEchoLinkProxies(await _listProvider());
    if (ready.isEmpty) {
      throw StateError('No Ready public EchoLink proxies are available');
    }
    ready.shuffle(_random);
    final int attempts = ready.length < maxAttempts ? ready.length : maxAttempts;

    Object? lastError;
    for (int i = 0; i < attempts; i++) {
      final EchoLinkProxyListEntry entry = ready[i];
      onDiagnostic
          ?.call('Trying EchoLink proxy ${entry.name} (${entry.host}:${entry.port})');
      final EchoLinkNetwork delegate = _proxyFactory(entry);
      try {
        await delegate.open();
        _active = delegate;
        _activeEntry = entry;
        _audioSub = delegate.audioIn.listen(_audioIn.add);
        _controlSub = delegate.controlIn.listen(_controlIn.add);
        onDiagnostic?.call('Connected to EchoLink proxy ${entry.name}');
        return;
      } catch (e) {
        lastError = e;
        try {
          await delegate.close();
        } catch (_) {}
      }
    }
    throw StateError(
        'Could not connect to any public EchoLink proxy (tried $attempts): $lastError');
  }

  @override
  void sendAudio(String host, Uint8List data) => _active?.sendAudio(host, data);

  @override
  void sendControl(String host, Uint8List data) =>
      _active?.sendControl(host, data);

  @override
  Future<Uint8List> directoryExchange(List<String> servers, Uint8List request,
      {int? maxBytes}) {
    final EchoLinkNetwork? active = _active;
    if (active == null) {
      throw StateError('EchoLink proxy not connected');
    }
    return active.directoryExchange(servers, request, maxBytes: maxBytes);
  }

  @override
  Future<void> close() async {
    await _audioSub?.cancel();
    await _controlSub?.cancel();
    _audioSub = null;
    _controlSub = null;
    final EchoLinkNetwork? active = _active;
    _active = null;
    _activeEntry = null;
    try {
      await active?.close();
    } catch (_) {}
    if (!_audioIn.isClosed) await _audioIn.close();
    if (!_controlIn.isClosed) await _controlIn.close();
  }
}
