// TCP raw — primitivas pra devs de libs

fn onServerData(socket, data) {
  let msg = Buffer.toString(data)
  print("Server received: ${msg}")
  socket.write(Buffer.fromString("echo: ${msg}"))
}

fn onClientData(data) {
  print("Client got: ${Buffer.toString(data)}")
}

fn handleConnection(socket) {
  print("Connected: ${socket.remoteAddress}")
  socket.listen((data) => onServerData(socket, data))
}

async fn main() {
  print("=== TCP Server + Client ===")

  let server = await Net.listen(4000)
  print("TCP server on :4000")
  server.listen(handleConnection)

  let client = await Net.connect("localhost", 4000)
  client.write(Buffer.fromString("Hello TCP!"))
  client.listen(onClientData)

  print("=== DNS ===")
  let ip = Dns.resolve("google.com")
  print("google.com: ${ip}")
}
