/// Tests the encoded size without allocating a UTF-8 buffer. Matches Dart's
/// UTF-8 encoder, including its replacement of unpaired surrogates with U+FFFD.
bool fitsUtf8ByteLimit(String value, int maximumBytes) {
  final length = value.length;
  // Each UTF-16 code unit needs at least one and at most three UTF-8 bytes.
  // A surrogate pair takes four bytes for its two code units.
  if (length > maximumBytes) return false;
  if (length <= maximumBytes ~/ 3) return true;

  var remaining = maximumBytes - length;
  for (var index = 0; index < length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit < 0x80) continue;
    remaining -= unit < 0x800 ? 1 : 2;
    if (remaining < 0) return false;
    if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < length) {
      final next = value.codeUnitAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) index++;
    }
  }
  return true;
}
