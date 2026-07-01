// wav.tu — gera um arquivo WAV PCM real e grava em disco.
// Prova de geração de binário end-to-end: Buffer.writeString (magic tags RIFF/
// WAVE/fmt/data) + Buffer.writeU*LE (campos little-endian) + writeU8 (samples).
// Formato: PCM 8-bit unsigned, mono, 8000 Hz, onda quadrada ~200 Hz.

fn buildHeader(sampleRate: Int, channels: Int, bits: Int, dataLen: Int) -> Buffer {
  let blockAlign = channels * (bits / 8)
  let byteRate = sampleRate * blockAlign
  var h = Buffer.alloc(44)
  Buffer.writeString(h, 0, "RIFF")            // ChunkID
  Buffer.writeU32LE(h, 4, 36 + dataLen)       // ChunkSize
  Buffer.writeString(h, 8, "WAVE")            // Format
  Buffer.writeString(h, 12, "fmt ")           // Subchunk1ID
  Buffer.writeU32LE(h, 16, 16)                // Subchunk1Size (PCM)
  Buffer.writeU16LE(h, 20, 1)                 // AudioFormat = PCM
  Buffer.writeU16LE(h, 22, channels)          // NumChannels
  Buffer.writeU32LE(h, 24, sampleRate)        // SampleRate
  Buffer.writeU32LE(h, 28, byteRate)          // ByteRate
  Buffer.writeU16LE(h, 32, blockAlign)        // BlockAlign
  Buffer.writeU16LE(h, 34, bits)              // BitsPerSample
  Buffer.writeString(h, 36, "data")           // Subchunk2ID
  Buffer.writeU32LE(h, 40, dataLen)           // Subchunk2Size
  return h
}

fn main() {
  let sampleRate = 8000
  let numSamples = 2000                        // 0.25 s

  // Onda quadrada: alterna alto/baixo a cada 20 samples -> período 40 -> 200 Hz.
  var data = Buffer.alloc(numSamples)
  for i in 0..numSamples {
    let high = (i / 20) % 2 == 0
    let sample = if high { 200 } else { 56 }   // 8-bit unsigned em torno de 128
    Buffer.writeU8(data, i, sample)
  }

  let header = buildHeader(sampleRate, 1, 8, numSamples)
  let wav = Buffer.concat(header, data)

  Buffer.writeFile("/tmp/ita_demo.wav", wav)

  print("=== WAV gerado ===")
  print("header (44 bytes): ${Buffer.toHex(header)}")
  print("total bytes: ${Buffer.length(wav)}")
  print("samples: ${numSamples} @ ${sampleRate}Hz, 8-bit mono")
  print("arquivo: /tmp/ita_demo.wav")
  print("=== Done! ===")
}
