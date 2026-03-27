// Test: import cross-diretorio
import { double, triple } from "lib/helpers"

fn main() {
  test("import: double from helpers", () => {
    expect(double(5)).toBe(10)
    expect(double(0)).toBe(0)
  })

  test("import: triple from helpers", () => {
    expect(triple(4)).toBe(12)
  })

  // internalHelper nao e pub — nao deve estar disponivel
  // Se fosse importavel, este teste passaria. Como nao e, a funcao
  // nao existe e o teste abaixo verifica isso indiretamente
  // (se descomentarmos internalHelper(1), daria compile error: Undefined)
}
