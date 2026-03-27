// Test: language features — recursion, closures, control flow

fn factorial(n: Int) -> Int {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

fn power(base: Int, exp: Int) -> Int {
  if exp == 0 { return 1 }
  return base * power(base, exp - 1)
}

fn applyTwice(x: Int) -> Int {
  return x * 2 * 2
}

fn main() {
  test("factorial", () => {
    expect(factorial(0)).toBe(1)
    expect(factorial(1)).toBe(1)
    expect(factorial(5)).toBe(120)
    expect(factorial(10)).toBe(3628800)
  })

  test("power", () => {
    expect(power(2, 0)).toBe(1)
    expect(power(2, 1)).toBe(2)
    expect(power(2, 10)).toBe(1024)
    expect(power(3, 3)).toBe(27)
    expect(power(10, 3)).toBe(1000)
  })

  test("applyTwice", () => {
    expect(applyTwice(5)).toBe(20)
    expect(applyTwice(0)).toBe(0)
    expect(applyTwice(1)).toBe(4)
  })

  flow("control flow patterns", () => {
    step("while loops", () => {
      var sum = 0
      var i = 1
      while i <= 10 {
        sum = sum + i
        i = i + 1
      }
      expect(sum).toBe(55)
    })

    step("for-in loops", () => {
      var total = 0
      for n in [1, 2, 3, 4, 5] {
        total = total + n
      }
      expect(total).toBe(15)
    })

    step("nested if/else", () => {
      let x = 42
      var label = "unknown"
      if x > 100 {
        label = "big"
      } else {
        if x > 10 {
          label = "medium"
        } else {
          label = "small"
        }
      }
      expect(label).toBe("medium")
    })

    step("variable mutation", () => {
      var count = 0
      count = count + 1
      count = count + 1
      count = count + 1
      expect(count).toBe(3)
    })
  })

  bench("factorial(15)", 50000, () => {
    factorial(15)
  })

  bench("power(2, 20)", 50000, () => {
    power(2, 20)
  })
}
