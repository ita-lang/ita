// Timer + Signal — scheduling e graceful shutdown

fn onTick(timer) {
  print("  tick!")
}

fn onShutdown() {
  print("Graceful shutdown!")
  exit(0)
}

async fn main() {
  print("=== Timer.delay (one-shot) ===")
  print("Waiting 100ms...")
  await Timer.delay(100)
  print("Done waiting!")

  print("=== sleep() shortcut ===")
  await sleep(50)
  print("Slept 50ms")

  print("=== Timer.interval (repeating) ===")
  let t = Timer.interval(100, onTick)

  // Esperar 350ms (3 ticks)
  await sleep(350)
  Timer.cancel(t)
  print("Timer cancelled")

  print("=== Signal.onInterrupt ===")
  Signal.onInterrupt(onShutdown)
  print("Press Ctrl+C to test graceful shutdown")
  print("(or wait 500ms for auto-exit)")

  await sleep(500)
  print("=== Done! ===")
}
