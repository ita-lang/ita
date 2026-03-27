// Test: stdlib/math.tu — ALL functions
// Goal: find compiler + stdlib limits

// === Reimplemented from stdlib/math.tu ===

fn abs(x: Int) -> Int {
  if x < 0 { return 0 - x }
  return x
}

fn min(a: Int, b: Int) -> Int {
  if a < b { return a }
  return b
}

fn max(a: Int, b: Int) -> Int {
  if a > b { return a }
  return b
}

fn clamp(value: Int, low: Int, high: Int) -> Int {
  if value < low { return low }
  if value > high { return high }
  return value
}

fn sum(list: List<Int>) -> Int {
  var total = 0
  for item in list { total = total + item }
  return total
}

fn gcd(a: Int, b: Int) -> Int {
  var x = abs(a)
  var y = abs(b)
  while y != 0 {
    let temp = y
    y = x % y
    x = temp
  }
  return x
}

fn lcm(a: Int, b: Int) -> Int {
  if a == 0 || b == 0 { return 0 }
  return abs(a * b) / gcd(a, b)
}

fn isPrime(n: Int) -> Bool {
  if n < 2 { return false }
  if n < 4 { return true }
  if n % 2 == 0 { return false }
  var i = 3
  while i * i <= n {
    if n % i == 0 { return false }
    i = i + 2
  }
  return true
}

fn fibonacci(n: Int) -> Int {
  if n <= 0 { return 0 }
  if n == 1 { return 1 }
  var a = 0
  var b = 1
  var i = 2
  while i <= n {
    let temp = a + b
    a = b
    b = temp
    i = i + 1
  }
  return b
}

