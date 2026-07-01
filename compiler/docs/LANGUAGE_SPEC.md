# Itá Language Specification

**Itá** é uma linguagem fortemente tipada, com tipagem estática, que compila para Dart Kernel (.dill) e roda na Dart VM. Ela é um híbrido funcional/OO, com ênfase no funcional, pensada para devs vindos do ecossistema JS/TS.

## Princípios

1. **Imutável por padrão.** Se quer mutável, peça explicitamente.
2. **Valor vs Referência é explícito.** `struct` = valor, `class` = referência.
3. **Tudo é expressão quando possível.** `match`, `if`, blocos retornam valor.
4. **Sem mágica.** Conciso, mas nunca esconde o que acontece.
5. **Funcional é o caminho natural. OO existe quando faz sentido.**
6. **Zero annotations.** `@decorators` não existem e NUNCA serão implementados. Comportamento deve ser explícito no código, não escondido em metadados. Se precisa de um comportamento, use traits, extensions, ou composição — nunca um `@` que modifica silenciosamente a semântica.

---

## 1. Tipos e Bindings

```tu
// Imutável (padrão)
let x = 42                    // tipo inferido: Int
let name: String = "Itá"      // tipo explícito

// Mutável (opt-in)
var count = 0
count = count + 1

// Constante em tempo de compilação
const PI = 3.14159
```

### Tipos primitivos

```tu
Int, Float, Bool, String, Void, Never
```

### Optionals (nullable)

```tu
let name: String? = nil
let age: Int? = 25

// Optional chaining
let len = name?.length         // Int?

// Nil coalescing
let safe = name ?? "anonymous" // String

// Force unwrap (panic se nil)
let forced = name!             // String (ou crash)
```

### Result

```tu
// Result é built-in, não uma lib
fn divide(a: Float, b: Float) -> Result<Float, MathError> {
  guard b != 0.0 else { return .err(.divisionByZero) }
  .ok(a / b)
}

// Uso
match divide(10.0, 0.0) {
  .ok(val)  => print("Result: ${val}"),
  .err(err) => print("Error: ${err}"),
}

// Try operator (propaga erro automaticamente)
fn calculate() -> Result<Float, MathError> {
  let a = divide(10.0, 2.0)?    // unwrap ou return early com erro
  let b = divide(a, 3.0)?
  .ok(b)
}
```

---

## 2. Funções

```tu
// Declaração padrão
fn add(a: Int, b: Int) -> Int {
  a + b    // retorno implícito (última expressão)
}

// Arrow (corpo de expressão única)
fn double(x: Int) -> Int => x * 2

// Sem retorno
fn greet(name: String) -> Void {
  print("Hello ${name}")
}

// Parâmetros com default
fn connect(host: String, port: Int = 8080) -> Connection {
  // ...
}

// Named parameters (após ;)
fn fetch(url: String; timeout: Int = 30, retries: Int = 3) -> Response {
  // ...
}
// Chamada:
fetch("https://api.io", timeout: 10)

// Generics
fn first<T>(list: List<T>) -> T? => list[0]
```

---

## 3. Closures

```tu
// Closure completa
let add = (a: Int, b: Int) -> Int => a + b

// Tipo inferido pelo contexto
let nums = [1, 2, 3]
let doubled = nums.map((x) => x * 2)

// Multiline
let process = (x: Int) -> String {
  let result = x * 2
  "value: ${result}"
}

// Shorthand com $0, $1 (quando tipo é conhecido pelo contexto)
let sorted = names.sort(by: $0.length > $1.length)

// Trailing closure
nums.filter { $0 > 2 }

// Closure como último argumento
fetch("url") { response in
  print(response.body)
}
```

---

## 4. Pattern Matching

```tu
// Match expression (retorna valor)
let label = match status {
  0           => "idle",
  1..=5       => "loading",
  n if n > 10 => "overloaded (${n})",
  _           => "unknown",
}

// Destructuring
match point {
  Point { x: 0, y: 0 }          => "origin",
  Point { x, y } if x == y      => "diagonal",
  Point { x, y }                 => "(${x}, ${y})",
}

// Nested patterns
match response {
  .ok(User { name, age }) if age >= 18 => "Welcome ${name}",
  .ok(User { name, .. })               => "Sorry ${name}, too young",
  .err(e)                               => "Failed: ${e}",
}

// List patterns
match items {
  []              => "empty",
  [single]        => "one: ${single}",
  [first, ..rest] => "first: ${first}, rest: ${rest.length}",
}
```

