// BDD test: User authentication

fn authenticate(email: String, password: String) -> Bool {
  if email == "alice@test.com" {
    if password == "123456" {
      return true
    }
  }
  return false
}

fn main() {
  feature("User authentication", () => {
    scenario("valid credentials", () => {
      given("a registered user with email alice@test.com")
      let email = "alice@test.com"
      let password = "123456"

      when("they login with correct password")
      let result = authenticate(email, password)

      then("they should be authenticated", () => {
        expect(result).toBeTrue()
      })
    })

    scenario("invalid password", () => {
      given("a registered user with email alice@test.com")
      let email = "alice@test.com"

      when("they login with wrong password")
      let result = authenticate(email, "wrong")

      then("authentication should fail", () => {
        expect(result).toBeFalse()
      })
    })

    scenario("unknown user", () => {
      given("an unregistered email")

      when("they try to login")
      let result = authenticate("nobody@test.com", "123456")

      then("authentication should fail", () => {
        expect(result).toBeFalse()
      })
    })
  })
}
