# Fase 1: Lexer (Analise Lexica)

> Transforma texto bruto em uma lista de tokens.

## O que e um Lexer?

O Lexer (tambem chamado de Scanner ou Tokenizer) e a primeira fase de qualquer compilador. Ele le o codigo fonte **caractere por caractere** e agrupa em **tokens** — as menores unidades significativas da linguagem.

```
  "let x = 42 + y"

       │ Lexer
       ▼

  [kwLet "let"]
  [identifier "x"]
  [eq "="]
  [intLiteral "42" (42)]
  [plus "+"]
  [identifier "y"]
  [eof ""]
```

## Analogia

Imagine que voce esta lendo uma frase em portugues:

> "O gato dormiu"

Voce nao le letra por letra — voce agrupa automaticamente em palavras: "O", "gato", "dormiu". O Lexer faz a mesma coisa com codigo.

## Arquivos

| Arquivo | O que faz |
|---------|-----------|
| `token.dart` | Define QUAIS tokens existem (tipos, keywords, operadores) |
| `lexer.dart` | Le o texto e PRODUZ tokens (o scanner em si) |

## Conceitos implementados

- **Maximal munch**: sempre consome o token mais longo (`>=` em vez de `>` + `=`)
- **String interpolation**: `"Hello ${name}"` com tracking de profundidade de `{}`
- **Numeros**: int, float, hex (`0xFF`), binario (`0b1010`), separadores (`1_000_000`)
- **Comentarios aninhados**: `/* pode ter /* dentro */ */`
- **Posicao**: cada token registra linha e coluna (para mensagens de erro)
