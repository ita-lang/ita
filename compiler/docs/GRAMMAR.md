# GRAMMAR.md — Gramática formal do Itá

> **Status:** normativo. Esta é a especificação sintática de referência do Itá, destilada do
> parser oficial (`compiler/lib/parser/parser.dart`) — a fonte de verdade da linguagem. Onde
> este documento e o parser divergirem, **o parser vence** e este documento é o bug.
>
> Complementa (não substitui) o `LANGUAGE_SPEC.md`, que descreve a semântica em prosa. Aqui só
> mora a **forma**: o que é sintaticamente aceito.

## Como ler esta gramática

Notação **EBNF em estilo PEG/ANTLR** — escolhida porque casa 1:1 com o parser recursive-descent
do Itá (cada produção ≈ uma função `_xxx()`), então a gramática é um *espelho verificável* do
código, não uma ficção documental.

| Símbolo | Significado |
|---------|-------------|
| `minúsculo` | não-terminal (regra de parser) |
| `MAIÚSCULO` | terminal léxico produzido por regex (ver §1) |
| `"texto"` | terminal literal (keyword ou pontuação) |
| `a b` | sequência (a seguido de b) |
| <code>a &#124; b</code> | **alternativa ordenada** — o parser tenta `a`, depois `b` (a 1ª que casa vence) |
| `a?` | opcional (0 ou 1) |
| `a*` | zero ou mais |
| `a+` | um ou mais |
| `( … )` | agrupamento |

> **Precedência de operadores fica FORA da EBNF.** As expressões são parseadas por um
> *Pratt / precedence-climbing* (uma função por nível). Documentamos isso numa **tabela de
> binding-power** (§4), não na gramática — forçá-la na EBNF geraria uma "torre" ilegível.

---

## 1. Léxico (terminais)

```ebnf
IDENT             = /[a-zA-Z_][a-zA-Z0-9_]*/ ;      // exceto as keywords reservadas
INT               = /[0-9][0-9_]*/
                  | /0[xX][0-9a-fA-F][0-9a-fA-F_]*/
                  | /0[bB][01][01_]*/ ;             // decimal, hex, binário (sem octal)
FLOAT             = /[0-9][0-9_]*\.[0-9][0-9_]*([eE][+-]?[0-9]+)?/ ;
STRING            = '"' ( char | escape | interpolation )* '"' ;
MULTILINE_STRING  = '"""' … '"""' ;
interpolation     = "${" expression "}" ;           // só em STRING (não em MULTILINE_STRING)
escape            = /\\[nrt\\"0]/ ;
```

**Ignorados entre tokens:** whitespace, `// comentário de linha`, `/* comentário de bloco */`.

**Sensibilidade a layout:** o Itá não usa `;` obrigatório. O parser usa `Token.line` para decidir
continuação: uma `call` (`(`) ou `member` (`.`) pós-fixa só continua a cadeia se estiver **na mesma
linha** do operando (ver §5). Quebra de linha termina o statement.

**Keywords reservadas:** `pub fn async stream actor struct class enum trait impl extension import
operator let var return if else guard while for await in match self mut where emit spawn panic
break continue true false nil as`. Contextuais (não reservadas): `from`, `left`, `right`, `all`,
`race`.

---

## 2. Declarações

```ebnf
program        = declaration* EOF ;

declaration    = "pub"? topLevelDecl
               | statement ;                        // statements top-level (scripting); só sem "pub"

topLevelDecl   = fnDecl
               | "async"  fnDecl                    // async fn
               | "stream" fnDecl                    // stream fn
               | actorDecl | structDecl | classDecl | enumDecl
               | traitDecl | implDecl | extensionDecl | importDecl | operatorDecl ;
```

> Nota: `"pub"` é repassado a `fn/struct/class/enum/trait`. Em `impl/extension/import/operator`
> ele é consumido e **ignorado** (débito conhecido).

### Funções

