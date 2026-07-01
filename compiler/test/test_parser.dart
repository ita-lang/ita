/// Teste do Parser Ita — parseia um programa completo e printa a AST.

import '../lib/lexer/token.dart';
import '../lib/lexer/lexer.dart';
import '../lib/parser/ast.dart';
import '../lib/parser/parser.dart';

void main() {
  const source = r'''
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
  fn display() -> String => "Point"
}

enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,
}

fn area(shape: Shape) -> Float => match shape {
  .circle(r)    => 3.14 * r * r,
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

  let range = 0..10
  let inclusive = 0..=100
  let power = 2.0 ** 10.0

  if count > 0 {
    print("positive")
  } else {
    print("zero")
  }

  for item in nums {
    print(item)
  }

  while count > 0 {
    count -= 1
  }

  match result {
    []              => print("empty"),
    [single]        => print("one"),
    [first, ..rest] => print("many"),
  }
}
''';

  print('=== Itá Parser Test ===\n');

  // Lexer
  final lexer = Lexer(source);
  final tokens = lexer.tokenize();

  if (lexer.errors.isNotEmpty) {
    print('--- LEXER ERRORS ---');
    for (final err in lexer.errors) {
      print('  $err');
    }
    return;
  }

  print('Lexer: ${tokens.length} tokens, 0 errors\n');

  // Parser
  final parser = Parser(tokens);
  final program = parser.parse();

  if (parser.errors.isNotEmpty) {
    print('--- PARSER ERRORS ---');
    for (final err in parser.errors) {
      print('  $err');
    }
    print('');
  }

  // Print AST
  final printer = AstPrinter();
  print(printer.print(program));

  // Stats
  print('=== Stats ===');
  print('Declarations: ${program.declarations.length}');
  print('Parse errors: ${parser.errors.length}');
}
