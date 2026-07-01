// helpers.tu — modulo auxiliar para testes de import
// Funcoes exportadas devem usar pub

pub fn double(x: Int) -> Int => x * 2
pub fn triple(x: Int) -> Int => x * 3

// Funcao privada — nao deve ser importavel
fn internalHelper(x: Int) -> Int => x + 1
