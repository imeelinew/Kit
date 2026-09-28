import Foundation

// Reads samples.json ([{id, text, ...}]), prints [{id, kind}] on stdout.
// Any home-relative sample text resolves against this machine's home, exactly
// like the production classifier does.

struct Sample: Decodable {
    let id: String
    let text: String
}

struct Verdict: Encodable {
    let id: String
    let kind: String
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: rules-cli <samples.json>\n".data(using: .utf8)!)
    exit(2)
}

let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let samples = try JSONDecoder().decode([Sample].self, from: data)
let verdicts = samples.map { Verdict(id: $0.id, kind: ClipboardTextClassifier.kind(for: $0.text).rawValue) }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(verdicts))
