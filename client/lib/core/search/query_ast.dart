// SPDX-FileCopyrightText: 2026 Bora Yarkın
// SPDX-License-Identifier: GPL-3.0-only

// AST types for the frontend structured-search language.

class SearchFieldToken {
  final String source;
  final String field;
  final String normalizedField;
  final String value;
  final String normalizedValue;
  final bool hasValueSeparator;
  final bool isNegated;
  final int start;
  final int end;

  const SearchFieldToken({
    required this.source,
    required this.field,
    required this.normalizedField,
    required this.value,
    required this.normalizedValue,
    required this.hasValueSeparator,
    required this.isNegated,
    required this.start,
    required this.end,
  });

  bool get hasValue => normalizedValue.isNotEmpty;

  String toChipLabel() {
    final buffer = StringBuffer();
    if (isNegated) buffer.write('-');
    buffer.write('@$normalizedField');
    if (hasValueSeparator || hasValue) {
      buffer.write(':');
      if (value.contains(' ')) {
        buffer.write('"$value"');
      } else {
        buffer.write(value);
      }
    }
    return buffer.toString();
  }
}

class SearchTextToken {
  final String source;
  final String value;
  final String normalizedValue;
  final bool isNegated;
  final int start;
  final int end;

  const SearchTextToken({
    required this.source,
    required this.value,
    required this.normalizedValue,
    this.isNegated = false,
    required this.start,
    required this.end,
  });
}

class SearchParseDiagnostic {
  final String code;
  final String message;
  final int start;
  final int end;

  const SearchParseDiagnostic({
    required this.code,
    required this.message,
    required this.start,
    required this.end,
  });
}

enum SearchBooleanOperator { and, or, nor, xor }

sealed class SearchExpressionNode {
  const SearchExpressionNode();
}

class SearchExpressionGroup extends SearchExpressionNode {
  final SearchBooleanOperator operator;
  final List<SearchExpressionNode> children;

  const SearchExpressionGroup({required this.operator, required this.children});
}

class SearchExpressionNot extends SearchExpressionNode {
  final SearchExpressionNode child;

  const SearchExpressionNot({required this.child});
}

class SearchExpressionAtom extends SearchExpressionNode {
  final SearchFieldToken? fieldToken;
  final SearchTextToken? textToken;

  const SearchExpressionAtom.field({required SearchFieldToken token})
    : fieldToken = token,
      textToken = null;

  const SearchExpressionAtom.text({required SearchTextToken token})
    : fieldToken = null,
      textToken = token;

  bool get isField => fieldToken != null;

  bool get isText => textToken != null;
}

class SearchQueryAst {
  final String raw;
  final List<SearchFieldToken> fieldTokens;
  final List<SearchTextToken> textTokens;
  final SearchExpressionNode? expression;
  final List<SearchParseDiagnostic> diagnostics;

  const SearchQueryAst({
    required this.raw,
    required this.fieldTokens,
    required this.textTokens,
    required this.expression,
    required this.diagnostics,
  });

  List<String> get normalizedTerms =>
      textTokens.map((token) => token.normalizedValue).toList(growable: false);

  bool get hasDiagnostics => diagnostics.isNotEmpty;
}

class AtTokenSuggestionContext {
  final String activeToken;
  final String fieldLower;
  final String partialFieldLower;
  final String partialValueLower;
  final bool hasValueSeparator;
  final bool hasTrailingWhitespace;
  final bool isNegated;
  final int replaceStart;
  final int replaceEnd;

  const AtTokenSuggestionContext({
    required this.activeToken,
    required this.fieldLower,
    required this.partialFieldLower,
    required this.partialValueLower,
    required this.hasValueSeparator,
    required this.hasTrailingWhitespace,
    required this.isNegated,
    required this.replaceStart,
    required this.replaceEnd,
  });
}

final RegExp _fieldNamePattern = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_-]*$');

