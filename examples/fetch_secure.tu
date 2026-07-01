// fetch async seguro por default (Bloco B, fatia 1).
//
// fetch(url) -> Result<Response> assincrono via dart:io HttpClient:
//   - TLS nativo LIGADO (cert + hostname) — nunca trust-all
//   - followRedirects = false por default (redirect e opt-in; evita SSRF)
//   - connectionTimeout = 30s
//   - rede/DNS/timeout viram Result.err(...) — NUNCA panic/crash
//
// Response expoe: Http.status(resp) -> Int, Http.text(resp) -> String,
// Http.bytes(resp) -> Buffer.  (Usados quando o Result e ok.)
//
// Esta prova e o caminho de ERRO-COMO-VALOR: alvo local que recusa conexao
// na hora (porta 1, sem egress, sem servidor). Deve imprimir Result.err e
// terminar gracioso — sem travar, sem crashar. Rede e nao-deterministica,
// entao nao ha golden (roda como "nao crashou").

async fn main() {
  print("=== fetch seguro: erro-como-valor ===")

  // Conexao recusada imediatamente (loopback, porta 1, ninguem escutando).
  let result = await fetch("http://127.0.0.1:1/")
  print("fetch loopback:1 -> ${result}")   // Result.err(error: SocketException...)

  // Segundo alvo local invalido — prova que o err e consistente e nao trava.
  let result2 = await fetch("http://127.0.0.1:1/health")
  print("fetch loopback:1/health -> ${result2}")

  print("=== fetch retornou err graciosamente (sem panic) ===")
  print("=== Done! ===")
}
