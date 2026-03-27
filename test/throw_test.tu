// Test: toThrow isolation

fn throwingFn() {
  panic("intentional error")
}

fn safeFn() {
  let x = 42
}

fn main() {
  test("toThrow com funcao nomeada", () => {
    expect(throwingFn).toThrow()
  })

  test("toNotThrow com funcao nomeada", () => {
    expect(safeFn).toNotThrow()
  })
}