SearchQueryAst parseSearchQueryAst(String raw) {
  final parser = _SearchExpressionParser(raw: raw, lexemes: _scanLexemes(raw));
  final expression = parser.parse();

  return SearchQueryAst(
    raw: raw,
    fieldTokens: parser.fieldTokens,
    textTokens: parser.textTokens,
    expression: expression,
    diagnostics: parser.diagnostics,
  );
}

bool evaluateSearchExpression(
  SearchExpressionNode? expression, {
  required bool Function(SearchFieldToken token) matchesField,
  required bool Function(SearchTextToken token) matchesText,
}) {
  if (expression == null) {
    return true;
  }
  return switch (expression) {
    SearchExpressionAtom(fieldToken: final fieldToken?) => matchesField(
      fieldToken,
    ),
    SearchExpressionAtom(textToken: final textToken?) => matchesText(textToken),
    SearchExpressionNot(:final child) => !evaluateSearchExpression(
      child,
      matchesField: matchesField,
      matchesText: matchesText,
    ),
    SearchExpressionGroup(
      operator: SearchBooleanOperator.and,
      :final children,
    ) =>
      children.every(
        (child) => evaluateSearchExpression(
          child,
          matchesField: matchesField,
          matchesText: matchesText,
        ),
      ),
    SearchExpressionGroup(
      operator: SearchBooleanOperator.or,
      :final children,
    ) =>
      children.any(
        (child) => evaluateSearchExpression(
          child,
          matchesField: matchesField,
          matchesText: matchesText,
        ),
      ),
    SearchExpressionGroup(
      operator: SearchBooleanOperator.nor,
      :final children,
    ) =>
      !children.any(
        (child) => evaluateSearchExpression(
          child,
          matchesField: matchesField,
          matchesText: matchesText,
        ),
      ),
    SearchExpressionGroup(
      operator: SearchBooleanOperator.xor,
      :final children,
    ) =>
      children
              .where(
                (child) => evaluateSearchExpression(
                  child,
                  matchesField: matchesField,
                  matchesText: matchesText,
                ),
              )
              .length ==
          1,
    _ => false,
  };
}

AtTokenSuggestionContext? parseAtTokenSuggestionContext(String raw) {
  if (raw.isEmpty) return null;
  final hasTrailingWhitespace = RegExp(r'\s$').hasMatch(raw);
  final trimmedRight = raw.replaceFirst(RegExp(r'[\s;]+$'), '');
  if (trimmedRight.isEmpty) return null;

  final lastTokenMatch = RegExp(r'([^\s;]+)$').firstMatch(trimmedRight);
  if (lastTokenMatch == null) return null;
  final active = lastTokenMatch.group(1) ?? '';
  if (active.isEmpty) return null;

  var token = active;
  var isNegated = false;
  if (token.startsWith('-@')) {
    isNegated = true;
    token = token.substring(1);
  }
  if (!token.startsWith('@')) return null;

  final payload = token.substring(1);
  final separatorIndex = payload.indexOf(':');
  if (separatorIndex < 0) {
    final partial = payload.trim().toLowerCase();
    return AtTokenSuggestionContext(
      activeToken: active,
      fieldLower: partial,
      partialFieldLower: partial,
      partialValueLower: '',
      hasValueSeparator: false,
      hasTrailingWhitespace: hasTrailingWhitespace,
      isNegated: isNegated,
      replaceStart: lastTokenMatch.start,
      replaceEnd: lastTokenMatch.end,
    );
  }

  final field = payload.substring(0, separatorIndex).trim().toLowerCase();
  final value = payload
      .substring(separatorIndex + 1)
      .replaceAll('"', '')
      .toLowerCase();
  return AtTokenSuggestionContext(
    activeToken: active,
    fieldLower: field,
    partialFieldLower: field,
    partialValueLower: value,
    hasValueSeparator: true,
    hasTrailingWhitespace: hasTrailingWhitespace,
    isNegated: isNegated,
    replaceStart: lastTokenMatch.start,
    replaceEnd: lastTokenMatch.end,
  );
}

