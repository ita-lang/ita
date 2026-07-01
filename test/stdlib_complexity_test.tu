// Test: collections complexity — O(n) vs O(1) vs O(n²)
// Benchmark data structures to verify performance characteristics

fn stackPush(items: List<Int>, value: Int) -> List<Int> {
  return items + [value]
}

fn stackPop(items: List<Int>) -> List<Int> {
  var result: List<Int> = []
  var i = 0
  var len = 0
  for item in items { len = len + 1 }
  for item in items {
    if i < len - 1 { result = result + [item] }
    i = i + 1
  }
  return result
}

fn queueDequeue(items: List<Int>) -> List<Int> {
  var result: List<Int> = []
  var first = true
  for item in items {
    if first { first = false }
    else { result = result + [item] }
  }
  return result
}

fn dequePushFront(items: List<Int>, value: Int) -> List<Int> {
  return [value] + items
}

fn listLen(list: List<Int>) -> Int {
  var count = 0
  for item in list { count = count + 1 }
  return count
}

fn listSum(list: List<Int>) -> Int {
  var total = 0
  for item in list { total = total + item }
  return total
}

fn setHas(items: List<Int>, value: Int) -> Bool {
  for item in items {
    if item == value { return true }
  }
  return false
}

fn setAdd(items: List<Int>, value: Int) -> List<Int> {
  if setHas(items, value) { return items }
  return items + [value]
}

fn linearSearch(items: List<Int>, target: Int) -> Int {
  var i = 0
  for item in items {
    if item == target { return i }
    i = i + 1
  }
  return -1
}

fn insertionSortSimple(arr: List<Int>) -> List<Int> {
  var result: List<Int> = []
  for item in arr {
    var inserted = false
    var newResult: List<Int> = []
    for existing in result {
      if existing > item && inserted == false {
        newResult = newResult + [item]
        inserted = true
      }
      newResult = newResult + [existing]
    }
    if inserted == false { newResult = newResult + [item] }
    result = newResult
  }
  return result
}

fn main() {
  // === Functional correctness ===
  test("Stack push/pop", () => {
    var s: List<Int> = []
    s = stackPush(s, 10)
    s = stackPush(s, 20)
    s = stackPush(s, 30)
    expect(listLen(s)).toBe(3)
    let s2 = stackPop(s)
    expect(listLen(s2)).toBe(2)
    expect(listSum(s2)).toBe(30)
  })

  test("Queue dequeue", () => {
    let q = [1, 2, 3, 4, 5]
    let q2 = queueDequeue(q)
    expect(listLen(q2)).toBe(4)
    expect(listSum(q2)).toBe(14)
  })

  test("Deque pushFront", () => {
    let d = [2, 3, 4]
    let d2 = dequePushFront(d, 1)
    expect(listLen(d2)).toBe(4)
    expect(listSum(d2)).toBe(10)
  })

  test("Set operations", () => {
    let s = setAdd(setAdd(setAdd([], 1), 2), 3)
    expect(listLen(s)).toBe(3)
    expect(setHas(s, 2)).toBeTrue()
    expect(setHas(s, 99)).toBeFalse()
    // Duplicate should not add
    let s2 = setAdd(s, 2)
    expect(listLen(s2)).toBe(3)
  })

  test("Linear search", () => {
    expect(linearSearch([10, 20, 30, 40, 50], 30)).toBe(2)
    expect(linearSearch([10, 20, 30, 40, 50], 99)).toBe(-1)
  })

  test("Insertion sort: correctness", () => {
    let sorted = insertionSortSimple([5, 3, 8, 1, 9, 2, 7, 4, 6])
    expect(listLen(sorted)).toBe(9)
    expect(listSum(sorted)).toBe(45)
    var prev = 0
    var ok = true
    for item in sorted {
      if item < prev { ok = false }
      prev = item
    }
    expect(ok).toBeTrue()
  })

  test("Insertion sort: already sorted (best case)", () => {
    let sorted = insertionSortSimple([1, 2, 3, 4, 5])
    expect(listSum(sorted)).toBe(15)
  })

  test("Insertion sort: reverse (worst case)", () => {
    let sorted = insertionSortSimple([5, 4, 3, 2, 1])
    var prev = 0
    var ok = true
    for item in sorted {
      if item < prev { ok = false }
      prev = item
    }
    expect(ok).toBeTrue()
  })

  // === BENCHMARKS — O(n) scaling ===
  // Se push é O(n), x50 deveria ser ~25x mais lento que x10

  bench("Stack push x10", 10000, () => {
    var s: List<Int> = []
    var i = 0
    while i < 10 {
      s = stackPush(s, i)
      i = i + 1
    }
  })

  bench("Stack push x50", 1000, () => {
    var s: List<Int> = []
    var i = 0
    while i < 50 {
      s = stackPush(s, i)
      i = i + 1
    }
  })

  bench("Stack push x200", 100, () => {
    var s: List<Int> = []
    var i = 0
    while i < 200 {
      s = stackPush(s, i)
      i = i + 1
    }
  })

  bench("Deque pushFront x10", 10000, () => {
    var d: List<Int> = []
    var i = 0
    while i < 10 {
      d = dequePushFront(d, i)
      i = i + 1
    }
  })

  bench("Deque pushFront x50", 1000, () => {
    var d: List<Int> = []
    var i = 0
    while i < 50 {
      d = dequePushFront(d, i)
      i = i + 1
    }
  })

  bench("Set add x20", 5000, () => {
    var items: List<Int> = []
    var i = 0
    while i < 20 {
      items = setAdd(items, i)
      i = i + 1
    }
  })

  bench("InsertionSort 10 items", 5000, () => {
    insertionSortSimple([9, 3, 7, 1, 8, 2, 6, 4, 5, 0])
  })

  bench("InsertionSort 20 items", 1000, () => {
    insertionSortSimple([19, 3, 17, 1, 18, 2, 16, 4, 15, 5, 14, 6, 13, 7, 12, 8, 11, 9, 10, 0])
  })

  bench("LinearSearch best (first)", 100000, () => {
    linearSearch([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 1)
  })

  bench("LinearSearch worst (last)", 100000, () => {
    linearSearch([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 10)
  })

  bench("LinearSearch miss", 100000, () => {
    linearSearch([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 99)
  })

  bench("Queue dequeue x5 from 10", 10000, () => {
    var q = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var i = 0
    while i < 5 {
      q = queueDequeue(q)
      i = i + 1
    }
  })

  stress("Stack push stress", 3000, () => {
    var s: List<Int> = []
    var i = 0
    while i < 100 {
      s = stackPush(s, i)
      i = i + 1
    }
  })
}
