/// Text helpers for PDFs built with the standard (ASCII) fonts.
library;

/// The built-in PDF fonts cover ASCII only; map engineering symbols.
String pdfSafe(String s) {
  const map = {
    'Ω': 'ohm',
    'µ': 'u',
    'μ': 'u',
    'Γ': 'G',
    'ε': 'e',
    '≤': '<=',
    '≥': '>=',
    '≈': '~',
    '±': '+/-',
    '×': 'x',
    '−': '-',
    '–': '-',
    '—': '-',
    '·': '-',
    '→': '->',
    '⊗': '(x)',
    '₀': '0',
    '…': '...',
    '’': "'",
    '“': '"',
    '”': '"',
    '⚠': '!',
    '√': 'sqrt',
    'τ': 'tau',
    'π': 'pi',
    'α': 'alpha',
    'δ': 'delta',
    'Δ': 'd',
    '²': '2',
    '←': '<-',
    '°': ' deg',
    '≠': '!=',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (map.containsKey(ch)) {
      b.write(map[ch]);
    } else if (r < 128) {
      b.write(ch);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}
