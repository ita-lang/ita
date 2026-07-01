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

  // Mensagens são entregues de forma assíncrona pelo event loop;
  // dá um tempo pra elas chegarem antes de encerrar.
  await Timer.delay(200)

  // Teardown — fecha as portas/broker que possuímos.
  Channel.close(ch)
  Mailbox.close(box)
  Broadcast.close(bus)

  print("=== Done! ===")

  // exit() explícito: Broadcast.subscribe abre ReceivePorts internos no main
  // isolate que não são expostos pra fechar. Sem isso, uma porta aberta mantém
  // a VM viva e o programa nunca encerra (não é deadlock — é falta de teardown).
  exit(0)
}
