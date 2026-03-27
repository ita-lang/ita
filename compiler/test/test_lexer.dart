/// Teste do Lexer Ita — tokeniza um programa de exemplo e printa os tokens.

import '../lib/lexer/token.dart';
import '../lib/lexer/lexer.dart';

void main() {
  const source = r'''
// Glu language example

use math.{ abs, round }

struct Point {
  x: Float
  y: Float

  fn distance(to other: Point) -> Float {
    ((x - other.x).pow(2) + (y - other.y).pow(2)).sqrt()
  }

  fn translated(dx: Float, dy: Float) -> Point {
    Point(x: x + dx, y: y + dy)
  }
}

trait Displayable {
  fn display() -> String
}

impl Displayable for Point {
  fn display() -> String => "Point(${x}, ${y})"
}

enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,
}

fn area(shape: Shape) -> Float => match shape {
  .circle(r)    => PI * r * r,
  .rect(w, h)   => w * h,
  .point        => 0.0,
}

fn main() {
  let p1 = Point(x: 1.0, y: 2.0)
  let p2 = p1.{ x: 10.0 }

  var count = 0
  count += 1

  let name: String? = nil
  guard let value = name else {
    return
  }

  let safe = name ?? "anonymous"

  let nums = [1, 2, 3, 4, 5]
  let result = nums
    |> filter((x) => x > 2)
    |> map((x) => x * 2)

  match result {
    []              => print("empty"),
    [single]        => print("one: ${single}"),
    [first, ..rest] => print("many: ${first}"),
  }

  let range = 0..10
  let inclusive = 0..=100

  // Custom operator
  let power = 2.0 ** 10.0

  // Hex and binary
  let hex = 0xFF
  let bin = 0b1010

  // Multiline string
  let html = """
    <div class="card">
      <h1>Hello</h1>
    </div>
  """
}
''';

  print('=== Glu Lexer Test ===\n');
  print('Source: ${source.length} chars\n');

  final lexer = Lexer(source);
  final tokens = lexer.tokenize();

  // Reportar erros
  if (lexer.errors.isNotEmpty) {
    print('--- ERRORS ---');
    for (final err in lexer.errors) {
      print('  $err');
    }
    print('');
  }

  // Printar tokens agrupados por linha
  int currentLine = -1;
  for (final token in tokens) {
    if (token.line != currentLine) {
      if (currentLine != -1) print('');
      currentLine = token.line;
      print('Line $currentLine:');
    }
    final litStr = token.literal != null ? ' = ${token.literal}' : '';
    print('  ${token.type.name.padRight(20)} "${token.lexeme}"$litStr');
  }

  // Estatísticas
  print('\n=== Stats ===');
  print('Tokens: ${tokens.length}');
  print('Errors: ${lexer.errors.length}');

  final typeCounts = <TokenType, int>{};
  for (final t in tokens) {
    typeCounts[t.type] = (typeCounts[t.type] ?? 0) + 1;
  }
  final sorted = typeCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('\nToken distribution:');
  for (final entry in sorted.take(15)) {
    print('  ${entry.key.name.padRight(20)} ${entry.value}');
  }
}
