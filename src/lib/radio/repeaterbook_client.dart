/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License").
See http://www.apache.org/licenses/LICENSE-2.0

Ported from the C# `HTCommander.Core.RepeaterBookClient`.
*/

import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'radio_models.dart';

/// Which RepeaterBook directory to query.
enum RepeaterBookService { amateur, gmrs }

/// A RepeaterBook search. Mirrors the documented `api/export.php` query terms.
class RepeaterBookQuery {
  RepeaterBookService service;
  String country;
  String state;
  String county;
  String city;
  String callsign;
  String frequency;

  /// Operating mode filter (analog / DMR / NXDN / P25 / tetra). Amateur only.
  String mode;

  RepeaterBookQuery({
    this.service = RepeaterBookService.amateur,
    this.country = '',
    this.state = '',
    this.county = '',
    this.city = '',
    this.callsign = '',
    this.frequency = '',
    this.mode = '',
  });
}

/// Thrown when a RepeaterBook request fails. [rateLimited] is set on HTTP 429.
class RepeaterBookException implements Exception {
  final String message;
  final bool rateLimited;
  RepeaterBookException(this.message, {this.rateLimited = false});
  @override
  String toString() => message;
}

/// One row from a RepeaterBook export. Field names mirror the API JSON (which
/// returns most values as strings). Only the fields we use are declared.
class RepeaterBookResult {
  final String frequency; // output (repeater TX / your RX), MHz
  final String inputFreq; // input  (repeater RX / your TX), MHz
  final String pl; // uplink CTCSS/DCS — what you transmit
  final String tsq; // downlink tone (ignored: RX squelch off)
  final String nearestCity;
  final String landmark;
  final String county;
  final String state;
  final String country;
  final String callsign;
  final String lat;
  final String long;
  final String fmAnalog;
  final String dmr;
  final String operationalStatus;
  final String use; // "OPEN" / "PRIVATE" / "CLOSED"
  final String fmBandwidth; // e.g. "25.0 kHz" / "12.5 kHz"

  RepeaterBookResult({
    this.frequency = '',
    this.inputFreq = '',
    this.pl = '',
    this.tsq = '',
    this.nearestCity = '',
    this.landmark = '',
    this.county = '',
    this.state = '',
    this.country = '',
    this.callsign = '',
    this.lat = '',
    this.long = '',
    this.fmAnalog = '',
    this.dmr = '',
    this.operationalStatus = '',
    this.use = '',
    this.fmBandwidth = '',
  });

  factory RepeaterBookResult.fromJson(Map<String, dynamic> j) {
    // RepeaterBook is inconsistent: a field is a quoted string on one endpoint
    // and a bare number on another. Coerce every value to a trimmed string.
    String s(String key) {
      final v = j[key];
      if (v == null) return '';
      return v.toString().trim();
    }

    return RepeaterBookResult(
      frequency: s('Frequency'),
      inputFreq: s('Input Freq'),
      pl: s('PL'),
      tsq: s('TSQ'),
      nearestCity: s('Nearest City'),
      landmark: s('Landmark'),
      county: s('County'),
      state: s('State'),
      country: s('Country'),
      callsign: s('Callsign'),
      lat: s('Lat'),
      long: s('Long'),
      fmAnalog: s('FM Analog'),
      dmr: s('DMR'),
      operationalStatus: s('Operational Status'),
      use: s('Use'),
      fmBandwidth: s('FM Bandwidth'),
    );
  }

  /// Parsed latitude in decimal degrees, or null when absent/unparseable.
  double? get latitude => double.tryParse(lat);

  /// Parsed longitude in decimal degrees, or null when absent/unparseable.
  double? get longitude => double.tryParse(long);

  /// True when the repeater is publicly usable: OPEN membership and currently
  /// on the air. Used to hide closed/private/off-air repeaters from results.
  bool get isOpenAndOnAir {
    final u = use.toLowerCase();
    final status = operationalStatus.toLowerCase();
    final openUse = u.isEmpty || u == 'open';
    final onAir = status.isEmpty || status == 'on-air';
    return openUse && onAir;
  }
}

/// Fetches repeaters from RepeaterBook's HTTP/JSON export API and maps them onto
/// [RadioChannelInfo]. Distributed clients authenticate with a per-user token
/// (each user generates their own `rbuapp_...` token for the approved app at
/// <https://www.repeaterbook.com/user/api_apps.php>).
class RepeaterBookClient {
  /// Identifies this application to RepeaterBook. Their policy requires a
  /// User-Agent carrying an app identifier and a contact address, and it must
  /// match the value registered for the approved application exactly — a
  /// mismatch is rejected with HTTP 403 `ua_mismatch`.
  static const String userAgent =
      'HTCommander (+https://github.com/mprattmd/HTCommander; mprattmd@gmail.com)';

  static const String _amateurNorthAmerica =
      'https://www.repeaterbook.com/api/export.php';
  static const String _amateurRestOfWorld =
      'https://www.repeaterbook.com/api/exportROW.php';

  static const Set<String> _northAmerica = {
    'united states',
    'usa',
    'us',
    'canada',
    'mexico',
  };

