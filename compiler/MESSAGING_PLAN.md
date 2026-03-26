# Glu Messaging Primitives — Implementation Plan

## Filosofia

3 primitivas cruas no codegen. Libs constroem os patterns em cima.

---

## Primitiva 1: Channel (ponto a ponto)

Canal tipado unidirecional. Um sender, um receiver. Backpressure nativo.

```glu
// Criar canal
let (sender, receiver) = Channel.create()

// Enviar (non-blocking se buffer não cheio)
sender.send("hello")

// Receber (bloqueia até ter mensagem)
let msg = await receiver.receive()

// Com buffer (bounded — backpressure automático)
let (tx, rx) = Channel.buffered(100)  // buffer de 100 msgs

// Fechar
sender.close()

// Iterar (stream)
for await msg in receiver {
  print(msg)
}
```

**Dart mapping:** `StreamController` + `Stream.listen`

---

## Primitiva 2: Broadcast (1 para N)

Canal que replica mensagem pra todos os subscribers.

```glu
// Criar broadcast
let bus = Broadcast.create()

// Subscribers
bus.subscribe((msg) => print("A: ${msg}"))
bus.subscribe((msg) => print("B: ${msg}"))

// Publicar (vai pra todos)
bus.publish("hello")

// Com filtro (topic)
bus.subscribe("orders", (msg) => processOrder(msg))
bus.publish("orders", orderData)

// Unsubscribe
let sub = bus.subscribe((msg) => print(msg))
sub.cancel()
```

**Dart mapping:** `StreamController.broadcast()`

---

## Primitiva 3: Mailbox (fila com backpressure)

Fila bounded FIFO. N producers, 1 consumer. Quando cheia, producers bloqueiam.

```glu
// Criar mailbox com capacidade
let box = Mailbox.create(1000)  // max 1000 msgs

// Produzir (bloqueia se cheio)
box.put("task-1")
box.put("task-2")

// Consumir (bloqueia se vazio)
let task = await box.take()

// Tamanho atual
box.size      // quantas msgs na fila
box.isEmpty   // bool
box.isFull    // bool

// Drenar (pegar todas)
let all = box.drain()

// Iterar
for await task in box {
  process(task)
}
```

**Dart mapping:** `StreamController` com `pause/resume` pra backpressure

---

## O que libs constroem em cima

```
Channel   → Request/Reply, RPC, command pattern
Broadcast → Pub/Sub, event bus, notifications, chat
Mailbox   → Job queue, task processing, worker pool, dead letter

Combinações:
Channel + Actor     → Database connection pool
Broadcast + Topic   → Microservice event bus
Mailbox + Actor     → Worker pool com load balancing
Mailbox + Deadletter → Retry queue com error handling
```

---

## Dart implementation approach

Todas as 3 primitivas mapeiam pra StreamController do Dart:

```dart
// Channel → StreamController (single subscription)
final controller = StreamController();
// sender = controller.sink
// receiver = controller.stream

// Broadcast → StreamController.broadcast()
final controller = StreamController.broadcast();

// Mailbox → StreamController + buffer counter
// put() = sink.add() (com check de capacidade)
// take() = stream.first
```
