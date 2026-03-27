// Prova que actors rodam em isolates separados
// Isolate.run executa a closure num isolate novo

actor HeavyWorker {
  fn compute(n: Int) -> Int {
    // Computação pesada simulada
    var result = 0
    var i = 0
    while i < n {
      result = result + i * i
      i = i + 1
    }
    result
  }

  fn identify() -> String {
    "I am a worker"
  }
}

fn localCompute(n: Int) -> Int {
  var result = 0
  var i = 0
  while i < n {
    result = result + i * i
    i = i + 1
  }
  result
}

async fn main() {
  print("=== Isolate Real ===")

  // Computação local (main isolate)
  let localResult = localCompute(100)
  print("Local: ${localResult}")

  // Computação via actor (Isolate.run)
  let worker = spawn HeavyWorker()

  let isolateResult = await worker.compute(100)
  print("Isolate: ${isolateResult}")

  // Devem ser iguais!
  if localResult == isolateResult {
    print("MATCH! Isolate produziu o mesmo resultado")
  } else {
    print("MISMATCH! Algo deu errado")
  }

  let msg = await worker.identify()
  print(msg)

  // Múltiplas chamadas ao actor
  let r1 = await worker.compute(10)
  let r2 = await worker.compute(20)
  let r3 = await worker.compute(50)
  print("r1=${r1}, r2=${r2}, r3=${r3}")

  print("=== Done! ===")
}
