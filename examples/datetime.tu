// Date/Time — formatos BR, US, EU + operações

fn main() {
  print("=== Data Atual ===")
  let agora = Date.now()
  print(agora)

  print("=== Formatos ===")

  // Brasil: dd/MM/yyyy HH:mm:ss
  print("BR: ${Date.formatBR(agora)}")

  // EUA: MM/dd/yyyy hh:mm AM/PM
  print("US: ${Date.formatUS(agora)}")

  // Europa: dd.MM.yyyy HH:mm
  print("EU: ${Date.formatEU(agora)}")

  // ISO 8601
  print("ISO: ${Date.formatISO(agora)}")

  print("=== Propriedades ===")
  print("Ano: ${Date.year(agora)}")
  print("Mês: ${Date.month(agora)}")
  print("Dia: ${Date.day(agora)}")
  print("Hora: ${Date.hour(agora)}")
  print("Minuto: ${Date.minute(agora)}")
  print("Dia da semana: ${Date.weekday(agora)}")
  print("Timezone: ${Date.timezone(agora)}")

  print("=== Nomes (PT-BR) ===")
  print("Dia: ${Date.weekdayNameBR(agora)}")
  print("Mês: ${Date.monthNameBR(agora)}")

  print("=== Nomes (EN) ===")
  print("Day: ${Date.weekdayName(agora)}")
  print("Month: ${Date.monthName(agora)}")

  print("=== Operações ===")

  // Adicionar dias
  let semanaQueVem = Date.addDays(agora, 7)
  print("Semana que vem: ${Date.formatBR(semanaQueVem)}")

  // Adicionar horas
  let maisHoras = Date.addHours(agora, 3)
  print("+3 horas: ${Date.formatBR(maisHoras)}")

  // Diferença
  let natal = Date.create(2026, 12, 25)
  let diasProNatal = Date.diffDays(natal, agora)
  print("Dias pro Natal: ${diasProNatal}")

  // Antes/Depois
  print("Natal depois de agora: ${Date.isAfter(natal, agora)}")

  // Timestamp
  print("Timestamp: ${Date.timestamp(agora)}")

  print("=== Relative ===")
  print(Date.formatRelative(agora))

  print("=== Duration ===")
  let d = Duration.days(7)
  print(d)
  let h = Duration.hours(2)
  print(h)

  print("=== Done! ===")
}