  final http.Client _http;

  RepeaterBookClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Runs a search. Throws [RepeaterBookException] on HTTP failure (incl. 429).
  Future<List<RepeaterBookResult>> search(
    RepeaterBookQuery query,
    String appToken,
  ) async {
    if (appToken.trim().isEmpty) {
      throw RepeaterBookException(
        'No RepeaterBook API token — set one in Settings.',
      );
    }
    // A pasted token often carries a trailing newline → auth_invalid.
    final token = appToken.trim();
    final url = Uri.parse(buildUrl(query));

    http.Response resp;
    try {
      resp = await _http.get(url, headers: {
        'User-Agent': userAgent,
        'X-RB-App-Token': token,
      });
    } catch (e) {
      throw RepeaterBookException('Network error contacting RepeaterBook: $e');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      // The API returns {"error_code":"...","message":"..."} — surface it so the
      // user can tell auth_invalid (bad token) from auth_inactive/auth_revoked.
      final err = _extractError(resp.body);
      final server = err == null ? '' : ' ($err)';
      if (resp.statusCode == 429) {
        throw RepeaterBookException(
          'RepeaterBook is rate-limiting — try again shortly.$server',
          rateLimited: true,
        );
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw RepeaterBookException(
          'RepeaterBook rejected the API token$server — check it in Settings.',
        );
      }
      throw RepeaterBookException(
        'RepeaterBook returned HTTP ${resp.statusCode}$server.',
      );
    }

    return parse(resp.body);
  }