String applyAtTokenSuggestion({
  required String raw,
  required String suggestionToken,
  required bool appendSpace,
}) {
  final trimmedRight = raw.replaceFirst(RegExp(r'[\s;]+$'), '');
  final context = parseAtTokenSuggestionContext(raw);

  if (context == null) {
    final spacer = trimmedRight.isEmpty ? '' : '; ';
    return '$trimmedRight$spacer$suggestionToken${appendSpace ? ' ' : ''}';
  }

  var replacement = suggestionToken;
  if (context.isNegated && !replacement.startsWith('-')) {
    replacement = '-$replacement';
  }

  final replaced = trimmedRight.replaceRange(
    context.replaceStart,
    context.replaceEnd,
    replacement,
  );
  return appendSpace ? '$replaced ' : replaced;
}

String removeSearchRangeFromQuery(
  String raw, {
  required int start,
  required int end,
}) {
  final safeStart = start < 0 ? 0 : (start > raw.length ? raw.length : start);
  final safeEnd = end < safeStart
      ? safeStart
      : (end > raw.length ? raw.length : end);
  final merged = '${raw.substring(0, safeStart)} ${raw.substring(safeEnd)}';
  return normalizeSearchInput(merged);
}

String normalizeSearchInput(String raw) {
  var normalized = raw.replaceAll(RegExp(r'\s*;\s*'), '; ');
  normalized = normalized.replaceAll(RegExp(r'\s+'), ' ');
  normalized = normalized.replaceAll(RegExp(r'(?:;\s*){2,}'), '; ');
  normalized = normalized.replaceAll(RegExp(r'^;\s*'), '');
  normalized = normalized.replaceAll(RegExp(r'\s*;$'), '');
  return normalized.trim();
}

List<String> splitSearchFlagValues(String rawValue) {
  final trimmed = rawValue.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return const <String>[];
  }
  final seen = <String>{};
  final values = <String>[];
  for (final part in trimmed.split(RegExp(r'[\s,]+'))) {
    final candidate = part.trim();
    if (candidate.isEmpty || !seen.add(candidate)) {
      continue;
    }
    values.add(candidate);
  }
  return values;
}

SearchFieldToken? _tryParseFieldToken({
  required String source,
  required String token,
  required bool isNegated,
  required int start,
  required int end,
}) {
  final hasAtPrefix = token.startsWith('@');
  final payload = hasAtPrefix ? token.substring(1).trim() : token.trim();
  if (payload.isEmpty) return null;

  final separatorIndex = payload.indexOf(':');
  final hasValueSeparator = separatorIndex >= 0;
  if (!hasAtPrefix && !hasValueSeparator) {
    return null;
  }

  String field;
  String value;
  if (separatorIndex >= 0) {
    field = payload.substring(0, separatorIndex).trim();
    value = payload.substring(separatorIndex + 1).trim();
  } else {
    field = payload.trim();
    value = '';
  }

  if (!_fieldNamePattern.hasMatch(field)) return null;

  final unquotedValue = _stripWrappingQuotes(value).trim();
  return SearchFieldToken(
    source: source,
    field: field,
    normalizedField: field.toLowerCase(),
    value: unquotedValue,
    normalizedValue: unquotedValue.toLowerCase(),
    hasValueSeparator: hasValueSeparator,
    isNegated: isNegated,
    start: start,
    end: end,
  );
}

String _stripWrappingQuotes(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}

enum _SearchLexemeKind { value, and, or, nor, xor, not, lParen, rParen }

class _SearchLexeme {
  final _SearchLexemeKind kind;
  final String text;
  final int start;
  final int end;

  const _SearchLexeme({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
  });
}

class _SearchExpressionParser {
  final String raw;
  final List<_SearchLexeme> lexemes;
  final List<SearchFieldToken> fieldTokens = <SearchFieldToken>[];
  final List<SearchTextToken> textTokens = <SearchTextToken>[];
  final List<SearchParseDiagnostic> diagnostics = <SearchParseDiagnostic>[];

  int _index = 0;

