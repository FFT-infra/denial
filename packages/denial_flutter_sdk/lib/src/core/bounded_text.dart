final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f]');
final _whitespace = RegExp(r'\s+');

/// Collapses control characters and whitespace, then keeps at most the given
/// number of Unicode runes without splitting a surrogate pair.
String normalizeBoundedText(String value, int maximumRunes) {
  if (maximumRunes < 0) {
    throw RangeError.range(maximumRunes, 0, null, 'maximumRunes');
  }
  if (maximumRunes == 0) return '';
  final normalized = value
      .replaceAll(_controlCharacters, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
  // UTF-16 length bounds the rune count. Short text needs no rune traversal,
  // intermediate integer list, or reconstructed string.
  if (normalized.length <= maximumRunes) return normalized;
  final runes = normalized.runes.iterator;
  for (var count = 0; count < maximumRunes; count++) {
    if (!runes.moveNext()) return normalized;
  }
  return normalized.substring(0, runes.rawIndex + runes.currentSize);
}
