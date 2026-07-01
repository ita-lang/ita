// Test: iterator utility functions

fn sumList(list: List<Int>) -> Int {
  var total = 0
  for item in list {
    total = total + item
  }
  return total
}

fn listLength(list: List<Int>) -> Int {
  var count = 0
  for item in list {
    count = count + 1
  }
  return count
}

fn listContains(list: List<Int>, value: Int) -> Bool {
  for item in list {
    if item == value { return true }
  }
  return false
}

fn filterPositive(list: List<Int>) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    if item > 0 {
      result = result + [item]
    }
  }
  return result
}

fn mapDouble(list: List<Int>) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    result = result + [item * 2]
  }
  return result
}

fn findFirst(list: List<Int>, target: Int) -> Int {
  var idx = 0
  for item in list {
    if item == target { return idx }
    idx = idx + 1
  }
  return -1
}

fn countIf(list: List<Int>, threshold: Int) -> Int {
  var count = 0
  for item in list {
    if item > threshold {
      count = count + 1
    }
  }
  return count
}

fn reverseList(list: List<Int>) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    result = [item] + result
  }
  return result
}

fn main() {
  test("sumList", () => {
    expect(sumList([1, 2, 3])).toBe(6)
    expect(sumList([10, 20, 30, 40])).toBe(100)
    expect(sumList([])).toBe(0)
    expect(sumList([-1, 1, -2, 2])).toBe(0)
  })

  test("listLength", () => {
    expect(listLength([1, 2, 3])).toBe(3)
    expect(listLength([])).toBe(0)
    expect(listLength([99])).toBe(1)
  })

  test("listContains", () => {
    expect(listContains([1, 2, 3], 2)).toBeTrue()
    expect(listContains([1, 2, 3], 4)).toBeFalse()
    expect(listContains([], 1)).toBeFalse()
  })

  test("filterPositive", () => {
    let result = filterPositive([-2, -1, 0, 1, 2, 3])
    expect(listLength(result)).toBe(3)
    expect(listContains(result, 1)).toBeTrue()
    expect(listContains(result, 2)).toBeTrue()
    expect(listContains(result, 3)).toBeTrue()
    expect(listContains(result, -1)).toBeFalse()
  })

  test("mapDouble", () => {
    let result = mapDouble([1, 2, 3])
    expect(sumList(result)).toBe(12)
    expect(listLength(result)).toBe(3)
  })

  test("findFirst", () => {
    expect(findFirst([10, 20, 30, 40], 30)).toBe(2)
    expect(findFirst([10, 20, 30, 40], 10)).toBe(0)
    expect(findFirst([10, 20, 30, 40], 99)).toBe(-1)
    expect(findFirst([], 1)).toBe(-1)
  })

  test("countIf", () => {
    expect(countIf([1, 5, 10, 15, 20], 10)).toBe(2)
    expect(countIf([1, 2, 3], 100)).toBe(0)
    expect(countIf([100, 200, 300], 0)).toBe(3)
  })

  test("reverseList", () => {
    let result = reverseList([1, 2, 3])
    expect(findFirst(result, 3)).toBe(0)
    expect(findFirst(result, 2)).toBe(1)
    expect(findFirst(result, 1)).toBe(2)
  })

  bench("sumList [1..100]", 10000, () => {
    sumList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])
  })
}