```ebnf
fnDecl         = "fn" IDENT genericParams? "(" paramList ")" ( "->" type )? fnBody? ;
fnBody         = "=>" ( block | expression )        // corpo-expressão
               | block ;                            // ausência de corpo ⇒ assinatura abstrata (trait)

genericParams  = "<" genericParam ( "," genericParam )* ">" ;
genericParam   = IDENT ( ":" type ( "+" type )* )? ;   // bounds: T: A + B

paramList      = ( param ( ( "," | ";" ) param )* ( "," | ";" )? )? ;
param          = IDENT IDENT? ( ":" type )? ( "=" expression )? ;   // 2 IDENTs = label + nome
```

> Em `paramList`, `";"` inicia o grupo de parâmetros **nomeados** (segunda lista).

### Tipos de usuário

```ebnf
structDecl     = "struct" IDENT genericParams? ( ":" traitRef ( "," traitRef )* )?
                 "{" ( methodDecl | fieldDecl ","? )* "}" ;      // campos e métodos intercaláveis

classDecl      = "class" IDENT genericParams? ( ":" IDENT ( "," traitRef )* )?
                 "{" ( initDecl | "pub"? "override"? "static"? fnDecl | fieldDecl )* "}" ;
               // após ":", o 1º IDENT é a superclasse; traits vêm depois da 1ª vírgula

enumDecl       = "enum" IDENT genericParams?
                 "{" ( methodDecl | enumCase ","? )* "}" ;

traitDecl      = "trait" IDENT genericParams? "{" fnDecl* "}" ;   // fnDecl sem corpo = assinatura

implDecl       = "impl" IDENT "for" type "{" fnDecl* "}" ;

extensionDecl  = "extension" IDENT ( ":" traitRef ( "," traitRef )* )?
                 "{" ( methodDecl | fieldDecl )* "}" ;

actorDecl      = "actor" IDENT "{" ( "stream" fnDecl | fnDecl | fieldDecl )* "}" ;
               // actor não tem generics; métodos "fn" são implicitamente async

operatorDecl   = "operator" OPSYM "(" paramList ")" "->" type
                 ( "precedence" INT ( "left" | "right" )? )? block ;

methodDecl     = "pub"? "static"? fnDecl ;
fieldDecl      = ( "var" | "let" )? IDENT ":" type ( "=" expression )? ;
initDecl       = "init" "(" paramList ")" block ;
enumCase       = IDENT ( "(" ( IDENT ":" type ( "," IDENT ":" type )* )? ")" )? ;
traitRef       = IDENT ( "<" type ( "," type )* ">" )? ;
```

### Imports

```ebnf
importDecl     = "import" "{" importMember ( "," importMember )* ","? "}" "from" STRING
               | "import" "*" "as" IDENT "from" STRING
               | "import" STRING ;
importMember   = IDENT ( "as" IDENT )? ;
```

---

## 3. Statements

```ebnf
statement    = letStmt | varStmt | returnStmt | ifStmt | guardStmt
             | whileStmt | forStmt | breakStmt | continueStmt
             | emitStmt | block | exprStmt ;

block        = "{" ( statement ";"* )* "}" ;         // ";" são separadores OPCIONAIS

letStmt      = "let" ( destructure "=" expression
                     | IDENT ( ":" type )? ( "=" expression )? ) ;
varStmt      = "var" ( destructure "=" expression
                     | IDENT ( ":" type )? ( "=" expression )? ) ;
destructure  = "{" ( IDENT ( "," IDENT )* )? "}"
             | "[" ( destrElem ( "," destrElem )* )? "]" ;
destrElem    = ".." IDENT? | IDENT ;                 // só binding ou rest (sem padrão aninhado)

returnStmt   = "return" expression? ;                // sem valor se o próximo for "}" ou EOF
ifStmt       = "if" ( "let" IDENT "=" expression | expression ) block
                    ( "else" ( ifStmt | block ) )? ;
guardStmt    = "guard" ( "let" IDENT "=" expression ( "&&" expression )? | expression )
                    "else" block ;
whileStmt    = "while" expression block ;
forStmt      = "for" "await"? IDENT "in" expression block ;
breakStmt    = "break" ;                             // válido só dentro de um loop
continueStmt = "continue" ;                          // válido só dentro de um loop
emitStmt     = "emit" expression ;
exprStmt     = expression ;
```