fn factorial(n: Int) -> Int {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

fn pow(base: Int, exp: Int) -> Int {
  if exp == 0 { return 1 }
  if exp < 0 { return 0 }
  var result = 1
  var i = 0
  while i < exp {
    result = result * base
    i = i + 1
  }
  return result
}

fn isqrt(n: Int) -> Int {
  if n < 0 { return 0 }
  if n == 0 { return 0 }
  var x = n
  var y = (x + 1) / 2
  while y < x {
    x = y
    y = (x + n / x) / 2
  }
  return x
}

fn sign(x: Int) -> Int {
  if x > 0 { return 1 }
  if x < 0 { return -1 }
  return 0
}

fn isEven(n: Int) -> Bool => n % 2 == 0
fn isOdd(n: Int) -> Bool => n % 2 != 0

fn range(start: Int, end: Int) -> List<Int> {
  var result: List<Int> = []
  var i = start
  while i < end {
    result = result + [i]
    i = i + 1
  }
  return result
}

fn main() {
  // === abs ===
  test("abs: positive", () => { expect(abs(5)).toBe(5) })
  test("abs: negative", () => { expect(abs(-5)).toBe(5) })
  test("abs: zero", () => { expect(abs(0)).toBe(0) })
  test("abs: large negative", () => { expect(abs(-999999)).toBe(999999) })

  // === min/max ===
  test("min: basic", () => {
    expect(min(3, 7)).toBe(3)
    expect(min(7, 3)).toBe(3)
    expect(min(5, 5)).toBe(5)
  })
  test("min: negatives", () => {
    expect(min(-3, -7)).toBe(-7)
    expect(min(-1, 0)).toBe(-1)
  })
  test("max: basic", () => {
    expect(max(3, 7)).toBe(7)
    expect(max(-1, -5)).toBe(-1)
    expect(max(0, 0)).toBe(0)
  })

  // === clamp ===
  test("clamp: in range", () => { expect(clamp(5, 0, 10)).toBe(5) })
  test("clamp: below", () => { expect(clamp(-5, 0, 10)).toBe(0) })
  test("clamp: above", () => { expect(clamp(15, 0, 10)).toBe(10) })
  test("clamp: at boundaries", () => {
    expect(clamp(0, 0, 10)).toBe(0)
    expect(clamp(10, 0, 10)).toBe(10)
  })

  // === sum ===
  test("sum: basic", () => { expect(sum([1, 2, 3, 4, 5])).toBe(15) })
  test("sum: negatives", () => { expect(sum([-1, -2, -3])).toBe(-6) })
  test("sum: mixed", () => { expect(sum([-5, 0, 5])).toBe(0) })
  test("sum: single", () => { expect(sum([42])).toBe(42) })
  test("sum: empty", () => { expect(sum([])).toBe(0) })

  // === gcd ===
  test("gcd: basic", () => {
    expect(gcd(12, 8)).toBe(4)
    expect(gcd(100, 75)).toBe(25)
    expect(gcd(7, 13)).toBe(1)
  })
  test("gcd: with zero", () => {
    expect(gcd(0, 5)).toBe(5)
    expect(gcd(5, 0)).toBe(5)
    expect(gcd(0, 0)).toBe(0)
  })
  test("gcd: same number", () => { expect(gcd(15, 15)).toBe(15) })
  test("gcd: coprime", () => { expect(gcd(17, 31)).toBe(1) })

  // === lcm ===
  test("lcm: basic", () => {
    expect(lcm(4, 6)).toBe(12)
    expect(lcm(3, 5)).toBe(15)
    expect(lcm(7, 7)).toBe(7)
  })
  test("lcm: with zero", () => { expect(lcm(0, 5)).toBe(0) })

  // === isPrime ===
  test("isPrime: primes", () => {
    expect(isPrime(2)).toBeTrue()
    expect(isPrime(3)).toBeTrue()
    expect(isPrime(5)).toBeTrue()
    expect(isPrime(7)).toBeTrue()
    expect(isPrime(11)).toBeTrue()
    expect(isPrime(97)).toBeTrue()
    expect(isPrime(997)).toBeTrue()
  })
  test("isPrime: non-primes", () => {
    expect(isPrime(0)).toBeFalse()
    expect(isPrime(1)).toBeFalse()
    expect(isPrime(4)).toBeFalse()
    expect(isPrime(9)).toBeFalse()
    expect(isPrime(100)).toBeFalse()
    expect(isPrime(999)).toBeFalse()
  })
  test("isPrime: negative", () => { expect(isPrime(-7)).toBeFalse() })

  // === fibonacci ===
  test("fibonacci: base cases", () => {
    expect(fibonacci(0)).toBe(0)
    expect(fibonacci(1)).toBe(1)
    expect(fibonacci(2)).toBe(1)
  })
  test("fibonacci: sequence", () => {
    expect(fibonacci(3)).toBe(2)
    expect(fibonacci(4)).toBe(3)
    expect(fibonacci(5)).toBe(5)
    expect(fibonacci(6)).toBe(8)
    expect(fibonacci(7)).toBe(13)
    expect(fibonacci(10)).toBe(55)
    expect(fibonacci(20)).toBe(6765)
  })
  test("fibonacci: negative", () => { expect(fibonacci(-1)).toBe(0) })

  // === factorial ===
  test("factorial: base", () => {
    expect(factorial(0)).toBe(1)
    expect(factorial(1)).toBe(1)
  })
  test("factorial: sequence", () => {
    expect(factorial(5)).toBe(120)
    expect(factorial(10)).toBe(3628800)
  })

  // === pow ===
  test("pow: basic", () => {
    expect(pow(2, 0)).toBe(1)
    expect(pow(2, 1)).toBe(2)
    expect(pow(2, 10)).toBe(1024)
    expect(pow(3, 3)).toBe(27)
    expect(pow(10, 3)).toBe(1000)
  })
  test("pow: zero base", () => { expect(pow(0, 5)).toBe(0) })
  test("pow: one base", () => { expect(pow(1, 100)).toBe(1) })

  // === isqrt ===
  test("isqrt: perfect squares", () => {
    expect(isqrt(0)).toBe(0)
    expect(isqrt(1)).toBe(1)
    expect(isqrt(4)).toBe(2)
    expect(isqrt(9)).toBe(3)
    expect(isqrt(16)).toBe(4)
    expect(isqrt(100)).toBe(10)
  })
  test("isqrt: non-perfect", () => {
    expect(isqrt(2)).toBe(1)
    expect(isqrt(8)).toBe(2)
    expect(isqrt(15)).toBe(3)
  })
  test("isqrt: negative", () => { expect(isqrt(-4)).toBe(0) })

  // === sign ===
  test("sign: positive", () => { expect(sign(42)).toBe(1) })
  test("sign: negative", () => { expect(sign(-42)).toBe(-1) })
  test("sign: zero", () => { expect(sign(0)).toBe(0) })

  // === isEven/isOdd ===
  test("isEven", () => {
    expect(isEven(0)).toBeTrue()
    expect(isEven(2)).toBeTrue()
    expect(isEven(-4)).toBeTrue()
    expect(isEven(1)).toBeFalse()
    expect(isEven(-3)).toBeFalse()
  })
  test("isOdd", () => {
    expect(isOdd(1)).toBeTrue()
    expect(isOdd(-3)).toBeTrue()
    expect(isOdd(0)).toBeFalse()
    expect(isOdd(2)).toBeFalse()
  })

  // === range ===
  test("range: basic", () => {
    let r = range(0, 5)
    expect(sum(r)).toBe(10)
  })
  test("range: empty", () => {
    let r = range(5, 5)
    expect(sum(r)).toBe(0)
  })
  test("range: negative", () => {
    let r = range(-2, 3)
    expect(sum(r)).toBe(0)
  })

  // === Benchmarks ===
  bench("fibonacci(30)", 1000, () => { fibonacci(30) })
  bench("isPrime(104729)", 10000, () => { isPrime(104729) })
  bench("factorial(12)", 100000, () => { factorial(12) })
  bench("isqrt(1000000)", 100000, () => { isqrt(1000000) })

  stress("gcd stress", 2000, () => { gcd(123456789, 987654321) })
}
