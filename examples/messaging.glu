// Messaging Primitives — com isolates reais!

fn onChannelMsg(msg) {
  print("  Channel: ${msg}")
}

fn subA(msg) {
  print("  A: ${msg}")
}

fn subB(msg) {
  print("  B: ${msg}")
}

fn workerFn(task) {
  print("  Worker: ${task}")
}

async fn main() {
  print("=== Channel (cross-isolate) ===")

  // Channel = ReceivePort (cross-isolate pipe)
  let ch = Channel.create()
  let port = Channel.port(ch)

  // Listener no main isolate
  Channel.listen(ch, onChannelMsg)

  // Enviar (de qualquer isolate via sendPort)
  Channel.send(port, "hello from isolate")
  Channel.send(port, "second msg")

  print("=== Broadcast (broker isolate) ===")

  // Broker roda em isolate dedicado
  let bus = await Broadcast.create()

  // Subscribers recebem via seus próprios ReceivePorts
  Broadcast.subscribe(bus, subA)
  Broadcast.subscribe(bus, subB)

  // Publish — broker distribui pra todos
  Broadcast.publish(bus, "event-1")
  Broadcast.publish(bus, "event-2")

  print("=== Mailbox (job queue) ===")

  let box = Mailbox.create()
  let boxPort = Mailbox.port(box)

  // Worker consome
  Mailbox.listen(box, workerFn)

  // Producer envia jobs
  Mailbox.put(boxPort, "job-A")
  Mailbox.put(boxPort, "job-B")

  print("=== Done! ===")
}
