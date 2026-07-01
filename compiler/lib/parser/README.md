# Fase 2: Parser (Analise Sintatica)

> Transforma uma lista flat de tokens em uma arvore hierarquica (AST).

## O que e um Parser?

O Parser recebe os tokens do Lexer e constroi uma **AST (Abstract Syntax Tree)** — uma representacao em arvore que captura a estrutura e hierarquia do programa.

```
  Tokens: [let] [x] [=] [2] [+] [3] [*] [4]

       │ Parser
       ▼

  LetStmt("x")
  └── BinaryExpr(+)
      ├── IntLiteral(2)
      └── BinaryExpr(*)
          ├── IntLiteral(3)
          └── IntLiteral(4)
```

Note como a arvore captura que `3 * 4` deve ser calculado antes de `+ 2`, sem precisar de parenteses. A **estrutura da arvore** codifica a **precedencia**.

## Analogia

Imagine a frase: "O gato grande dormiu no sofa"

As palavras (tokens) sao flat, mas a frase tem estrutura:
- "O gato grande" e o sujeito
- "dormiu" e o verbo
- "no sofa" e o complemento

O parser faz essa analise estrutural para codigo.

## Arquivos

| Arquivo | O que faz |
|---------|-----------|
| `ast.dart` | Define a FORMA da arvore (tipos de nos, campos) |
| `parser.dart` | CONSTROI a arvore a partir dos tokens |

## Tecnicas utilizadas

### Recursive Descent
Cada regra gramatical da linguagem vira uma funcao no parser:
- `_fnDecl()` → parseia `fn nome(params) -> Tipo { corpo }`
- `_ifStmt()` → parseia `if cond { ... } else { ... }`
- `_structDecl()` → parseia `struct Point { x: Float, y: Float }`

As funcoes chamam umas as outras recursivamente, espelhando a gramatica.

### Pratt Parsing (para expressoes)
Tecnica elegante para lidar com precedencia de operadores. Cada operador tem um "binding power" (forca de ligacao). O parser compara esses valores para decidir como agrupar:

```
2 + 3 * 4

  + tem binding power 6
  * tem binding power 7 (mais forte)

  Resultado: 2 + (3 * 4)  ← * "puxa" mais forte
```

### Sealed Classes
A AST usa `sealed class` do Dart 3, garantindo que todo switch sobre nos seja **exaustivo** — o compilador Dart avisa se voce esqueceu de tratar algum caso.
