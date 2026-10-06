import Foundation
import Testing
@testable import EchoSense

@Suite("Completion in a long script", .serialized)
struct LongScriptCompletionTests {
    private func makeEngine() -> SQLAutoCompletionEngine {
        let id = EchoSenseColumnInfo(name: "id", dataType: "integer", isPrimaryKey: true, isNullable: false)
        let name = EchoSenseColumnInfo(name: "name", dataType: "text", isNullable: true)
        let email = EchoSenseColumnInfo(name: "email", dataType: "text", isNullable: true)
        let userID = EchoSenseColumnInfo(name: "user_id", dataType: "integer", isNullable: false)
        let amount = EchoSenseColumnInfo(name: "amount", dataType: "numeric", isNullable: true)
        let users = EchoSenseSchemaObjectInfo(name: "users", schema: "public", type: .table, columns: [id, name, email])
        let orders = EchoSenseSchemaObjectInfo(name: "orders", schema: "public", type: .table, columns: [id, userID, amount])
        let schema = EchoSenseSchemaInfo(name: "public", objects: [users, orders])
        let structure = EchoSenseDatabaseStructure(databases: [EchoSenseDatabaseInfo(name: "app", schemas: [schema])])
        let engine = SQLAutoCompletionEngine()
        engine.updateContext(SQLEditorCompletionContext(databaseType: .postgresql, selectedDatabase: "app",
                                                         defaultSchema: "public", structure: structure))
        return engine
    }

    /// A long script with `target` in the middle, and where the caret is in it.
    private func script(around target: String, marker: String = "|") -> (text: String, caret: Int, statement: String, statementCaret: Int) {
        let filler = (1...400).map { "SELECT \($0) AS n, 'a;b' AS s FROM orders WHERE amount > \($0);" }.joined(separator: "\n")
        let statement = target.replacingOccurrences(of: marker, with: "")
        let statementCaret = (target as NSString).range(of: marker).location
        let head = filler + "\n\n"
        let text = head + statement + "\n\n" + filler
        return (text, (head as NSString).length + statementCaret, statement, statementCaret)
    }

    private func ids(_ response: SQLCompletionResponse) -> [String] { response.suggestions.map(\.id) }

    @Test(arguments: [
        "SELECT u.| FROM users u",
        "SELECT * FROM users u JOIN orders o ON o.user_id = u.| WHERE u.id > 1",
        "SELECT | FROM orders",
        "SELECT * FROM |",
        "SELECT * FROM users WHERE |",
        "WITH recent AS (SELECT id, amount FROM orders) SELECT r.| FROM recent r"
    ])
    func aLongScriptCompletesLikeParsingAllOfIt(target: String) {
        let long = script(around: target)
        let original = SQLAutoCompletionEngine.parseWindowThreshold
        defer { SQLAutoCompletionEngine.parseWindowThreshold = original }
        #expect((long.text as NSString).length > original)

        let windowed = makeEngine().completions(in: long.text, at: long.caret)
        SQLAutoCompletionEngine.parseWindowThreshold = Int.max
        let whole = makeEngine().completions(in: long.text, at: long.caret)

        #expect(ids(windowed) == ids(whole))
        #expect(windowed.token == whole.token)
        #expect(windowed.clause == whole.clause)
        #expect(windowed.replacementRange == whole.replacementRange)
    }

    @Test func aShortScriptIsParsedWhole() {
        let text = "SELECT 1; SELECT u. FROM users u"
        let window = SQLAutoCompletionEngine.parseWindow(in: text as NSString, caret: 19)
        #expect(window == NSRange(location: 0, length: (text as NSString).length))
    }

    @Test func theWindowStartsAfterTheLastSemicolonAndEndsAtTheNextOne() {
        let long = script(around: "SELECT u.| FROM users u")
        let text = long.text as NSString
        let window = SQLAutoCompletionEngine.parseWindow(in: text, caret: long.caret)
        let inside = text.substring(with: window)
        #expect(inside.contains("SELECT u. FROM users u"))
        #expect(window.length < 500)
        #expect(NSLocationInRange(long.caret, NSRange(location: window.location, length: window.length + 1)))
    }
}
