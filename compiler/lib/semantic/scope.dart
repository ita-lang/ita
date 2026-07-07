// ============================================================================
// scope.dart — Escopos aninhados (tabela de símbolos encadeada)
// ============================================================================
//
// CONTEXTO EDUCACIONAL:
// ---------------------
// Um ESCOPO é uma tabela de símbolos com um ponteiro para o escopo PAI.
// Entrar num bloco `{ ... }` empurra um novo escopo-filho; sair descarta-o.
// A busca por um nome sobe a cadeia até a raiz (shadowing natural: o mais
// interno vence). Isto espelha o `Env` push/pop do Dragon Book (6.3.6).
//
//   global
//     └── fn foo   (params)
//           └── block { }   (locais)
//
// REFERÊNCIA:
// - Dragon Book, Cap. 2.7 (Symbol Tables) e 6.3.6 (Nested Environments)
// ============================================================================

import 'symbol.dart';

/// Um escopo léxico: seus próprios símbolos + link para o pai.
class Scope {
  final Scope? parent;
  final Map<String, Symbol> symbols = {};

  Scope([this.parent]);

  /// Define um símbolo NESTE escopo.
  ///
  /// Retorna `false` se o nome já existia localmente (redeclaração) — o
  /// chamador decide se isso é erro. Não olha os escopos-pai (shadowing é ok).
  bool define(Symbol symbol) {
    if (symbols.containsKey(symbol.name)) return false;
    symbols[symbol.name] = symbol;
    return true;
  }

  /// Busca [name] neste escopo e, se não achar, sobe pela cadeia de pais.
  Symbol? lookup(String name) {
    return symbols[name] ?? parent?.lookup(name);
  }

  /// Busca [name] APENAS neste escopo (sem subir).
  Symbol? lookupLocal(String name) => symbols[name];

  /// Cria um escopo-filho que tem `this` como pai.
  Scope child() => Scope(this);
}