---

## 5. Guard Clauses

```tu
// guard (deve divergir: return, throw, break, continue)
fn process(input: String?) -> String {
  guard let value = input else {
    return "empty"
  }
  // value é String (unwrapped) daqui pra frente
  value.uppercase()
}

// guard com condição
fn withdraw(amount: Float, balance: Float) -> Result<Float, BankError> {
  guard amount > 0.0 else { return .err(.invalidAmount) }
  guard amount <= balance else { return .err(.insufficientFunds) }
  .ok(balance - amount)
}

// if let (scoped unwrap)
if let name = user.nickname {
  print("Nick: ${name}")
} else {
  print("No nickname")
}

// if let com pattern
if let .ok(value) = fetchData() {
  print("Got: ${value}")
}
```

---

## 6. Structs (Valor)

```tu
// Structs são value types: copiadas na atribuição, imutáveis por padrão
struct Point {
  x: Float
  y: Float
}

// Instanciação (sem "new")
let p = Point(x: 1.0, y: 2.0)

// Copiar com modificação (copy-with syntax)
let moved = p.{ x: p.x + 10.0 }

// Métodos (não mutam — retornam novo valor)
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

// Struct com generics
struct Pair<A, B> {
  first: A
  second: B
}
```

---

## 7. Classes (Referência)

```tu
// Classes são reference types, mutáveis
class Counter {
  var count: Int

  init(start: Int = 0) {
    count = start
  }

  fn increment() {
    count += 1
  }

  fn reset() {
    count = 0
  }
}

let c = Counter(start: 10)
c.increment()   // muta in-place (referência)

// Herança
class Animal {
  let name: String
  init(name: String) { self.name = name }
  fn speak() -> String => "..."
}

class Dog : Animal {
  override fn speak() -> String => "Woof!"
}
```

---

## 8. Enums (Algebraic Data Types)

```tu
// Enum simples
enum Direction { north, south, east, west }

// Enum com valores associados (ADT / tagged union)
enum Shape {
  circle(radius: Float),
  rect(width: Float, height: Float),
  point,
}

fn area(shape: Shape) -> Float => match shape {
  .circle(r)    => PI * r * r,
  .rect(w, h)   => w * h,
  .point         => 0.0,
}

// Result e Optional são enums built-in:
// enum Result<T, E> { ok(T), err(E) }
// enum Optional<T> { some(T), none }
```

---

## 9. Traits (Interfaces com comportamento)

```tu
trait Displayable {
  fn display() -> String
}

trait Hashable {
  fn hash() -> Int
}

// Implementação separada do tipo
struct Color {
  r: Int, g: Int, b: Int
}

impl Displayable for Color {
  fn display() -> String => "rgb(${r}, ${g}, ${b})"
}

// Trait com implementação default
trait Printable {
  fn toString() -> String
  fn print() -> Void {
    print(self.toString())
  }
}

// Trait bounds em generics
fn show<T: Displayable>(item: T) -> String => item.display()

// Múltiplos bounds
fn process<T: Displayable + Hashable>(item: T) { ... }
```

---

## 10. Extensions (estilo Swift)

```tu
struct Point {
  x: Float
  y: Float
}

// Adicionar métodos em qualquer lugar (mesmo outro arquivo)
extension Point {
  fn magnitude() -> Float {
    (x * x + y * y)
  }

  fn translated(dx: Float, dy: Float) -> Point {
    Point(x: x + dx, y: y + dy)
  }
}

// Múltiplas extensions no mesmo tipo
extension Point {
  fn isOrigin() -> Bool {
    x == 0.0 && y == 0.0
  }
}

// Extension com conformidade a trait
extension Point : Displayable {
  fn display() -> String {
    "Point"
  }
}

// Extension em enums
extension Direction {
  fn opposite() -> Direction => match self {
    .north => Direction.south,
    .south => Direction.north,
    .east  => Direction.west,
    .west  => Direction.east,
  }
}
```

