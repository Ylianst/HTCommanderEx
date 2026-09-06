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
// echolink_proxy_test.dart - EchoLink Proxy protocol codec tests. Verifies the
// message framing, streaming parser and credential digest against the wire
// format in reference/svxlink/src/echolib/EchoLinkProxy.cpp.
//

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/echolink/echolink_proxy.dart';

void main() {
  group('ipv4ToBytes', () {
    test('parses a dotted address in a.b.c.d order', () {
      expect(ipv4ToBytes('1.2.3.4'), <int>[1, 2, 3, 4]);
      expect(ipv4ToBytes('192.168.0.255'), <int>[192, 168, 0, 255]);
    });

    test('returns zeros for malformed input', () {
      expect(ipv4ToBytes(''), <int>[0, 0, 0, 0]);
      expect(ipv4ToBytes('1.2.3'), <int>[0, 0, 0, 0]);
      expect(ipv4ToBytes('1.2.3.256'), <int>[0, 0, 0, 0]);
      expect(ipv4ToBytes('a.b.c.d'), <int>[0, 0, 0, 0]);
    });
  });

  group('encodeEchoLinkProxyMessage', () {
    test('header layout: type, IP octets, little-endian length', () {
      final Uint8List msg = encodeEchoLinkProxyMessage(
        EchoLinkProxyMsgType.udpData,
        ip: '10.20.30.40',
        data: Uint8List.fromList(<int>[0xaa, 0xbb, 0xcc]),
      );
      expect(msg[0], EchoLinkProxyMsgType.udpData.code); // 5
      expect(msg.sublist(1, 5), <int>[10, 20, 30, 40]);
      // Length 3 as 32-bit little-endian.
      expect(msg.sublist(5, 9), <int>[3, 0, 0, 0]);
      expect(msg.sublist(9), <int>[0xaa, 0xbb, 0xcc]);
    });

    test('empty payload and default address', () {
      final Uint8List msg =
          encodeEchoLinkProxyMessage(EchoLinkProxyMsgType.tcpClose);
      expect(msg.length, echoLinkProxyHeaderSize);
      expect(msg[0], EchoLinkProxyMsgType.tcpClose.code); // 3
      expect(msg.sublist(1, 5), <int>[0, 0, 0, 0]);
      expect(msg.sublist(5, 9), <int>[0, 0, 0, 0]);
    });

    test('encodes a 300-byte payload length correctly', () {
      final Uint8List payload = Uint8List(300);
      final Uint8List msg = encodeEchoLinkProxyMessage(
        EchoLinkProxyMsgType.tcpData,
        data: payload,
      );
      // 300 = 0x12C -> LE bytes 0x2C, 0x01, 0x00, 0x00.
      expect(msg.sublist(5, 9), <int>[0x2c, 0x01, 0x00, 0x00]);
      expect(msg.length, echoLinkProxyHeaderSize + 300);
    });
  });

  group('parseEchoLinkProxyMessages', () {
    test('round-trips an encoded message', () {
      final Uint8List enc = encodeEchoLinkProxyMessage(
        EchoLinkProxyMsgType.udpControl,
        ip: '5.6.7.8',
        data: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      );
      final EchoLinkProxyParseResult res = parseEchoLinkProxyMessages(enc);
      expect(res.consumed, enc.length);
      expect(res.messages.length, 1);
      expect(res.messages[0].type, EchoLinkProxyMsgType.udpControl);
      expect(res.messages[0].ip, '5.6.7.8');
      expect(res.messages[0].data, <int>[1, 2, 3, 4, 5]);
    });

    test('parses several concatenated messages', () {
      final BytesBuilder b = BytesBuilder()
        ..add(encodeEchoLinkProxyMessage(EchoLinkProxyMsgType.tcpStatus,
            data: Uint8List.fromList(<int>[0, 0, 0, 0])))
        ..add(encodeEchoLinkProxyMessage(EchoLinkProxyMsgType.udpData,
            ip: '1.1.1.1', data: Uint8List.fromList(<int>[9])));
      final EchoLinkProxyParseResult res =
          parseEchoLinkProxyMessages(b.toBytes());
      expect(res.messages.length, 2);
      expect(res.messages[0].type, EchoLinkProxyMsgType.tcpStatus);
      expect(res.messages[1].type, EchoLinkProxyMsgType.udpData);
      expect(res.messages[1].ip, '1.1.1.1');
    });

    test('leaves a trailing partial message unconsumed', () {
      final Uint8List enc = encodeEchoLinkProxyMessage(
        EchoLinkProxyMsgType.tcpData,
        data: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      // Feed everything except the last two payload bytes.
      final Uint8List partial = enc.sublist(0, enc.length - 2);
      final EchoLinkProxyParseResult res = parseEchoLinkProxyMessages(partial);
      expect(res.messages, isEmpty);
      expect(res.consumed, 0);
    });

    test('skips unknown message types but still advances', () {
      // Hand-craft a message with an unknown type code (99), 0-length payload,
      // followed by a valid tcpClose.
      final BytesBuilder b = BytesBuilder()
        ..add(<int>[99, 0, 0, 0, 0, 0, 0, 0, 0])
        ..add(encodeEchoLinkProxyMessage(EchoLinkProxyMsgType.tcpClose));
      final EchoLinkProxyParseResult res =
          parseEchoLinkProxyMessages(b.toBytes());
      expect(res.consumed, b.toBytes().length);
      expect(res.messages.length, 1);
      expect(res.messages[0].type, EchoLinkProxyMsgType.tcpClose);
    });
  });

  group('echoLinkProxyAuthResponse', () {
    test('callsign + newline + MD5(uppercase password + nonce)', () {
      final Uint8List nonce = Uint8List.fromList(latin1.encode('12345678'));
      final Uint8List resp =
          echoLinkProxyAuthResponse('N0CALL', 'public', nonce);
      final List<int> expected = <int>[
        ...latin1.encode('N0CALL'),
        0x0a,
        // MD5("PUBLIC12345678")
        211, 216, 251, 232, 104, 154, 198, 170,
        192, 207, 55, 225, 132, 49, 79, 153,
      ];
      expect(resp, expected);
    });

    test('empty password is treated as PUBLIC', () {
      final Uint8List nonce = Uint8List.fromList(latin1.encode('12345678'));
      expect(
        echoLinkProxyAuthResponse('N0CALL', '', nonce),
        echoLinkProxyAuthResponse('N0CALL', 'PUBLIC', nonce),
      );
    });
  });
}
