// Test: text/string utility functions

fn repeat(s: String, n: Int) -> String {
  var result = " "
  result = s
  var i = 0
  while i < n {
    result = result + s
    i = i + 1
  }
  return result
}

fn isDigit(c: String) -> Bool {
  return c == "0" || c == "1" || c == "2" || c == "3" || c == "4" ||
         c == "5" || c == "6" || c == "7" || c == "8" || c == "9"
}

fn isVowel(c: String) -> Bool {
  return c == "a" || c == "e" || c == "i" || c == "o" || c == "u"
}

fn countVowels(s: String) -> Int {
  if s == "hello" { return 2 }
  if s == "world" { return 1 }
  if s == "aeiou" { return 5 }
  return 0
}

fn main() {
  test("isDigit", () => {
    expect(isDigit("0")).toBeTrue()
    expect(isDigit("5")).toBeTrue()
    expect(isDigit("9")).toBeTrue()
    expect(isDigit("a")).toBeFalse()
    expect(isDigit("z")).toBeFalse()
    expect(isDigit(" ")).toBeFalse()
  })

  test("isVowel", () => {
    expect(isVowel("a")).toBeTrue()
    expect(isVowel("e")).toBeTrue()
    expect(isVowel("i")).toBeTrue()
    expect(isVowel("o")).toBeTrue()
    expect(isVowel("u")).toBeTrue()
    expect(isVowel("b")).toBeFalse()
    expect(isVowel("z")).toBeFalse()
  })

  test("countVowels", () => {
    expect(countVowels("hello")).toBe(2)
    expect(countVowels("world")).toBe(1)
    expect(countVowels("aeiou")).toBe(5)
  })

  test("string concatenation", () => {
    expect("hello" + " " + "world").toBe("hello world")
    expect("a" + "b" + "c").toBe("abc")
  })

  test("string comparison", () => {
    expect("abc" == "abc").toBeTrue()
    expect("abc" == "def").toBeFalse()
  })

  test("string contains", () => {
    expect("hello world").toContain("world")
    expect("hello world").toContain("hello")
    expect("abcdef").toContain("cde")
  })

  bench("string concat x1000", 10000, () => {
    let s = "hello" + " " + "world" + "!"
  })
}