  /// Pulls `error_code`/`message` out of a RepeaterBook error envelope.
  static String? _extractError(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final brace = body.indexOf('{');
      final json =
          jsonDecode(brace > 0 ? body.substring(brace) : body);
      if (json is Map) {
        final code = json['error_code']?.toString();
        final msg = json['message']?.toString();
        if (code != null && code.isNotEmpty) {
          return msg == null || msg.isEmpty ? code : '$code: $msg';
        }
        return msg;
      }
    } catch (_) {}
    return null;
  }

  static List<RepeaterBookResult> parse(String body) {
    if (body.trim().isEmpty) return const [];
    // The API can prepend PHP warnings/HTML before the JSON object; start at the
    // first '{' so leading noise doesn't break parsing.
    final brace = body.indexOf('{');
    final text = brace > 0 ? body.substring(brace) : body;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return const [];
      final results = json['results'];
      if (results is! List) return const [];
      return results
          .whereType<Map>()
          .map((m) => RepeaterBookResult.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      throw RepeaterBookException(
        'Could not parse RepeaterBook response: $e',
      );
    }
  }

  static String buildUrl(RepeaterBookQuery q) {
    // GMRS is a parameter (stype=gmrs) on the North America export endpoint and
    // is US-only, so always use export.php for it.
    final base = (q.service == RepeaterBookService.gmrs || _isNorthAmerica(q.country))
        ? _amateurNorthAmerica
        : _amateurRestOfWorld;

    final params = <String, String>{};
    void add(String key, String value) {
      if (value.trim().isNotEmpty) params[key] = value.trim();
    }

    if (q.service == RepeaterBookService.gmrs) add('stype', 'gmrs');
    add('country', q.country);
    // RepeaterBook wants the numeric FIPS code, not the state name.
    add('state_id', resolveStateId(q.state));
    add('county', q.county);
    add('city', q.city);
    add('callsign', q.callsign);
    add('frequency', q.frequency);
    if (q.service == RepeaterBookService.amateur) add('mode', q.mode);

    return Uri.parse(base).replace(queryParameters: params).toString();
  }

  static bool _isNorthAmerica(String country) =>
      country.trim().isEmpty || _northAmerica.contains(country.trim().toLowerCase());

  /// RepeaterBook's `state_id` is the numeric US-state FIPS code (Virginia = 51).
  /// Accepts a full name ("Tennessee") or 2-letter abbreviation ("TN"). A value
  /// that is already numeric, or any unrecognized text, is passed through so
  /// non-US queries and direct IDs still work.
  static String resolveStateId(String state) {
    final s = state.trim();
    if (s.isEmpty) return '';
    if (RegExp(r'^\d+$').hasMatch(s)) return s; // already an ID
    return _usStateFips[s.toLowerCase()] ?? s;
  }

  // US state/territory FIPS codes, keyed (lowercase) by full name and 2-letter
  // abbreviation.
  static const Map<String, String> _usStateFips = {
    'alabama': '01', 'al': '01', 'alaska': '02', 'ak': '02',
    'arizona': '04', 'az': '04', 'arkansas': '05', 'ar': '05',
    'california': '06', 'ca': '06', 'colorado': '08', 'co': '08',
    'connecticut': '09', 'ct': '09', 'delaware': '10', 'de': '10',
    'district of columbia': '11', 'dc': '11', 'florida': '12', 'fl': '12',
    'georgia': '13', 'ga': '13', 'hawaii': '15', 'hi': '15',
    'idaho': '16', 'id': '16', 'illinois': '17', 'il': '17',
    'indiana': '18', 'in': '18', 'iowa': '19', 'ia': '19',
    'kansas': '20', 'ks': '20', 'kentucky': '21', 'ky': '21',
    'louisiana': '22', 'la': '22', 'maine': '23', 'me': '23',
    'maryland': '24', 'md': '24', 'massachusetts': '25', 'ma': '25',
    'michigan': '26', 'mi': '26', 'minnesota': '27', 'mn': '27',
    'mississippi': '28', 'ms': '28', 'missouri': '29', 'mo': '29',
    'montana': '30', 'mt': '30', 'nebraska': '31', 'ne': '31',
    'nevada': '32', 'nv': '32', 'new hampshire': '33', 'nh': '33',
    'new jersey': '34', 'nj': '34', 'new mexico': '35', 'nm': '35',
    'new york': '36', 'ny': '36', 'north carolina': '37', 'nc': '37',
    'north dakota': '38', 'nd': '38', 'ohio': '39', 'oh': '39',
    'oklahoma': '40', 'ok': '40', 'oregon': '41', 'or': '41',
    'pennsylvania': '42', 'pa': '42', 'rhode island': '44', 'ri': '44',
    'south carolina': '45', 'sc': '45', 'south dakota': '46', 'sd': '46',
    'tennessee': '47', 'tn': '47', 'texas': '48', 'tx': '48',
    'utah': '49', 'ut': '49', 'vermont': '50', 'vt': '50',
    'virginia': '51', 'va': '51', 'washington': '53', 'wa': '53',
    'west virginia': '54', 'wv': '54', 'wisconsin': '55', 'wi': '55',
    'wyoming': '56', 'wy': '56',
    'american samoa': '60', 'as': '60', 'guam': '66', 'gu': '66',
    'northern mariana islands': '69', 'mp': '69', 'puerto rico': '72', 'pr': '72',
    'virgin islands': '78', 'vi': '78',
  };

  /// Maps a RepeaterBook row to a radio channel.
  ///   • output freq → RX, input freq → TX (standard repeater convention);
  ///   • uplink PL/DCS → txSubAudio (CTCSS Hz×100, or DCS code as int);
  ///   • RX tone squelch left off (rxSubAudio = 0);
  ///   • name = callsign, else nearest city / landmark, clamped to 10 chars.
  /// Returns null when there is no usable frequency.
  static RadioChannelInfo? toRadioChannelInfo(RepeaterBookResult r, {int channelId = 0}) {
    int rxHz = _mHzToHz(r.frequency); // you receive on the repeater's output
    int txHz = _mHzToHz(r.inputFreq); // you transmit on the repeater's input
    if (rxHz == 0) rxHz = txHz;
    if (txHz == 0) txHz = rxHz; // simplex / missing input
    if (rxHz == 0 && txHz == 0) return null;

    final dmr = r.dmr.toLowerCase() == 'yes';
    final fm = r.fmAnalog.toLowerCase() == 'yes' || !dmr;
    final RadioModulationType mod;
    final RadioBandwidthType bw;
    if (dmr && !fm) {
      mod = RadioModulationType.dmr;
      bw = RadioBandwidthType.narrow;
    } else {
      mod = RadioModulationType.fm;
      bw = _parseBandwidth(r.fmBandwidth);
    }

    String name = r.callsign.isNotEmpty
        ? r.callsign
        : r.nearestCity.isNotEmpty
            ? r.nearestCity
            : r.landmark.isNotEmpty
                ? r.landmark
                : 'RPT';
    name = name.trim();
    if (name.length > 10) name = name.substring(0, 10);

    return RadioChannelInfo(
      channelId: channelId,
      name: name,
      rxFreq: rxHz,
      txFreq: txHz,
      rxMod: mod,
      txMod: mod,
      bandwidth: bw,
      rxSubAudio: 0, // RX squelch off
      txSubAudio: _parseTone(r.pl), // uplink tone you transmit
      txAtMaxPower: true,
    );
  }

  static int _mHzToHz(String mhz) {
    final v = double.tryParse(mhz.trim());
    return v == null ? 0 : (v * 1000000).round();
  }

  /// "25.0 kHz" → wide, "12.5 kHz" → narrow. Anything ≤ 15 kHz is narrow;
  /// blank/unparseable defaults to wide (the FM analog norm).
  static RadioBandwidthType _parseBandwidth(String bandwidth) {
    final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(bandwidth);
    final khz = m == null ? null : double.tryParse(m.group(1)!);
    return (khz != null && khz <= 15)
        ? RadioBandwidthType.narrow
        : RadioBandwidthType.wide;
  }

  /// CTCSS like "100.0" → 10000 (Hz×100). DCS like "D023" / "023" → 23. Empty → 0.
  static int _parseTone(String pl) {
    final s = pl.trim();
    if (s.isEmpty) return 0;
    if (s.toUpperCase().startsWith('D')) {
      final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
      return int.tryParse(digits) ?? 0;
    }
    final hz = double.tryParse(s);
    return hz == null ? 0 : (hz * 100).round();
  }

  /// Great-circle distance in kilometres between two coordinates (haversine).
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    double toRad(double d) => d * math.pi / 180.0;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  void close() => _http.close();
}
