// CSV — parse e stringify com suporte a delimitadores BR/EU

fn main() {
  print("=== CSV Parse (vírgula) ===")

  let data = Csv.parse("nome,idade,cidade\nAlice,30,São Paulo\nBob,25,Rio")
  print(data)

  // Acessar campos
  for row in data {
    print(row)
  }

  print("=== CSV Parse (ponto-e-vírgula BR/EU) ===")

  let brData = Csv.parse("nome;idade;cidade\nCarlos;28;Curitiba\nDiana;32;BH", ";")
  for row in brData {
    print(row)
  }

  print("=== CSV Stringify ===")

  let table = [["produto", "preço", "qty"], ["Café", "12.50", "100"], ["Chá", "8.00", "200"]]
  let csvStr = Csv.stringify(table)
  print(csvStr)

  print("=== CSV Stringify (;) ===")

  let brStr = Csv.stringify(table, ";")
  print(brStr)

  print("=== CSV File I/O ===")

  // Escrever CSV
  Csv.writeFile("/tmp/glu_test.csv", table)

  // Ler de volta
  let loaded = Csv.parseFile("/tmp/glu_test.csv")
  print("loaded:")
  for row in loaded {
    print(row)
  }
  File.delete("/tmp/glu_test.csv")

  print("=== CSV com aspas ===")

  let quoted = Csv.parse("name,desc\nAlice,\"likes, commas\"\nBob,simple")
  for row in quoted {
    print(row)
  }

  print("=== Done! ===")
}
