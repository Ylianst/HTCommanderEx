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
// echolink_proxy_list_test.dart - Parsing the public EchoLink proxy list and
// automatic proxy selection with failover.
//

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/echolink/echolink_network.dart';
import 'package:htcommander/echolink/echolink_proxy_auto_network.dart';
import 'package:htcommander/echolink/echolink_proxy_list.dart';

const String _sampleHtml = '''
<table>
<tr><td>Name</td><td>Host Address</td><td>Port</td><td>Last Updated (UTC)</td><td>Status</td><td>Ver</td><td>Comments</td></tr>
<tr><td>W3KIT #42</td><td>elp-42.w3kit.net</td><td>8100</td><td>18:37</td><td>Ready</td><td>1.2.5c</td><td>Silver Spring, MD</td></tr>
<tr><td>K9WAW #9</td><td>44.72.16.254</td><td>8100</td><td>18:32</td><td>Busy</td><td>1.2.5c</td><td>Chicago, IL -- <a href="https://x">XenSpec</a></td></tr>
<tr><td>PE1CHL</td><td>185.103.159.238</td><td>8100</td><td>18:31</td><td>Ready</td><td>1.2.5c</td><td>Amsterdam &amp; NL</td></tr>
</table>
''';

class _FakeNet implements EchoLinkNetwork {
  final bool failOpen;
  final StreamController<EchoLinkDatagram> audio =
      StreamController<EchoLinkDatagram>.broadcast();
  final StreamController<EchoLinkDatagram> control =
      StreamController<EchoLinkDatagram>.broadcast();
  final List<List<Object>> sentAudio = <List<Object>>[];
  bool opened = false;
  bool closed = false;

  _FakeNet({this.failOpen = false});

  @override
  Stream<EchoLinkDatagram> get audioIn => audio.stream;
  @override
  Stream<EchoLinkDatagram> get controlIn => control.stream;

  @override
  Future<void> open() async {
    if (failOpen) throw StateError('boom');
    opened = true;
  }

  @override
  void sendAudio(String host, Uint8List data) =>
      sentAudio.add(<Object>[host, data]);
  @override
  void sendControl(String host, Uint8List data) {}

  @override
  Future<Uint8List> directoryExchange(List<String> servers, Uint8List request,
          {int? maxBytes}) async =>
      Uint8List(0);

  @override
  Future<void> close() async {
    closed = true;
    if (!audio.isClosed) await audio.close();
    if (!control.isClosed) await control.close();
  }
}

void main() {
  group('parseEchoLinkProxyList', () {
    test('parses rows, skips header, decodes status/entities', () {
      final List<EchoLinkProxyListEntry> list =
          parseEchoLinkProxyList(_sampleHtml);
      expect(list.length, 3);
      expect(list[0].name, 'W3KIT #42');
      expect(list[0].host, 'elp-42.w3kit.net');
      expect(list[0].port, 8100);
      expect(list[0].ready, isTrue);
      expect(list[1].ready, isFalse); // Busy
      expect(list[1].comment, contains('XenSpec')); // tags stripped
      expect(list[2].comment, 'Amsterdam & NL'); // entity decoded
    });

    test('readyEchoLinkProxies keeps only Ready rows', () {
      final List<EchoLinkProxyListEntry> ready =
          readyEchoLinkProxies(parseEchoLinkProxyList(_sampleHtml));
      expect(ready.length, 2);
      expect(ready.every((EchoLinkProxyListEntry e) => e.ready), isTrue);
    });

    test('ignores malformed / non-proxy rows', () {
      expect(parseEchoLinkProxyList('<tr><td>x</td><td>y</td></tr>'), isEmpty);
      expect(parseEchoLinkProxyList(''), isEmpty);
    });
  });

  group('AutoEchoLinkProxyNetwork', () {
    EchoLinkProxyListEntry entry(String host, {bool ready = true}) =>
        EchoLinkProxyListEntry(
            name: host, host: host, port: 8100, ready: ready);

    test('skips Busy, retries past failing proxies, connects to a Ready one',
        () async {
      final _FakeNet good = _FakeNet();
      final Map<String, _FakeNet> nets = <String, _FakeNet>{
        'bad1': _FakeNet(failOpen: true),
        'bad2': _FakeNet(failOpen: true),
        'good': good,
      };
      final AutoEchoLinkProxyNetwork auto = AutoEchoLinkProxyNetwork(
        callsign: 'N0CALL',
        listProvider: () async => <EchoLinkProxyListEntry>[
          entry('busy', ready: false),
          entry('bad1'),
          entry('bad2'),
          entry('good'),
        ],
        proxyFactory: (EchoLinkProxyListEntry e) => nets[e.host]!,
      );

      await auto.open();
      expect(auto.connectedProxy?.host, 'good');
      expect(good.opened, isTrue);

      // Forwarding works through the chosen delegate.
      auto.sendAudio('1.2.3.4', Uint8List.fromList(<int>[1, 2]));
      expect(good.sentAudio.single[0], '1.2.3.4');

      // Inbound audio from the delegate is piped to the auto network's stream.
      final Future<EchoLinkDatagram> first = auto.audioIn.first;
      good.audio.add(EchoLinkDatagram('5.6.7.8', 5198,
          Uint8List.fromList(<int>[9])));
      final EchoLinkDatagram dg = await first;
      expect(dg.host, '5.6.7.8');

      await auto.close();
      expect(good.closed, isTrue);
    });

    test('throws when no Ready proxies are available', () async {
      final AutoEchoLinkProxyNetwork auto = AutoEchoLinkProxyNetwork(
        callsign: 'N0CALL',
        listProvider: () async => <EchoLinkProxyListEntry>[
          entry('busy', ready: false),
        ],
        proxyFactory: (EchoLinkProxyListEntry e) => _FakeNet(),
      );
      await expectLater(auto.open(), throwsA(isA<StateError>()));
    });

    test('throws when every candidate fails to connect', () async {
      final AutoEchoLinkProxyNetwork auto = AutoEchoLinkProxyNetwork(
        callsign: 'N0CALL',
        listProvider: () async => <EchoLinkProxyListEntry>[
          entry('a'),
          entry('b'),
        ],
        proxyFactory: (EchoLinkProxyListEntry e) => _FakeNet(failOpen: true),
      );
      await expectLater(auto.open(), throwsA(isA<StateError>()));
    });
  });
}
