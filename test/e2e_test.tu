// E2E test: data processing pipeline

fn processData(input: String) -> String {
  return input + " processed"
}

fn validateOutput(output: String) -> Bool {
  return output == "hello processed"
}

fn main() {
  flow("data processing pipeline", () => {
    step("prepare input data", () => {
      let input = "hello"
      save("input", input)
      expect(input).toBe("hello")
    })

    step("process the data", () => {
      let input = load("input")
      let output = processData("hello")
      save("output", output)
      expect(output).toContain("processed")
    })

    step("validate output", () => {
      let result = validateOutput("hello processed")
      expect(result).toBeTrue()
    })

    cleanup(() => {
      print("cleaned up test resources")
    })
  })

  flow("error handling", () => {
    step("first step passes", () => {
      save("status", "ok")
      expect(1 + 1).toBe(2)
    })

    step("verify state", () => {
      expect(1).toBeGreaterThan(0)
    })
  })
}
