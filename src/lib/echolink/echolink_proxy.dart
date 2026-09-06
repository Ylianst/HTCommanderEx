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
// echolink_proxy.dart - EchoLink Proxy protocol codec (pure, no sockets).
//
// Port of reference/svxlink/src/echolib/EchoLinkProxy.cpp and
// reference/svxlink/src/doc/echolink_proxy_protocol.txt. An EchoLink proxy
// tunnels the two EchoLink UDP ports (5198 audio / 5199 control) and the
// directory-server TCP port (5200) over a single TCP connection to the proxy,
// which is what lets EchoLink work from networks that block inbound UDP (hotel
// LANs, and mobile carriers behind CGNAT). This file only encodes/decodes the
// wire bytes; the socket transport lives in echolink_proxy_network.dart so this
// logic can be unit-tested without real sockets.
//

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Default TCP port an EchoLink proxy listens on.
const int echoLinkProxyDefaultPort = 8100;

/// Conventional password for *public* proxies (case-insensitive on the wire).
const String echoLinkProxyPublicPassword = 'PUBLIC';

/// Size of the credentials nonce the proxy sends right after the TCP connect.
const int echoLinkProxyNonceSize = 8;

/// Fixed proxy message header: 1 byte type + 4 byte address + 4 byte length.
const int echoLinkProxyHeaderSize = 1 + 4 + 4;

/// SYSTEM message data byte: the client provided the wrong password.
const int echoLinkProxySystemBadPassword = 1;

/// SYSTEM message data byte: the client is not authorized to use this proxy.
const int echoLinkProxySystemAccessDenied = 2;

/// Proxy message block types (wire code in parentheses).
enum EchoLinkProxyMsgType {
  tcpOpen(1),
  tcpData(2),
  tcpClose(3),
  tcpStatus(4),
  udpData(5),
  udpControl(6),
  system(7);

  const EchoLinkProxyMsgType(this.code);

  /// The 1-byte wire value for this message type.
  final int code;

  /// Maps a wire byte to a type, or null if unknown.
  static EchoLinkProxyMsgType? fromCode(int code) {
    for (final EchoLinkProxyMsgType t in EchoLinkProxyMsgType.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// A decoded proxy message block.
class EchoLinkProxyMessage {
  /// The message type.
  final EchoLinkProxyMsgType type;

  /// Remote peer IPv4 address in dotted form (e.g. "1.2.3.4"); "0.0.0.0" when
  /// the address field is unused (TCP_DATA/TCP_CLOSE).
  final String ip;

  /// Payload bytes (may be empty).
  final Uint8List data;

  const EchoLinkProxyMessage(this.type, this.ip, this.data);
}

/// Result of [parseEchoLinkProxyMessages]: the fully-decoded messages and the
/// number of bytes consumed from the front of the input (any trailing partial
/// message is left for the caller to re-feed once more bytes arrive).
class EchoLinkProxyParseResult {
  final List<EchoLinkProxyMessage> messages;
  final int consumed;
  const EchoLinkProxyParseResult(this.messages, this.consumed);
}

/// Encodes a single proxy message block. [ip] is the remote peer address in
/// dotted IPv4 form; pass "0.0.0.0" (the default) when the address is unused.
Uint8List encodeEchoLinkProxyMessage(
  EchoLinkProxyMsgType type, {
  String ip = '0.0.0.0',
  Uint8List? data,
}) {
  final Uint8List payload = data ?? Uint8List(0);
  final Uint8List addr = ipv4ToBytes(ip);
  final Uint8List out = Uint8List(echoLinkProxyHeaderSize + payload.length);
  out[0] = type.code;
  // Address: the 4 IPv4 octets in a.b.c.d order (little-endian s_addr).
  out[1] = addr[0];
  out[2] = addr[1];
  out[3] = addr[2];
  out[4] = addr[3];
  // Length: 32-bit little-endian.
  final int len = payload.length;
  out[5] = len & 0xff;
  out[6] = (len >> 8) & 0xff;
  out[7] = (len >> 16) & 0xff;
  out[8] = (len >> 24) & 0xff;
  out.setRange(echoLinkProxyHeaderSize, out.length, payload);
  return out;
}

/// Parses as many complete proxy message blocks as [buf] contains.
EchoLinkProxyParseResult parseEchoLinkProxyMessages(Uint8List buf) {
  final List<EchoLinkProxyMessage> messages = <EchoLinkProxyMessage>[];
  int off = 0;
  while (buf.length - off >= echoLinkProxyHeaderSize) {
    final int typeCode = buf[off];
    final String ip =
        '${buf[off + 1]}.${buf[off + 2]}.${buf[off + 3]}.${buf[off + 4]}';
    final int len = buf[off + 5] |
        (buf[off + 6] << 8) |
        (buf[off + 7] << 16) |
        (buf[off + 8] << 24);
    if (len < 0 || buf.length - off - echoLinkProxyHeaderSize < len) {
      break; // Incomplete payload; wait for more bytes.
    }
    final int dataStart = off + echoLinkProxyHeaderSize;
    final Uint8List data =
        Uint8List.sublistView(buf, dataStart, dataStart + len);
    final EchoLinkProxyMsgType? type = EchoLinkProxyMsgType.fromCode(typeCode);
    if (type != null) {
      messages.add(EchoLinkProxyMessage(type, ip, Uint8List.fromList(data)));
    }
    off = dataStart + len;
  }
  return EchoLinkProxyParseResult(messages, off);
}

/// Builds the authentication response for the 8-byte [nonce] the proxy sends
/// after connect: the callsign, a newline, then the raw 16-byte MD5 digest of
/// the upper-cased password concatenated with the nonce. An empty password is
/// treated as [echoLinkProxyPublicPassword] (the public-proxy convention).
Uint8List echoLinkProxyAuthResponse(
    String callsign, String password, Uint8List nonce) {
  final String pw =
      (password.isEmpty ? echoLinkProxyPublicPassword : password).toUpperCase();
  final BytesBuilder toDigest = BytesBuilder()
    ..add(latin1.encode(pw))
    ..add(nonce);
  final List<int> digest = md5.convert(toDigest.toBytes()).bytes;
  final BytesBuilder out = BytesBuilder()
    ..add(latin1.encode(callsign))
    ..addByte(0x0a) // '\n'
    ..add(digest);
  return out.toBytes();
}

/// Converts a dotted IPv4 string to 4 bytes (a.b.c.d order). Returns zeros for
/// malformed input.
Uint8List ipv4ToBytes(String ip) {
  final Uint8List out = Uint8List(4);
  final List<String> parts = ip.split('.');
  if (parts.length != 4) return out;
  for (int i = 0; i < 4; i++) {
    final int? v = int.tryParse(parts[i]);
    if (v == null || v < 0 || v > 255) return Uint8List(4);
    out[i] = v;
  }
  return out;
}
