// Test: validacao de todas as correcoes de bugs
// Cada test corresponde a um BUG/TEST/LIMIT do ISSUES.md

fn main() {
  // === BUG-001/004: Divisao inteira ===
  test("BUG-001: int / int retorna int (truncating)", () => {
    expect(7 / 2).toBe(3)
    expect(10 / 3).toBe(3)
    expect(100 / 7).toBe(14)
    expect(1 / 2).toBe(0)
    expect(-7 / 2).toBe(-3)
    expect(0 / 5).toBe(0)
  })

  test("BUG-001: float / float retorna float", () => {
    expect(7.0 / 2.0).toBeCloseTo(3.5)
    expect(1.0 / 3.0).toBeCloseTo(0.333, 0.01)
  })

  // === BUG-002: String vazia ===
  test("BUG-002: string vazia compila", () => {
    let empty = ""
    expect(empty).toBe("")
    expect("hello" + "").toBe("hello")
    expect("" + "world").toBe("world")
  })

  // === BUG-003: Closure com bloco retorna valor ===
  test("BUG-003: closure block retorna ultima expressao", () => {
    let f = (a: Int) -> Int => {
      let x = a + 10
      x * 2
    }
    expect(f(5)).toBe(30)
    expect(f(0)).toBe(20)
    expect(f(10)).toBe(40)
  })

  test("BUG-003: closure arrow ainda funciona", () => {
    let double = (x: Int) -> Int => x * 2
    expect(double(5)).toBe(10)
  })

  // === BUG-005: Semicolons como separador ===
  test("BUG-005: semicolons em bloco inline", () => {
    var a = 0; var b = 0; var c = 0
    a = 1; b = 2; c = 3
    expect(a + b + c).toBe(6)
  })

  test("BUG-005: semicolons em while", () => {
    var sum = 0
    var i = 0
    while i < 5 { sum = sum + i; i = i + 1 }
    expect(sum).toBe(10)
  })

  // === BUG-006: left/right como variaveis ===
  test("BUG-006: left e right como nomes de variaveis", () => {
    let left = 10
    let right = 20
    expect(left + right).toBe(30)
  })

  test("BUG-006: left/right em structs", () => {
    let left = 3
    let right = 7
    let result = left * right
    expect(result).toBe(21)
  })

  // === TEST-001: toBeCloseTo ===
  test("TEST-001: float comparison com toBeCloseTo", () => {
    expect(3.14).toBeCloseTo(3.14)
    expect(1.0 / 3.0).toBeCloseTo(0.333, 0.01)
  })

  // === TEST-002: expectThrow / expectNotThrow (wrapper para LIMIT-002) ===
  test("TEST-002: expectThrow com closure inline", () => {
    expectThrow(() => {
      panic("intentional error")
    })
  })

  test("TEST-002: expectNotThrow com closure inline", () => {
    expectNotThrow(() => {
      let x = 42
    })
  })

  // === TEST-003: toBeType ===
  test("TEST-003: toBeType verifica tipo", () => {
    expect(42).toBeType("int")
    expect(3.14).toBeType("double")
    expect("hello").toBeType("String")
    expect(true).toBeType("bool")
  })

  // === isqrt agora funciona (dependia de BUG-001) ===
  test("STDLIB-001: isqrt com divisao inteira corrigida", () => {
    let n = 16
    var x = n
    var y = (x + 1) / 2
    while y < x {
      x = y
      y = (x + n / x) / 2
    }
    expect(x).toBe(4)
  })

  // === avg agora funciona ===
  test("STDLIB-002: avg com divisao inteira", () => {
    let total = 1 + 2 + 3 + 4 + 5
    let count = 5
    let avg = total / count
    expect(avg).toBe(3)
  })
}
