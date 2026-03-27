// Test: advanced patterns used by stdlib
// Goal: find limits of generics, Option, Result, struct methods, HOF

// === Option pattern ===
fn optionSome(value: Int) -> Int { return value }
fn optionNone() -> Int? { return nil }
fn optionIsSome(value: Int?) -> Bool { return value != nil }

// === Result pattern (using Int: 0 = error, >0 = success) ===
fn divide(a: Int, b: Int) -> Int {
  if b == 0 { return -1 }
  return a / b
}

// === Higher-order functions ===
fn applyFn(x: Int, f: (Int) -> Int) -> Int {
  return f(x)
}

fn applyTwice(x: Int, f: (Int) -> Int) -> Int {
  return f(f(x))
}

fn compose(x: Int) -> Int {
  // Simulating f >> g
  let doubled = x * 2
  let incremented = doubled + 1
  return incremented
}

// === Recursive data processing ===
fn sumRecursive(list: List<Int>, index: Int) -> Int {
  if index < 0 { return 0 }
  var total = 0
  for item in list { total = total + item }
  return total
}

// === Struct with methods pattern ===
struct Counter {
  value: Int
}

fn counterNew() -> Counter => Counter(value: 0)
fn counterIncrement(c: Counter) -> Counter => Counter(value: c.value + 1)
fn counterDecrement(c: Counter) -> Counter => Counter(value: c.value - 1)
fn counterAdd(c: Counter, n: Int) -> Counter => Counter(value: c.value + n)
fn counterReset(c: Counter) -> Counter => Counter(value: 0)

// === Pair/Tuple pattern ===
struct Pair {
  first: Int
  second: Int
}

fn pairSum(p: Pair) -> Int => p.first + p.second
fn pairSwap(p: Pair) -> Pair => Pair(first: p.second, second: p.first)
fn pairMax(p: Pair) -> Int {
  if p.first > p.second { return p.first }
  return p.second
}

// === Nested struct ===
struct Point {
  x: Int
  y: Int
}

struct Rect {
  origin: Point
  width: Int
  height: Int
}

fn rectArea(r: Rect) -> Int => r.width * r.height
fn rectPerimeter(r: Rect) -> Int => 2 * (r.width + r.height)

fn main() {
  // === Option ===
  test("option: some", () => {
    let x = optionSome(42)
    expect(x).toBe(42)
  })

  // === Higher-order ===
  test("applyFn", () => {
    let double = (x: Int) -> Int => x * 2
    let square = (x: Int) -> Int => x * x
    expect(applyFn(5, double)).toBe(10)
    expect(applyFn(5, square)).toBe(25)
    expect(applyFn(0, double)).toBe(0)
  })

  test("applyTwice", () => {
    let double = (x: Int) -> Int => x * 2
    expect(applyTwice(3, double)).toBe(12)

    let inc = (x: Int) -> Int => x + 1
    expect(applyTwice(0, inc)).toBe(2)
  })

  test("compose pattern", () => {
    expect(compose(5)).toBe(11)
    expect(compose(0)).toBe(1)
    expect(compose(10)).toBe(21)
  })

  // === Counter struct ===
  test("Counter: basic", () => {
    let c = counterNew()
    expect(c.value).toBe(0)

    let c1 = counterIncrement(c)
    expect(c1.value).toBe(1)

    let c2 = counterIncrement(c1)
    expect(c2.value).toBe(2)

    // Original unchanged
    expect(c.value).toBe(0)
  })

  test("Counter: chain", () => {
    let c = counterNew()
    let c1 = counterAdd(counterAdd(counterIncrement(c), 5), 10)
    expect(c1.value).toBe(16)
  })

  test("Counter: decrement", () => {
    let c = counterAdd(counterNew(), 10)
    let c1 = counterDecrement(c)
    expect(c1.value).toBe(9)
  })

  test("Counter: reset", () => {
    let c = counterAdd(counterNew(), 100)
    let c1 = counterReset(c)
    expect(c1.value).toBe(0)
  })

  // === Pair ===
  test("Pair: basic", () => {
    let p = Pair(first: 3, second: 7)
    expect(pairSum(p)).toBe(10)
    expect(pairMax(p)).toBe(7)
  })

  test("Pair: swap", () => {
    let p = Pair(first: 1, second: 2)
    let swapped = pairSwap(p)
    expect(swapped.first).toBe(2)
    expect(swapped.second).toBe(1)
  })

  // === Nested struct ===
  test("Rect: area", () => {
    let r = Rect(origin: Point(x: 0, y: 0), width: 10, height: 5)
    expect(rectArea(r)).toBe(50)
    expect(rectPerimeter(r)).toBe(30)
  })

  test("Rect: field access", () => {
    let r = Rect(origin: Point(x: 3, y: 4), width: 7, height: 8)
    expect(r.width).toBe(7)
    expect(r.height).toBe(8)
    expect(r.origin.x).toBe(3)
    expect(r.origin.y).toBe(4)
  })

  // === Division edge cases ===
  test("divide: normal", () => {
    expect(divide(10, 2)).toBe(5)
    expect(divide(7, 2)).toBe(3)
  })
  test("divide: by zero", () => {
    expect(divide(10, 0)).toBe(-1)
  })

  // === Closure tests ===
  test("closure: capture", () => {
    let x = 42
    let f = (n: Int) -> Int => n + x
    expect(f(8)).toBe(50)
  })

  test("closure: nested", () => {
    let outer = 10
    let f = (a: Int) -> Int => {
      let inner = a + outer
      inner * 2
    }
    expect(f(5)).toBe(30)
  })

  bench("Counter chain x1000", 10000, () => {
    let c = counterNew()
    counterAdd(counterAdd(counterAdd(c, 1), 2), 3)
  })

  bench("Pair operations", 50000, () => {
    let p = Pair(first: 42, second: 99)
    pairSum(p)
    pairSwap(p)
    pairMax(p)
  })
}