  _SearchExpressionParser({required this.raw, required this.lexemes});

  bool get _isAtEnd => _index >= lexemes.length;

  _SearchLexeme? get _current => _isAtEnd ? null : lexemes[_index];

  bool _match(_SearchLexemeKind kind) {
    if (_current?.kind != kind) {
      return false;
    }
    _index += 1;
    return true;
  }

  SearchExpressionNode? parse() {
    final expression = _parseOr();
    while (!_isAtEnd) {
      final token = lexemes[_index];
      _addDiagnostic(
        code: 'unexpected_token',
        message: 'Unexpected token: ${token.text}',
        start: token.start,
        end: token.end,
      );
      _index += 1;
    }
    return expression;
  }

  SearchExpressionNode? _parseOr() {
    var node = _parseAnd();
    while (true) {
      final operator = _matchDisjunctionOperator();
      if (operator == null) {
        break;
      }
      final rhs = _parseAnd();
      node = _joinGroup(operator, node, rhs);
    }
    return node;
  }

  SearchBooleanOperator? _matchDisjunctionOperator() {
    if (_match(_SearchLexemeKind.or)) {
      return SearchBooleanOperator.or;
    }
    if (_match(_SearchLexemeKind.nor)) {
      return SearchBooleanOperator.nor;
    }
    if (_match(_SearchLexemeKind.xor)) {
      return SearchBooleanOperator.xor;
    }
    return null;
  }

  SearchExpressionNode? _parseAnd() {
    var node = _parseUnary();
    while (true) {
      if (_match(_SearchLexemeKind.and)) {
        final rhs = _parseUnary();
        node = _joinGroup(SearchBooleanOperator.and, node, rhs);
        continue;
      }
      final next = _current?.kind;
      final isImplicitAnd =
          next == _SearchLexemeKind.value ||
          next == _SearchLexemeKind.lParen ||
          next == _SearchLexemeKind.not;
      if (!isImplicitAnd) {
        break;
      }
      final rhs = _parseUnary();
      node = _joinGroup(SearchBooleanOperator.and, node, rhs);
    }
    return node;
  }

  SearchExpressionNode? _parseUnary() {
    if (_match(_SearchLexemeKind.not)) {
      final token = lexemes[_index - 1];
      final child = _parseUnary();
      if (child == null) {
        _addDiagnostic(
          code: 'missing_operand',
          message: 'NOT requires an operand.',
          start: token.start,
          end: token.end,
        );
        return null;
      }
      return SearchExpressionNot(child: child);
    }
    return _parsePrimary();
  }

  SearchExpressionNode? _parsePrimary() {
    if (_match(_SearchLexemeKind.lParen)) {
      final opening = lexemes[_index - 1];
      final expression = _parseOr();
      if (!_match(_SearchLexemeKind.rParen)) {
        _addDiagnostic(
          code: 'unclosed_group',
          message: 'Missing closing parenthesis.',
          start: opening.start,
          end: opening.end,
        );
      }
      return expression;
    }

    if (_match(_SearchLexemeKind.rParen)) {
      final token = lexemes[_index - 1];
      _addDiagnostic(
        code: 'unexpected_close_paren',
        message: 'Unexpected closing parenthesis.',
        start: token.start,
        end: token.end,
      );
      return null;
    }

    if (_match(_SearchLexemeKind.and) ||
        _match(_SearchLexemeKind.or) ||
        _match(_SearchLexemeKind.nor) ||
        _match(_SearchLexemeKind.xor)) {
      final token = lexemes[_index - 1];
      _addDiagnostic(
        code: 'unexpected_operator',
        message: 'Unexpected operator: ${token.text.toUpperCase()}',
        start: token.start,
        end: token.end,
      );
      return null;
    }

    if (_match(_SearchLexemeKind.value)) {
      final token = lexemes[_index - 1];
      return _parseValue(token);
    }

    return null;
  }

