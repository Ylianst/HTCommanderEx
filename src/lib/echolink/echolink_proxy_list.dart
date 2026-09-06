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
// echolink_proxy_list.dart - Fetches and parses the public EchoLink proxy list.
//
// The EchoLink project publishes the list of public proxies as an HTML table at
// www.echolink.org/proxylist.jsp. Only proxies that reported status within the
// last ~10 minutes are listed; each row carries a Ready/Busy status (a proxy
// serves only one client at a time). The parser is pure so it can be unit
// tested against captured HTML; the fetch helper is a thin http wrapper.
//

import 'dart:async';

import 'package:http/http.dart' as http;

/// URL of the public EchoLink proxy list (HTML table).
const String echoLinkPublicProxyListUrl =
    'https://www.echolink.org/proxylist.jsp';

/// One row of the public proxy list.
class EchoLinkProxyListEntry {
  /// Owner-assigned proxy name (e.g. "W3KIT #42").
  final String name;

  /// Host address (IPv4 or DNS name).
  final String host;

  /// TCP port the proxy listens on (usually 8100).
  final int port;

  /// True when the proxy reported itself Ready (free); false when Busy.
  final bool ready;

  /// Proxy software version string (e.g. "1.2.5c").
  final String version;

  /// Free-text comment from the proxy owner.
  final String comment;

  const EchoLinkProxyListEntry({
    required this.name,
    required this.host,
    required this.port,
    required this.ready,
    this.version = '',
    this.comment = '',
  });

  @override
  String toString() =>
      'EchoLinkProxyListEntry($name, $host:$port, ${ready ? 'Ready' : 'Busy'})';
}

final RegExp _rowPattern =
    RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
final RegExp _cellPattern =
    RegExp(r'<td[^>]*>(.*?)</td>', dotAll: true, caseSensitive: false);
final RegExp _tagPattern = RegExp(r'<[^>]*>');

/// Parses the proxylist.jsp HTML into proxy rows. Rows that do not look like a
/// proxy entry (header row, surrounding markup) are skipped. Never throws.
List<EchoLinkProxyListEntry> parseEchoLinkProxyList(String html) {
  final List<EchoLinkProxyListEntry> out = <EchoLinkProxyListEntry>[];
  for (final RegExpMatch row in _rowPattern.allMatches(html)) {
    final List<String> cells = <String>[
      for (final RegExpMatch c in _cellPattern.allMatches(row.group(1) ?? ''))
        _stripCell(c.group(1) ?? ''),
    ];
    // Columns: Name | Host | Port | Last Updated | Status | Ver | Comments.
    if (cells.length < 5) continue;
    final int? port = int.tryParse(cells[2]);
    if (port == null) continue;
    final String status = cells[4].toLowerCase();
    final bool ready = status == 'ready';
    if (!ready && status != 'busy') continue; // Not a proxy row.
    if (cells[1].isEmpty) continue;
    out.add(EchoLinkProxyListEntry(
      name: cells[0],
      host: cells[1],
      port: port,
      ready: ready,
      version: cells.length > 5 ? cells[5] : '',
      comment: cells.length > 6 ? cells[6] : '',
    ));
  }
  return out;
}

/// Returns only the Ready proxies from [all].
List<EchoLinkProxyListEntry> readyEchoLinkProxies(
        List<EchoLinkProxyListEntry> all) =>
    all.where((EchoLinkProxyListEntry e) => e.ready).toList(growable: false);

/// Fetches and parses the public proxy list. Throws on HTTP/network error.
Future<List<EchoLinkProxyListEntry>> fetchEchoLinkProxyList({
  http.Client? client,
  Uri? url,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final http.Client c = client ?? http.Client();
  try {
    final http.Response resp = await c
        .get(url ?? Uri.parse(echoLinkPublicProxyListUrl))
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw StateError('Proxy list HTTP ${resp.statusCode}');
    }
    return parseEchoLinkProxyList(resp.body);
  } finally {
    if (client == null) c.close();
  }
}

String _stripCell(String raw) {
  final String noTags = raw.replaceAll(_tagPattern, '');
  return noTags
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();
}
