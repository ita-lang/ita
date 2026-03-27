// Teste de I/O completo

fn main() {
  print("=== Output ===")
  println("hello from println")
  eprint("this goes to stderr\n")

  print("=== File I/O ===")
  File.write("/tmp/glu_io_test.txt", "Hello from Glu!")
  let content = File.read("/tmp/glu_io_test.txt")
  print("read: ${content}")

  let exists = File.exists("/tmp/glu_io_test.txt")
  print("exists: ${exists}")

  File.delete("/tmp/glu_io_test.txt")
  let gone = File.exists("/tmp/glu_io_test.txt")
  print("deleted: ${gone}")

  print("=== Dir I/O ===")
  Dir.create("/tmp/glu_test_dir")
  let dirExists = Dir.exists("/tmp/glu_test_dir")
  print("dir exists: ${dirExists}")
  Dir.delete("/tmp/glu_test_dir")

  print("=== Path ===")
  let joined = Path.join("src", "main.glu")
  print("joined: ${joined}")

  let dir = Path.dirname("/src/main.glu")
  print("dirname: ${dir}")

  let ext = Path.ext("main.glu")
  print("ext: ${ext}")

  print("=== Timing ===")
  let start = now()
  var sum = 0
  for i in 0..10000 {
    sum += i
  }
  let end = now()
  print("sum: ${sum}")
  print("time > 0: ${end > start}")

  print("=== Logs ===")
  log.debug("starting up")
  log.info("connected")
  log.warn("slow query")
  log.error("something failed")

  print("=== Done! ===")
}
