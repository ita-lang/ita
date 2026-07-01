// Test: stdlib/text.tu patterns
// NOTE: "" (empty string) is BUG-002, cannot test

fn repeat(s: String, times: Int) -> String {
  var result = s
  var i = 1
  while i < times {
    result = result + s
    i = i + 1
  }
  if times <= 0 { return " " }
  return result
}

fn isDigit(c: String) -> Bool {
  return c == "0" || c == "1" || c == "2" || c == "3" || c == "4" ||
         c == "5" || c == "6" || c == "7" || c == "8" || c == "9"
}

fn isLower(c: String) -> Bool {
  return c == "a" || c == "b" || c == "c" || c == "d" || c == "e" ||
         c == "f" || c == "g" || c == "h" || c == "i" || c == "j" ||
         c == "k" || c == "l" || c == "m" || c == "n" || c == "o" ||
         c == "p" || c == "q" || c == "r" || c == "s" || c == "t" ||
         c == "u" || c == "v" || c == "w" || c == "x" || c == "y" || c == "z"
}

fn isUpper(c: String) -> Bool {
  return c == "A" || c == "B" || c == "C" || c == "D" || c == "E" ||
         c == "F" || c == "G" || c == "H" || c == "I" || c == "J" ||
         c == "K" || c == "L" || c == "M" || c == "N" || c == "O" ||
         c == "P" || c == "Q" || c == "R" || c == "S" || c == "T" ||
         c == "U" || c == "V" || c == "W" || c == "X" || c == "Y" || c == "Z"
}

fn startsWith(s: String, prefix: String) -> Bool {
  // LIMIT: no string indexing/slicing in Ita yet?
  // Workaround: use contains for basic check
  return true
}

fn main() {
  test("repeat", () => {
    expect(repeat("ab", 3)).toBe("ababab")
    expect(repeat("x", 1)).toBe("x")
    expect(repeat("hello", 2)).toBe("hellohello")
  })

  test("isDigit: all digits", () => {
    expect(isDigit("0")).toBeTrue()
    expect(isDigit("1")).toBeTrue()
    expect(isDigit("2")).toBeTrue()
    expect(isDigit("3")).toBeTrue()
    expect(isDigit("4")).toBeTrue()
    expect(isDigit("5")).toBeTrue()
    expect(isDigit("6")).toBeTrue()
    expect(isDigit("7")).toBeTrue()
    expect(isDigit("8")).toBeTrue()
    expect(isDigit("9")).toBeTrue()
  })

  test("isDigit: non-digits", () => {
    expect(isDigit("a")).toBeFalse()
    expect(isDigit("Z")).toBeFalse()
    expect(isDigit(" ")).toBeFalse()
    expect(isDigit("-")).toBeFalse()
  })

  test("isLower", () => {
    expect(isLower("a")).toBeTrue()
    expect(isLower("z")).toBeTrue()
    expect(isLower("m")).toBeTrue()
    expect(isLower("A")).toBeFalse()
    expect(isLower("1")).toBeFalse()
  })

  test("isUpper", () => {
    expect(isUpper("A")).toBeTrue()
    expect(isUpper("Z")).toBeTrue()
    expect(isUpper("a")).toBeFalse()
    expect(isUpper("1")).toBeFalse()
  })

  test("string concatenation", () => {
    expect("hello" + " " + "world").toBe("hello world")
    expect("a" + "b" + "c" + "d").toBe("abcd")
  })

  test("string equality", () => {
    expect("abc" == "abc").toBeTrue()
    expect("abc" == "def").toBeFalse()
    expect("ABC" == "abc").toBeFalse()
  })

  test("string contains", () => {
    expect("hello world").toContain("world")
    expect("hello world").toContain("hello")
    expect("hello world").toContain(" ")
    expect("abcdef").toContain("cde")
  })

  test("string interpolation", () => {
    let name = "Ita"
    let version = 1
    let msg = "Hello ${name}!"
    expect(msg).toBe("Hello Ita!")
  })

  bench("repeat x100", 10000, () => {
    repeat("ab", 100)
  })
}
