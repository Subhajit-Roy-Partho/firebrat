/// Tolerant JSON extraction for small on-device LLMs: drops `<think>` blocks and
/// Markdown fences, tolerates trailing commas and prose around the JSON, and
/// repairs output truncated by the token limit (closes open strings/brackets).
library;

import 'dart:convert';

final _thinkBlock = RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false);
final _thinkOpen = RegExp(r'<think>.*$', dotAll: true, caseSensitive: false);
final _fence = RegExp(r'```(?:json)?\s*(.*?)```', dotAll: true, caseSensitive: false);
final _trailingComma = RegExp(r',(\s*[}\]])');

/// Removes Qwen-style reasoning blocks (also an unterminated one).
String stripThinking(String text) => text.replaceAll(_thinkBlock, '').replaceAll(_thinkOpen, '').trim();

/// Parses one JSON value (object or array) out of free-form model output.
/// Throws [FormatException] when nothing usable is found.
Object? extractJsonValue(String? raw) {
  var text = stripThinking(raw ?? '');
  final fenced = _fence.firstMatch(text);
  if (fenced != null) text = fenced.group(1)!.trim();
  final candidates = <String>[text, text.replaceAllMapped(_trailingComma, (m) => m.group(1)!)];
  for (final candidate in candidates) {
    try {
      return jsonDecode(candidate);
    } on FormatException {
      // fall through to the substring strategies
    }
    final start = _firstOpen(candidate);
    if (start < 0) continue;
    final slice = candidate.substring(start);
    final balanced = _balancedPrefix(slice);
    if (balanced != null) {
      for (final attempt in [balanced, balanced.replaceAllMapped(_trailingComma, (m) => m.group(1)!)]) {
        try {
          return jsonDecode(attempt);
        } on FormatException {
          // try repair below
        }
      }
    }
    final repaired = repairTruncatedJson(slice);
    if (repaired != null) {
      try {
        return jsonDecode(repaired);
      } on FormatException {
        // give up on this candidate
      }
    }
  }
  final shown = text.length > 120 ? '${text.substring(0, 120)}...' : text;
  throw FormatException('no JSON value found in model output: $shown');
}

Map<String, dynamic> extractJsonObject(String? raw) {
  final v = extractJsonValue(raw);
  if (v is Map) return Map<String, dynamic>.from(v);
  throw FormatException('expected a JSON object, got ${v.runtimeType}');
}

List<dynamic> extractJsonArray(String? raw) {
  final v = extractJsonValue(raw);
  if (v is List) return v;
  throw FormatException('expected a JSON array, got ${v.runtimeType}');
}

int _firstOpen(String s) {
  final a = s.indexOf('{'), b = s.indexOf('[');
  if (a < 0) return b;
  if (b < 0) return a;
  return a < b ? a : b;
}

/// The first complete top-level JSON value at the start of [s], or null.
String? _balancedPrefix(String s) {
  final stack = <String>[];
  var inString = false, escape = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{' || c == '[') {
      stack.add(c);
    } else if (c == '}' || c == ']') {
      if (stack.isEmpty) return null;
      stack.removeLast();
      if (stack.isEmpty) return s.substring(0, i + 1);
    }
  }
  return null;
}

/// Best-effort repair of output cut off mid-way: drops a dangling partial
/// element, closes an open string and every open bracket. Null when hopeless.
String? repairTruncatedJson(String s) {
  final stack = <String>[];
  var inString = false, escape = false;
  var lastSafe = -1; // index just after the last complete element boundary
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (c == r'\') {
        escape = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{' || c == '[') {
      stack.add(c);
      lastSafe = i + 1;
    } else if (c == '}' || c == ']') {
      if (stack.isEmpty) return null;
      stack.removeLast();
      lastSafe = i + 1;
    } else if (c == ',') {
      lastSafe = i; // cut before the comma: the element after it is partial
    }
  }
  if (stack.isEmpty && !inString) return s;
  if (lastSafe <= 0) return null;
  // Rebuild open brackets as of lastSafe.
  final open = <String>[];
  var str = false, esc = false;
  for (var i = 0; i < lastSafe; i++) {
    final c = s[i];
    if (str) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        str = false;
      }
      continue;
    }
    if (c == '"') {
      str = true;
    } else if (c == '{' || c == '[') {
      open.add(c);
    } else if (c == '}' || c == ']') {
      if (open.isNotEmpty) open.removeLast();
    }
  }
  final b = StringBuffer(s.substring(0, lastSafe).trimRight());
  var out = b.toString();
  if (out.endsWith(',')) out = out.substring(0, out.length - 1);
  // A dangling key without a value ("name":) cannot be closed cleanly.
  if (RegExp(r'[:,]\s*$').hasMatch(out)) return null;
  for (final o in open.reversed) {
    out += o == '{' ? '}' : ']';
  }
  return out;
}
