// A sample Swift file for the editor (Phase N) to open.

struct Greeter {
    let name: String

    func greet() -> String {
        "Hello, \(name)!"
    }
}

let greeter = Greeter(name: "Wiffer")
print(greeter.greet())
