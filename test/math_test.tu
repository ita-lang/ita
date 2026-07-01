// Test: math operations and assertions

fn add(a: Int, b: Int) -> Int => a + b
fn multiply(a: Int, b: Int) -> Int => a * b
fn factorial(n: Int) -> Int {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

fn main() {
  test("addition", () => {
    expect(1 + 1).toBe(2)
    expect(add(3, 4)).toBe(7)
    expect(add(0, 0)).toBe(0)
  })

  test("multiplication", () => {
    expect(3 * 4).toBe(12)
    expect(multiply(5, 6)).toBe(30)
  })

  test("factorial", () => {
    expect(factorial(1)).toBe(1)
    expect(factorial(5)).toBe(120)
    expect(factorial(10)).toBe(3628800)
  })

  test("comparison operators", () => {
    expect(10 > 5).toBeTrue()
    expect(3 < 1).toBeFalse()
    expect(42).toBeGreaterThan(10)
    expect(1).toBeLessThan(100)
  })

  test("string operations", () => {
    expect("hello world").toContain("world")
    expect("Ita language").toContain("Ita")
  })

  bench("factorial(10)", 10000, () => {
    factorial(10)
  })

  bench("add(100, 200)", 100000, () => {
    add(100, 200)
  })

  stress("factorial under load", 500, () => {
    factorial(10)
  })
}
