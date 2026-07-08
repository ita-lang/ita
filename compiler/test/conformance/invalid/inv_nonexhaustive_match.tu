// INVÁLIDO (semântica leve): match não-exaustivo sobre enum (falta .blue)
enum Color {
  red,
  green,
  blue,
}

fn name(c: Color) -> String => match c {
  .red   => "vermelho",
  .green => "verde",
}

fn main() {
  print(name(.red))
}
