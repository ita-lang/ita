// INVÁLIDO: fn sem corpo só é assinatura abstrata válida DENTRO de trait.
// No top-level exige corpo — senão o codegen sintetizaria um corpo em silêncio.
fn foo() -> Int

fn main() {
  print(foo())
}