> Nas condições de `if`/`while`/`for`/`match` (e `if`-expressão) o parser desliga *trailing
> closures* para não ler o `{` do bloco como argumento (ver §5). `guard` **não** desliga.

---

## 4. Expressões

### 4.1 Estrutura (esqueleto — a precedência real está em §4.2)

```ebnf
expression   = assignment ( "where" "{" statement* "}" )? ;
assignment   = pipe ( ( "=" | "+=" | "-=" | "*=" | "/=" ) assignment )? ;
             // … escada Pratt … (ver tabela §4.2)
unary        = ( "!" | "-" | "~" ) unary | postfix ;
postfix      = primary postfixOp* ;

postfixOp    = "(" argList ")" trailingClosure?      // call (mesma linha)
             | "." "{" copyField ( "," copyField )* "}"   // copy-with: expr.{ campo: v }
             | "." INT                               // índice de tupla: t.0
             | "." IDENT trailingClosure?            // member access (mesma linha)
             | "?." IDENT                            // optional chaining
             | "[" expression "]"                    // index
             | "!"                                   // force-unwrap
             | "?" ;                                 // try
argList      = ( arg ( "," arg )* )? ;
arg          = ( IDENT ":" )? expression ;
copyField    = IDENT ":" expression ;
trailingClosure = block ;                            // closure com params implícitos $0, $1, …

primary      = "async" closure                       // async closure: só quando "async ("
             | "panic" "(" expression ")"
             | "await" "race" "(" exprList ")"
             | "await" "all"  "(" exprList ")"
             | "await" expression
             | "spawn" postfix
             | INT | FLOAT | STRING | MULTILINE_STRING
             | "true" | "false" | "nil"
             | IDENT | "self"
             | parenOrClosure | listLiteral | mapLiteral | matchExpr | ifExpr
             | "." IDENT ( "(" ( expression ( "," expression )* )? ")" )? ;   // enum shorthand

parenOrClosure = closure
               | "(" expression ( "," expression )* ","? ")" ;   // 1 elem = grupo; ≥2 = tupla
closure      = "(" paramList ")" ( "->" type )? ( "=>" ( block | expression ) | block ) ;
listLiteral  = "[" ( expression ( "," expression )* )? "]" ;
mapLiteral   = "{" ( expression ":" expression ( "," expression ":" expression )* ","? )? "}" ;
matchExpr    = "match" expression "{" matchArm* "}" ;
matchArm     = pattern ( "if" expression )? "=>" expression ","? ;
ifExpr       = "if" expression block ( "else" ( ifStmt | block ) )? ;
```

### 4.2 Tabela de binding-power (Pratt)

Do mais **frouxo** (topo, mais externo) ao mais **forte** (base). Associatividade à esquerda salvo
indicação. O parser não usa números — a ordem é dada pela profundidade da escada de funções.

| Nível | Operadores | Assoc. | Função |
|------:|-----------|--------|--------|
| 0 | `where { … }` (cláusula pós-fixa) | — | `_expression` |
| 1 | `=` `+=` `-=` `*=` `/=` | **direita** | `_assignment` |
| 2 | `\|>` (pipe) · `>>` (compose) | esquerda | `_pipe` |
| 3 | `??` (nil-coalesce) | esquerda | `_nilCoalesce` |
| 4 | `\|\|` | esquerda | `_or` |
| 5 | `&&` | esquerda | `_and` |
| 6 | `==` `!=` | esquerda | `_equality` |
| 7 | `<` `>` `<=` `>=` | esquerda | `_comparison` |
| 8 | `..` `..=` (range) | **não-assoc** | `_range` |
| 9 | `+` `-` | esquerda | `_addition` |
| 10 | `*` `/` `%` | esquerda | `_multiplication` |
| 11 | `**` (potência) | **direita** | `_power` |
| 12 | unário prefixo `!` `-` `~` | direita | `_unary` |
| 13 | pós-fixos: `()` `.` `.{}` `.N` `?.` `[]` `!` `?` | esquerda | `_postfix` |

