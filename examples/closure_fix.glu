// Teste de closures multiline com => { ... }

fn doWork(callback) {
  callback("hello")
  callback("world")
}

fn applyAndPrint(items, transform) {
  for item in items {
    let result = transform(item)
    print(result)
  }
}

fn main() {
  print("=== Arrow closure single expr ===")
  let double = (x: Int) => x * 2
  print(double(5))
  print(double(21))

  print("=== Arrow closure with block ===")
  let process = (msg: String) => {
    let upper = msg + "!"
    print("Processing: ${upper}")
  }
  process("test")

  print("=== Callback with block ===")
  doWork((msg) => {
    let decorated = "[${msg}]"
    print(decorated)
  })

  print("=== Transform with block ===")
  let nums = [1, 2, 3, 4, 5]
  applyAndPrint(nums, (x) => {
    let squared = x * x
    return squared + 1
  })

  print("=== Server-style callback ===")
  // Simula o pattern que falhava antes
  let items = ["a", "b", "c"]
  for item in items {
    let handler = (data) => {
      let result = data + "-processed"
      print(result)
    }
    handler(item)
  }

  print("=== Done! ===")
}
