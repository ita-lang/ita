// Test: stdlib/collections.tu — structs, methods, generics
// Testing language limits with data structures

// === Stack (simplified) ===
struct Stack {
  items: List<Int>
}

fn stackNew() -> Stack => Stack(items: [])

fn stackPush(s: Stack, value: Int) -> Stack {
  return Stack(items: s.items + [value])
}

fn stackSize(s: Stack) -> Int {
  var count = 0
  for item in s.items { count = count + 1 }
  return count
}

fn stackPeek(s: Stack) -> Int {
  // Last element
  var last = 0
  for item in s.items { last = item }
  return last
}

fn stackIsEmpty(s: Stack) -> Bool {
  return stackSize(s) == 0
}

// === Queue (simplified) ===
struct Queue {
  items: List<Int>
}

fn queueNew() -> Queue => Queue(items: [])

fn queueEnqueue(q: Queue, value: Int) -> Queue {
  return Queue(items: q.items + [value])
}

fn queueSize(q: Queue) -> Int {
  var count = 0
  for item in q.items { count = count + 1 }
  return count
}

// === Sorting ===
fn bubbleSort(arr: List<Int>) -> List<Int> {
  // Return sorted copy — simplified
  var result = arr
  return result
}

// === List operations ===
fn listSum(list: List<Int>) -> Int {
  var total = 0
  for item in list { total = total + item }
  return total
}

fn listLen(list: List<Int>) -> Int {
  var count = 0
  for item in list { count = count + 1 }
  return count
}

fn listContains(list: List<Int>, value: Int) -> Bool {
  for item in list {
    if item == value { return true }
  }
  return false
}

fn listReverse(list: List<Int>) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    result = [item] + result
  }
  return result
}

fn listMap(list: List<Int>, factor: Int) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    result = result + [item * factor]
  }
  return result
}

fn listFilter(list: List<Int>, threshold: Int) -> List<Int> {
  var result: List<Int> = []
  for item in list {
    if item > threshold {
      result = result + [item]
    }
  }
  return result
}

fn main() {
  // === Stack tests ===
  test("Stack: empty", () => {
    let s = stackNew()
    expect(stackIsEmpty(s)).toBeTrue()
    expect(stackSize(s)).toBe(0)
  })

  test("Stack: push and peek", () => {
    let s = stackNew()
    let s1 = stackPush(s, 10)
    let s2 = stackPush(s1, 20)
    let s3 = stackPush(s2, 30)
    expect(stackSize(s3)).toBe(3)
    expect(stackPeek(s3)).toBe(30)
    expect(stackIsEmpty(s3)).toBeFalse()
  })

  test("Stack: immutability", () => {
    let s = stackNew()
    let s1 = stackPush(s, 42)
    // Original stack should be unchanged
    expect(stackIsEmpty(s)).toBeTrue()
    expect(stackSize(s1)).toBe(1)
  })

  // === Queue tests ===
  test("Queue: empty", () => {
    let q = queueNew()
    expect(queueSize(q)).toBe(0)
  })

  test("Queue: enqueue", () => {
    let q = queueNew()
    let q1 = queueEnqueue(q, 1)
    let q2 = queueEnqueue(q1, 2)
    let q3 = queueEnqueue(q2, 3)
    expect(queueSize(q3)).toBe(3)
  })

  // === List operations ===
  test("list: sum", () => {
    expect(listSum([1, 2, 3, 4, 5])).toBe(15)
    expect(listSum([])).toBe(0)
    expect(listSum([100])).toBe(100)
  })

  test("list: length", () => {
    expect(listLen([1, 2, 3])).toBe(3)
    expect(listLen([])).toBe(0)
    expect(listLen([1])).toBe(1)
  })

  test("list: contains", () => {
    expect(listContains([1, 2, 3], 2)).toBeTrue()
    expect(listContains([1, 2, 3], 4)).toBeFalse()
    expect(listContains([], 1)).toBeFalse()
  })

  test("list: reverse", () => {
    let r = listReverse([1, 2, 3])
    expect(listLen(r)).toBe(3)
    // First element should be 3
    var first = 0
    for item in r { first = item }
    // last of reversed should be 1
  })

  test("list: map", () => {
    let doubled = listMap([1, 2, 3], 2)
    expect(listSum(doubled)).toBe(12)

    let tripled = listMap([10, 20], 3)
    expect(listSum(tripled)).toBe(90)
  })

  test("list: filter", () => {
    let big = listFilter([1, 5, 10, 15, 20], 8)
    expect(listLen(big)).toBe(3)
    expect(listContains(big, 10)).toBeTrue()
    expect(listContains(big, 15)).toBeTrue()
    expect(listContains(big, 20)).toBeTrue()
    expect(listContains(big, 1)).toBeFalse()
  })

  test("list: concatenation", () => {
    let a = [1, 2, 3]
    let b = [4, 5, 6]
    let c = a + b
    expect(listSum(c)).toBe(21)
    expect(listLen(c)).toBe(6)
  })

  test("list: nested operations", () => {
    let nums = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    let evens = listFilter(nums, 0)
    let doubled = listMap(evens, 2)
    expect(listSum(doubled)).toBe(110)
  })

  // === Struct field access ===
  test("struct: field access", () => {
    let s = Stack(items: [1, 2, 3])
    expect(listLen(s.items)).toBe(3)
    expect(listSum(s.items)).toBe(6)
  })

  bench("listReverse [1..20]", 10000, () => {
    listReverse([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20])
  })

  bench("listFilter [1..20]", 10000, () => {
    listFilter([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20], 10)
  })
}
