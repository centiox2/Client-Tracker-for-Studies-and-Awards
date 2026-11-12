/// Search that ignores punctuation, case and accents: "O'Brien", "obrien"
/// and "O. Brien" all find the same person, and "Mary, Wanjiku" finds
/// "Mary Wanjiku".
library;

const _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', //
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', //
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
};

final _apostrophes = RegExp(r"['’`´]");
final _other = RegExp(r'[^a-z0-9]+');

/// [text] in lower case, without accents or apostrophes, with every other
/// mark (commas, full stops, dashes, slashes…) turned into a space and the
/// spaces evened out.
String searchKey(String text) {
  final lower = text.toLowerCase();
  final buf = StringBuffer();
  for (final ch in lower.split('')) {
    buf.write(_accents[ch] ?? ch);
  }
  return buf
      .toString()
      .replaceAll(_apostrophes, '')
      .replaceAll(_other, ' ')
      .trim();
}

/// The words of a search, punctuation ignored.
List<String> searchWords(String query) =>
    searchKey(query).split(' ').where((w) => w.isNotEmpty).toList();

/// A prepared search: [matches] says whether some text has every word of
/// the query in it (in any order). Words also match across a space or a
/// mark in the text ("obrien" finds "O. Brien").
class TextSearch {
  TextSearch(String query) : words = searchWords(query);

  final List<String> words;

  bool get isEmpty => words.isEmpty;

  bool matches(String text) {
    if (words.isEmpty) return true;
    final key = searchKey(text);
    final joined = key.replaceAll(' ', '');
    for (final w in words) {
      if (!key.contains(w) && !joined.contains(w)) return false;
    }
    return true;
  }

  /// Whether any of [fields] together hold every word.
  bool matchesAny(Iterable<String> fields) => matches(fields.join(' '));
}
