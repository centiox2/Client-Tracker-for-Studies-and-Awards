/// [text] cut to at most [max] UTF-16 units, never splitting an emoji or
/// other character stored as a surrogate pair (that would leave a broken
/// half behind).
String clipText(String text, int max) {
  if (text.length <= max) return text;
  var end = max;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--; // a pair's first half
  return text.substring(0, end);
}
