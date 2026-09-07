/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'package:flutter/services.dart';

import '../radio/utils.dart';

/// A [TextInputFormatter] that limits the edited text to at most [maxBytes]
/// bytes when encoded as GBK (code page 936). Truncation happens on a character
/// boundary so a multi-byte GBK character (e.g. a Chinese character, which takes
/// 2 bytes) is never split. This matches how the radio stores name fields:
/// fixed-size GBK byte buffers (10 bytes for channel and region names).
class GbkLengthLimitingTextInputFormatter extends TextInputFormatter {
  GbkLengthLimitingTextInputFormatter(this.maxBytes) : assert(maxBytes > 0);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final truncated = RadioUtils.truncateGbk(newValue.text, maxBytes);
    if (truncated == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
      composing: TextRange.empty,
    );
  }
}