  SearchExpressionNode? _parseValue(_SearchLexeme lexeme) {
    var token = lexeme.text;
    var isLeadingNegatedText = false;
    if (token.startsWith('-') && token.length > 1) {
      isLeadingNegatedText = true;
      token = token.substring(1);
    }

    final fieldToken = _tryParseFieldToken(
      source: lexeme.text,
      token: token,
      isNegated: isLeadingNegatedText,
      start: lexeme.start,
      end: lexeme.end,
    );
    if (fieldToken != null) {
      fieldTokens.add(fieldToken);
      return SearchExpressionAtom.field(token: fieldToken);
    }

    final textValue = _stripWrappingQuotes(token).trim();
    if (textValue.isEmpty) {
      _addDiagnostic(
        code: 'empty_term',
        message: 'Empty search term.',
        start: lexeme.start,
        end: lexeme.end,
      );
      return null;
    }

    final textToken = SearchTextToken(
      source: lexeme.text,
      value: textValue,
      normalizedValue: textValue.toLowerCase(),
      isNegated: isLeadingNegatedText,
      start: lexeme.start,
      end: lexeme.end,
    );
    textTokens.add(textToken);

    SearchExpressionNode atom = SearchExpressionAtom.text(token: textToken);
    if (isLeadingNegatedText) {
      atom = SearchExpressionNot(child: atom);
    }
    return atom;
  }

  SearchExpressionNode? _joinGroup(
    SearchBooleanOperator operator,
    SearchExpressionNode? left,
    SearchExpressionNode? right,
  ) {
    if (left == null) {
      return right;
    }
    if (right == null) {
      return left;
    }
    if (left is SearchExpressionGroup && left.operator == operator) {
      return SearchExpressionGroup(
        operator: operator,
        children: <SearchExpressionNode>[...left.children, right],
      );
    }
    return SearchExpressionGroup(
      operator: operator,
      children: <SearchExpressionNode>[left, right],
    );
  }

  void _addDiagnostic({
    required String code,
    required String message,
    required int start,
    required int end,
  }) {
    diagnostics.add(
      SearchParseDiagnostic(
        code: code,
        message: message,
        start: start,
        end: end,
      ),
    );
  }
}

List<_SearchLexeme> _scanLexemes(String raw) {
  final lexemes = <_SearchLexeme>[];
  var index = 0;

  while (index < raw.length) {
    final ch = raw[index];
    if (ch.trim().isEmpty || ch == ';') {
      index += 1;
      continue;
    }

    if (ch == '(') {
      lexemes.add(
        _SearchLexeme(
          kind: _SearchLexemeKind.lParen,
          text: '(',
          start: index,
          end: index + 1,
        ),
      );
      index += 1;
      continue;
    }

    if (ch == ')') {
      lexemes.add(
        _SearchLexeme(
          kind: _SearchLexemeKind.rParen,
          text: ')',
          start: index,
          end: index + 1,
        ),
      );
      index += 1;
      continue;
    }

    final start = index;
    var inQuotes = false;
    while (index < raw.length) {
      final next = raw[index];
      if (next == '"') {
        inQuotes = !inQuotes;
        index += 1;
        continue;
      }
      if (!inQuotes &&
          (next.trim().isEmpty || next == ';' || next == '(' || next == ')')) {
        break;
      }
      index += 1;
    }

    final end = index;
    final text = raw.substring(start, end).trim();
    if (text.isEmpty) {
      continue;
    }

    final lower = text.toLowerCase();
    final kind = switch (lower) {
      'and' || '&&' => _SearchLexemeKind.and,
      'or' || '||' => _SearchLexemeKind.or,
      'nor' => _SearchLexemeKind.nor,
      'xor' || '^' => _SearchLexemeKind.xor,
      'not' || '!' => _SearchLexemeKind.not,
      _ =>
        (text == '-' || text == '!')
            ? _SearchLexemeKind.not
            : _SearchLexemeKind.value,
    };

    lexemes.add(_SearchLexeme(kind: kind, text: text, start: start, end: end));
  }

  return lexemes;
}