Extensions podem:
- Adicionar métodos a structs, classes e enums
- Acessar campos do tipo (`x`, `y`) e `self` diretamente
- Ser divididas em quantos blocos quiser (organização por responsabilidade)
- Opcionalmente adicionar conformidade a traits

---

## 11. Pipe Operator e Composição

```tu
// Pipe forward
let result = data
  |> filter((x) => x > 0)
  |> map((x) => x * 2)
  |> reduce(0, (a, b) => a + b)

// Composição de funções
let transform = uppercase >> trim >> capitalize
let name = transform("  hello  ")

// Partial application
fn add(a: Int, b: Int) -> Int => a + b
let add5 = add(5, _)    // (Int) -> Int
add5(3)                  // 8
```

---

## 11. Custom Operators

```tu
// Definir operador binário
operator ** (base: Float, exp: Float) -> Float
  precedence 15 right
{
  base.pow(exp)
}

let x = 2.0 ** 10.0   // 1024.0

// Definir operador em tipo
impl Point {
  operator + (other: Point) -> Point {
    Point(x: x + other.x, y: y + other.y)
  }

  operator * (scalar: Float) -> Point {
    Point(x: x * scalar, y: y * scalar)
  }
}

let p = Point(x: 1.0, y: 2.0) + Point(x: 3.0, y: 4.0)
```

---

## 12. Unsafe (Aritmética de Ponteiros)

```tu
// unsafe é explícito e isolado — não é o modo normal
unsafe {
  let ptr: Ptr<Int> = alloc(10)   // aloca 10 Ints
  ptr[0] = 42
  ptr[1] = 99
  let sum = ptr[0] + ptr[1]
  free(ptr)
}

// Ponteiros não escapam de unsafe sem cast explícito
// Útil pra FFI, buffers de performance, interop C
```

---

## 13. Módulos e Imports

```tu
// Arquivo = módulo implícito
// math.tu
pub fn abs(x: Float) -> Float => if x < 0.0 { -x } else { x }

// Importar
use math                        // importa tudo público
use math.{ abs, round }         // importa específico
use math as m                   // alias
```

---

## 14. String Interpolation e Multiline

```tu
let name = "world"
let greeting = "Hello ${name}!"

// Expressão complexa
let msg = "Result: ${if x > 0 { "positive" } else { "negative" }}"

// Multiline
let html = """
  <div class="card">
    <h1>${title}</h1>
  </div>
"""
```

---

## 15. Coleções

```tu
// List (imutável por padrão)
let nums = [1, 2, 3, 4, 5]
let doubled = nums.map((x) => x * 2)      // [2, 4, 6, 8, 10]

// List mutável
var items: mut List<String> = ["a", "b"]
items.push("c")

// Map
let scores = { "alice": 95, "bob": 87 }

// Set
let unique = {1, 2, 3}

// Range
let range = 0..10        // exclusive: 0 até 9
let range = 0..=10       // inclusive: 0 até 10

// Comprehension
let evens = [for x in 0..100 if x % 2 == 0 => x]
```

---

## Mapeamento para Dart Kernel

| Itá                | Dart Kernel Node              |
|--------------------|-------------------------------|
| `let x = 1`       | VariableDeclaration (final)   |
| `var x = 1`       | VariableDeclaration (mutable) |
| `fn foo()`        | Procedure + FunctionNode      |
| `struct`          | Class (sem referência)        |
| `class`           | Class                         |
| `enum`            | Class (sealed) + subclasses   |
| `trait`           | Class (abstract)              |
| `impl X for Y`   | Extension / mixin application |
| `match`           | SwitchExpression / PatternSwitchStatement |
| `guard let`       | IfCaseStatement + early return|
| `if let`          | IfCaseStatement               |
| `Result<T,E>`     | Sealed class + ok/err         |
| `T?`              | Nullable type                 |
| `|>`              | Nested StaticInvocation       |
| `unsafe {}`       | dart:ffi calls                |
| `operator +`      | Method com operatorName       |
| closure           | FunctionExpression            |