> `>>` é **composição de funções** (nunca shift-right). Não há `+` unário nem `<<`. `spawn`/`await`/
> `panic`/`async`-closure são prefixos de `primary` (ligam mais forte que binários).

---

## 5. Tipos e patterns

```ebnf
type         = "mut" type
             | "async" type                          // inner deve ser FunctionType
             | "(" ( type ( "," type )* ","? )? ")" ( "->" type )? "?"?   // grupo/tupla/função
             | IDENT ( "<" type ( "," type )* ">" )? "?"? ;

pattern      = "_"
             | "." IDENT ( "(" pattern ( "," pattern )* ")" )?   // enum variant
             | "[" ( patElem ( "," patElem )* )? "]"            // list pattern
             | IDENT "{" ( fieldPat ( "," fieldPat )* )? "}"    // struct pattern (lookahead: IDENT "{")
             | INT ( ( ".." | "..=" ) INT )?                     // range OU literal
             | FLOAT | STRING | "true" | "false" | "nil"        // literais
             | IDENT ;                                           // binding
patElem      = ".." IDENT? | pattern ;
fieldPat     = ".." | IDENT ( ":" pattern )? ;
```

> **Generics em posição de tipo** fecham com `_consumeTypeGt`, que faz *token-splitting* de `>>`→`>`+`>`
> (para `List<List<T>>`) e `>=`→`>`+`=`. Em posição de expressão, `>>` continua sendo compose.

---

## 6. Regras de desambiguação (cantos do parser)

- **`<` genérico vs. comparação:** generics só são parseados em contexto de tipo/declaração. Em
  expressão, `<` é sempre comparação — **não há turbofish** (`Foo<Int>()` numa expressão vira
  `((Foo < Int) > ())`). *(débito)*
- **Trailing closure exige mesma linha:** `f(x) { … }` só vira call-com-closure se o `(`/`.` estiver
  na linha do operando; caso contrário a quebra de linha encerra o statement.
- **`{` = map ou block:** em posição de statement, `{` é bloco; em posição de expressão, é map literal.
  `{}` vazio é map (expr) ou block (stmt) por posição.
- **`if`/`match` como expressão** existem quando aparecem em posição de expressão; `if` em statement
  é `ifStmt`, em expressão é `ifExpr`. `match` só existe como expressão.
- **Struct pattern precisa de 2 tokens:** `IDENT "{"` = struct pattern; `IDENT` isolado = binding.
- **`await race(…)` / `await all(…)`** usam `race`/`all` como IDENT contextual: uma função chamada
  `race` sempre vira `AwaitRaceExpr`. *(canto)*

---

## Apêndice A — Reconciliação com a `tree-sitter-ita`

A gramática tree-sitter (highlighting) é **derivada** desta. Divergências conhecidas (parser é o
normativo) e seu status de correção:

| Área | Divergência | Status |
|------|-------------|--------|
| Precedência | tree-sitter achatava binários num nível único | corrigir p/ escada §4.2 |
| Construções | faltavam map literal, tuplas, async closure, `static fn`, `?.`, `await race`, force-unwrap `!` | adicionar |
| Rigidez | struct forçava campos-antes-métodos; class só 1 conformance; `var` sem destructuring | flexibilizar |
| `>>` | tratado como binário genérico, não compose | corrigir |
| `break`/`continue` | ausentes | adicionar |

## Apêndice B — Débitos conhecidos (não bloqueiam a gramática)

- **Lacunas de linguagem** (decisão de design): `typealias`/`type`, `const`/`static` top-level,
  cláusula `where T: A + B` de genéricos. (`break`/`continue` **saíram** deste apêndice — implementados.)
- **Bugs do parser:** turbofish ausente; `operator` custom sem tabela de precedência dinâmica e com
  símbolo lido como 1 token só (`<=>` quebra); `pub` ignorado em impl/extension/import/operator.
- **AST órfã:** `BlockExpr`, `PartialAppExpr`, `StringInterpolationExpr` e `EnumAccessExpr.enumName`
  existem na AST mas nunca são emitidos pelo parser.
- **Terminais mortos no lexer:** `const unsafe effect signal state`, `@ # & | ^ <<`, `gsx*`, `newline`.
