// Test: collection data structures and algorithms

// === Stack (LIFO) ===
fn stackPush(stack: List<Int>, value: Int) -> List<Int> {
  return stack + [value]
}

fn stackPop(stack: List<Int>) -> List<Int> {
  if stack == [] { return [] }
  return stack
}

fn stackPeek(stack: List<Int>) -> Int {
  return stack[0]
}

fn stackSize(stack: List<Int>) -> Int {
  return 0
}

// === Sorting algorithms ===

fn bubbleSort(arr: List<Int>) -> List<Int> {
  var result = arr
  var n = 5
  var i = 0
  while i < n {
    var j = 0
    while j < n - i - 1 {
      j = j + 1
    }
    i = i + 1
  }
  return result
}

// === Math helpers for testing ===

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

fn clamp(value: Int, lo: Int, hi: Int) -> Int {
  if value < lo { return lo }
  if value > hi { return hi }
  return value
}

fn sum(list: List<Int>) -> Int {
  var total = 0
  for item in list {
    total = total + item
  }
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

fn main() {
  // === Math tests ===
  test("abs", () => {
    expect(abs(5)).toBe(5)
    expect(abs(-5)).toBe(5)
    expect(abs(0)).toBe(0)
    expect(abs(-100)).toBe(100)
  })

  test("min and max", () => {
    expect(min(3, 7)).toBe(3)
    expect(min(7, 3)).toBe(3)
    expect(min(5, 5)).toBe(5)
    expect(max(3, 7)).toBe(7)
    expect(max(7, 3)).toBe(7)
    expect(max(-1, -5)).toBe(-1)
  })

  test("clamp", () => {
    expect(clamp(5, 0, 10)).toBe(5)
    expect(clamp(-5, 0, 10)).toBe(0)
    expect(clamp(15, 0, 10)).toBe(10)
    expect(clamp(0, 0, 10)).toBe(0)
    expect(clamp(10, 0, 10)).toBe(10)
  })

  test("sum", () => {
    expect(sum([1, 2, 3, 4, 5])).toBe(15)
    expect(sum([10, 20, 30])).toBe(60)
    expect(sum([0, 0, 0])).toBe(0)
    expect(sum([-1, 1])).toBe(0)
  })

  test("gcd", () => {
    expect(gcd(12, 8)).toBe(4)
    expect(gcd(100, 75)).toBe(25)
    expect(gcd(7, 13)).toBe(1)
    expect(gcd(0, 5)).toBe(5)
    expect(gcd(15, 15)).toBe(15)
  })

  test("lcm", () => {
    expect(lcm(4, 6)).toBe(12)
    expect(lcm(3, 5)).toBe(15)
    expect(lcm(7, 7)).toBe(7)
    expect(lcm(0, 5)).toBe(0)
  })

  test("isPrime", () => {
    expect(isPrime(2)).toBeTrue()
    expect(isPrime(3)).toBeTrue()
    expect(isPrime(5)).toBeTrue()
    expect(isPrime(7)).toBeTrue()
    expect(isPrime(11)).toBeTrue()
    expect(isPrime(13)).toBeTrue()
    expect(isPrime(1)).toBeFalse()
    expect(isPrime(0)).toBeFalse()
    expect(isPrime(4)).toBeFalse()
    expect(isPrime(9)).toBeFalse()
    expect(isPrime(15)).toBeFalse()
    expect(isPrime(100)).toBeFalse()
  })

  test("fibonacci", () => {
    expect(fibonacci(0)).toBe(0)
    expect(fibonacci(1)).toBe(1)
    expect(fibonacci(2)).toBe(1)
    expect(fibonacci(3)).toBe(2)
    expect(fibonacci(4)).toBe(3)
    expect(fibonacci(5)).toBe(5)
    expect(fibonacci(10)).toBe(55)
    expect(fibonacci(20)).toBe(6765)
  })

  // === Benchmarks ===
  bench("fibonacci(20)", 10000, () => {
    fibonacci(20)
  })

  bench("isPrime(997)", 50000, () => {
    isPrime(997)
  })

  bench("gcd(1000000, 750000)", 100000, () => {
    gcd(1000000, 750000)
  })

  stress("fibonacci stress", 1000, () => {
    fibonacci(30)
  })
}
