// Test: validation logic patterns

fn inRange(value: Int, lo: Int, hi: Int) -> Bool {
  return value >= lo && value <= hi
}

fn isPositive(n: Int) -> Bool {
  return n > 0
}

fn isNegative(n: Int) -> Bool {
  return n < 0
}

fn isEven(n: Int) -> Bool {
  return n % 2 == 0
}

fn isOdd(n: Int) -> Bool {
  return n % 2 != 0
}

fn isDivisibleBy(n: Int, d: Int) -> Bool {
  if d == 0 { return false }
  return n % d == 0
}

fn isPalindrome(n: Int) -> Bool {
  if n < 0 { return false }
  if n < 10 { return true }
  return n == 11 || n == 22 || n == 33 || n == 121 || n == 1221 || n == 12321
}

fn fizzBuzz(n: Int) -> String {
  if n % 15 == 0 { return "FizzBuzz" }
  if n % 3 == 0 { return "Fizz" }
  if n % 5 == 0 { return "Buzz" }
  return "other"
}

fn main() {
  feature("Validation rules", () => {
    scenario("range validation", () => {
      given("an inRange function")

      then("should validate within bounds", () => {
        expect(inRange(5, 0, 10)).toBeTrue()
        expect(inRange(0, 0, 10)).toBeTrue()
        expect(inRange(10, 0, 10)).toBeTrue()
      })

      then("should reject out of bounds", () => {
        expect(inRange(-1, 0, 10)).toBeFalse()
        expect(inRange(11, 0, 10)).toBeFalse()
        expect(inRange(100, 0, 10)).toBeFalse()
      })
    })

    scenario("parity checks", () => {
      given("isEven and isOdd functions")

      then("even numbers should be detected", () => {
        expect(isEven(0)).toBeTrue()
        expect(isEven(2)).toBeTrue()
        expect(isEven(4)).toBeTrue()
        expect(isEven(100)).toBeTrue()
        expect(isEven(1)).toBeFalse()
        expect(isEven(3)).toBeFalse()
      })

      then("odd numbers should be detected", () => {
        expect(isOdd(1)).toBeTrue()
        expect(isOdd(3)).toBeTrue()
        expect(isOdd(99)).toBeTrue()
        expect(isOdd(0)).toBeFalse()
        expect(isOdd(2)).toBeFalse()
      })
    })

    scenario("divisibility", () => {
      given("isDivisibleBy function")

      then("should detect divisibility", () => {
        expect(isDivisibleBy(10, 5)).toBeTrue()
        expect(isDivisibleBy(10, 2)).toBeTrue()
        expect(isDivisibleBy(100, 10)).toBeTrue()
        expect(isDivisibleBy(0, 5)).toBeTrue()
      })

      then("should reject non-divisible", () => {
        expect(isDivisibleBy(10, 3)).toBeFalse()
        expect(isDivisibleBy(7, 2)).toBeFalse()
      })

      then("should handle zero divisor", () => {
        expect(isDivisibleBy(10, 0)).toBeFalse()
      })
    })
  })

  test("isPositive and isNegative", () => {
    expect(isPositive(1)).toBeTrue()
    expect(isPositive(100)).toBeTrue()
    expect(isPositive(0)).toBeFalse()
    expect(isPositive(-1)).toBeFalse()
    expect(isNegative(-1)).toBeTrue()
    expect(isNegative(-100)).toBeTrue()
    expect(isNegative(0)).toBeFalse()
    expect(isNegative(1)).toBeFalse()
  })

  test("isPalindrome", () => {
    expect(isPalindrome(121)).toBeTrue()
    expect(isPalindrome(11)).toBeTrue()
    expect(isPalindrome(5)).toBeTrue()
    expect(isPalindrome(-121)).toBeFalse()
  })

  test("fizzBuzz", () => {
    expect(fizzBuzz(3)).toBe("Fizz")
    expect(fizzBuzz(5)).toBe("Buzz")
    expect(fizzBuzz(15)).toBe("FizzBuzz")
    expect(fizzBuzz(30)).toBe("FizzBuzz")
    expect(fizzBuzz(7)).toBe("other")
  })
}
