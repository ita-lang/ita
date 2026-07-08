// break / continue (sem rótulo) — controle de fluxo em loops
// Afetam apenas o loop mais interno; válidos em while, for-range e for-in.

fn main() {
  // for-range + break: para ao chegar em 5 → imprime 0..4
  print("for-range break:")
  for i in 0..10 {
    if i == 5 {
      break
    }
    print(i)
  }

  // for-range + continue: pula os pares → imprime só ímpares
  print("for-range continue (ímpares):")
  for i in 0..10 {
    if i % 2 == 0 {
      continue
    }
    print(i)
  }

  // while + break
  print("while break:")
  var n = 0
  while true {
    if n == 3 {
      break
    }
    print(n)
    n += 1
  }

  // for-in sobre lista + continue (pula o 30)
  print("for-in continue (pula 30):")
  let xs = [10, 20, 30, 40, 50]
  for x in xs {
    if x == 30 {
      continue
    }
    print(x)
  }

  // aninhado: o break interno NÃO afeta o loop externo
  print("nested break (interno só):")
  for a in 0..3 {
    for b in 0..3 {
      if b == 1 {
        break
      }
      print("a=" + a.toString() + " b=" + b.toString())
    }
  }

  print("done")
}
