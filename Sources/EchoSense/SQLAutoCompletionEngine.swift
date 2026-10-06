import Foundation

typealias DatabaseStructure = EchoSenseDatabaseStructure
typealias DatabaseInfo = EchoSenseDatabaseInfo
typealias SchemaInfo = EchoSenseSchemaInfo
typealias SchemaObjectInfo = EchoSenseSchemaObjectInfo
typealias ColumnInfo = EchoSenseColumnInfo
typealias ForeignKeyReference = EchoSenseForeignKeyReference
typealias DatabaseType = EchoSenseDatabaseType

public final class SQLAutoCompletionEngine {
    private let completionEngine: SQLCompletionProviding
    static let identifierDelimiterCharacterSet: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "\"")
        set.insert(charactersIn: "`")
        set.insert(charactersIn: "[")
        set.insert(charactersIn: "]")
        return set
    }()

    private final class CachingSuggestionBuilderFactory: SQLSuggestionBuilderFactory {
        private var cache: [SQLDialect: SQLSuggestionBuilder] = [:]

        func makeBuilder(for dialect: SQLDialect) -> SQLSuggestionBuilder {
            if let existing = cache[dialect] {
                return existing
            }
            let builder = DefaultSuggestionBuilder(dialect: dialect)
            cache[dialect] = builder
            return builder
        }
    }

    public init(completionEngine: SQLCompletionProviding? = nil) {
        if let completionEngine {
            self.completionEngine = completionEngine
        } else {
            self.completionEngine = SQLCompletionEngine(builderFactory: CachingSuggestionBuilderFactory())
        }
    }

    var context: SQLEditorCompletionContext?
    /// The catalog of the context's objects. It is built when something first asks for it after the
    /// context changed, not when the context is set: the host sets a new context for every schema
    /// that loads, and each build walks every object of every database.
    var catalog: SQLMetadataCatalog? {
        get { rebuildCatalogIfStale(); return catalogStorage }
        set { catalogStorage = newValue; catalogIsStale = false }
    }
    private var catalogStorage: SQLMetadataCatalog?
    private var catalogIsStale = false
    private var builtInFunctions: [String] = []
    private var useTableAliasShortcuts = false
    let historyStore = SQLAutoCompletionHistoryStore.shared
    public private(set) var isMetadataLimited: Bool = false
    private var metadataProviderStorage: SQLStructureMetadataProvider = .empty
    private var metadataProvider: SQLStructureMetadataProvider {
        rebuildCatalogIfStale()
        return metadataProviderStorage
    }
    var lastAcceptedClause: SQLClause?
    var lastAcceptedCaretLocation: Int?
    // Default to enabled in production, disabled under test runners so the
    // shared history store singleton cannot leak state between parallel tests.
    var includeHistorySuggestions = !SQLAutoCompletionEngine.isRunningUnderTests
    var preferQualifiedTableInsertions = false
    var aggressiveness: SQLCompletionAggressiveness = .balanced
    private var includeSystemSchemas = false
    var manualTriggerInProgress = false
    /// True when this process appears to be a Swift test runner. Used to flip
    /// history-suggestion defaults so the shared `SQLAutoCompletionHistoryStore`
    /// singleton cannot leak state between parallel tests.
    static let isRunningUnderTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        let args = CommandLine.arguments
        return args.contains { $0.contains("xctest") || $0.contains(".xctest") }
    }()

    private static let emptyMetadata = SQLCompletionMetadata(clause: .unknown,
                                                             currentToken: "",
                                                             precedingKeyword: nil,
                                                             pathComponents: [],
                                                             tablesInScope: [],
                                                             focusTable: nil,
                                                             cteColumns: [:])

    private static let reservedLeadingKeywords: Set<String> = [
        "select", "from", "where", "join", "inner", "left", "right", "full",
        "outer", "cross", "on", "group", "by", "having", "order", "limit",
        "offset", "insert", "into", "values", "update", "set", "delete",
        "create", "drop", "alter", "vacuum", "analyze", "with", "as",
        "when", "then", "else", "case", "using"
    ]

    static let objectContextKeywords: Set<String> = [
        "from", "join", "inner", "left", "right", "full", "outer", "cross",
        "update", "into", "delete"
    ]

    private static let columnContextKeywords: Set<String> = [
        "select", "where", "on", "and", "or", "having", "group", "order",
        "by", "set", "values", "case", "when", "then", "else", "returning",
        "using"
    ]

    static let postObjectClauseKeywordOrder: [String] = [
        "where",
        "inner",
        "left",
        "right",
        "full",
        "outer",
        "join",
        "on",
        "group",
        "order",
        "having",
        "limit",
        "offset"
    ]

    static let relationLikeKinds: Set<SQLAutoCompletionKind> = [
        .schema,
        .table,
        .view,
        .materializedView
    ]

    public func updateContext(_ newContext: SQLEditorCompletionContext?) {
        context = newContext
        if let newContext {
            builtInFunctions = SQLAutoCompletionEngine.builtInFunctions(for: newContext.databaseType)
            isMetadataLimited = newContext.structure == nil
            catalogIsStale = true
        } else {
            catalogStorage = nil
            catalogIsStale = false
            builtInFunctions = []
            metadataProviderStorage = .empty
            isMetadataLimited = false
        }
    }

    /// Builds the catalog for the current context if it changed since the last build.
    private func rebuildCatalogIfStale() {
        guard catalogIsStale, let context else { return }
        let newCatalog = SQLMetadataCatalog(context: context,
                                            builtInFunctions: builtInFunctions,
                                            includeSystemSchemas: includeSystemSchemas)
        catalogStorage = newCatalog
        metadataProviderStorage = newCatalog.metadataProvider
        catalogIsStale = false
    }

    public func updateAliasPreference(useTableAliases: Bool) {
        useTableAliasShortcuts = useTableAliases
    }

    public func updateHistoryPreference(includeHistory: Bool) {
        includeHistorySuggestions = includeHistory
    }

    public func updateQualifiedInsertionPreference(includeSchema: Bool) {
        preferQualifiedTableInsertions = includeSchema
    }

    public func updateAggressiveness(_ level: SQLCompletionAggressiveness) {
        aggressiveness = level
    }

    public func updateSystemSchemaVisibility(includeSystemSchemas: Bool) {
        guard self.includeSystemSchemas != includeSystemSchemas else { return }
        self.includeSystemSchemas = includeSystemSchemas
        if let current = context {
            updateContext(current)
        }
    }

    public func beginManualTrigger() {
        manualTriggerInProgress = true
    }

    public func endManualTrigger() {
        manualTriggerInProgress = false
    }

    public var isManualTriggerActive: Bool {
        manualTriggerInProgress
    }

    public func clearPostCommitSuppression() {
        lastAcceptedClause = nil
        lastAcceptedCaretLocation = nil
    }

    public func recordSelection(_ suggestion: SQLAutoCompletionSuggestion, query: SQLAutoCompletionQuery) {
        if includeHistorySuggestions {
            historyStore.record(suggestion, context: context)
        }
        lastAcceptedClause = query.clause
        lastAcceptedCaretLocation = query.replacementRange.location + query.replacementRange.length
    }

    public func suggestions(for query: SQLAutoCompletionQuery,
                            text: String,
                            caretLocation: Int) -> SQLAutoCompletionResult {
        guard let context else {
            return SQLAutoCompletionResult(sections: [],
                                           metadata: SQLAutoCompletionEngine.emptyMetadata)
        }

        let trimmedToken = query.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty && query.pathComponents.isEmpty {
            // Only suppress if caret is still at the exact position where we accepted
            // AND the clause hasn't changed (user hasn't moved to a new context).
            if let acceptedClause = lastAcceptedClause,
               let acceptedCaret = lastAcceptedCaretLocation,
               acceptedClause == query.clause,
               caretLocation == acceptedCaret {
                return SQLAutoCompletionResult(sections: [],
                                               metadata: SQLAutoCompletionEngine.emptyMetadata)
            }
        }
        // Clear suppression state once the user starts typing or moves
        if !trimmedToken.isEmpty || !query.pathComponents.isEmpty {
            lastAcceptedClause = nil
            lastAcceptedCaretLocation = nil
        }

        guard shouldProvideCompletions(for: query, text: text, caretLocation: caretLocation) else {
            return SQLAutoCompletionResult(sections: [],
                                           metadata: SQLAutoCompletionEngine.emptyMetadata)
        }

        let options = SQLEngineOptions(enableAliasShortcuts: useTableAliasShortcuts,
                                       keywordCasing: .upper)

        let request = SQLCompletionRequest(text: text,
                                           caretLocation: caretLocation,
                                           dialect: context.databaseType.sqlDialect,
                                           selectedDatabase: context.selectedDatabase,
                                           defaultSchema: context.defaultSchema,
                                           metadata: metadataProvider,
                                           options: options)

        let result = completionEngine.completions(for: request)

        let mapped = mapSuggestions(result.suggestions,
                                    query: query,
                                    context: context)
        let combined = injectHistorySuggestions(base: mapped,
                                                query: query,
                                                context: context)
        let ranked = rankSuggestions(combined, query: query, context: context)

        // Deduplicate already-selected columns in SELECT list
        let final: [SQLAutoCompletionSuggestion]
        if query.clause == .selectList {
            let alreadySelected = parseSelectedColumns(from: text, caretLocation: caretLocation)
            if !alreadySelected.isEmpty {
                final = ranked.filter { suggestion in
                    guard suggestion.kind == .column else { return true }
                    // Extract bare column name from the title (strip alias prefix)
                    let columnName: String
                    if let dotIndex = suggestion.title.lastIndex(of: ".") {
                        columnName = String(suggestion.title[suggestion.title.index(after: dotIndex)...])
                    } else {
                        columnName = suggestion.title
                    }
                    let bare = columnName.trimmingCharacters(in: CharacterSet(charactersIn: "\"[]`"))
                    return !alreadySelected.contains(bare.lowercased())
                }
            } else {
                final = ranked
            }
        } else {
            final = ranked
        }

        let sections = [SQLAutoCompletionSection(title: "Suggestions", suggestions: final)]
        return SQLAutoCompletionResult(sections: sections, metadata: result.metadata)
    }

    private func shouldProvideCompletions(for query: SQLAutoCompletionQuery,
                                          text: String,
                                          caretLocation: Int) -> Bool {
        let trimmedToken = query.token.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedToken.isEmpty && query.pathComponents.isEmpty {
            if query.precedingCharacter == "*" {
                return false
            }
            // In SELECT list: show completions when tables are in scope or after comma
            if query.clause == .selectList {
                if manualTriggerInProgress { return true }
                if query.precedingCharacter == "," { return true }
                if !query.tablesInScope.isEmpty { return true }
                return false
            }
            if isObjectContext(query: query) {
                // In FROM/JOIN clause with tables already in scope, empty token, no comma:
                // suppress unless cursor is immediately after FROM/JOIN keyword with no table yet.
                if (query.clause == .from || query.clause == .joinTarget)
                    && !query.tablesInScope.isEmpty
                    && query.precedingCharacter != "," {
                    if isImmediatelyAfterObjectKeyword(text: text, caretLocation: caretLocation) {
                        return true
                    }
                    return false
                }
                return true
            }
            if isColumnContext(query: query) || query.precedingCharacter == "," {
                let scopeTables = tablesForColumnSuggestions(query: query)
                if !scopeTables.isEmpty {
                    return true
                }
            }
            return false
        }
        if trimmedToken == "*" && query.pathComponents.isEmpty {
            return manualTriggerInProgress
        }
        let tokenLower = trimmedToken.lowercased()
        if SQLAutoCompletionEngine.reservedLeadingKeywords.contains(tokenLower) && query.pathComponents.isEmpty {
            return false
        }
        // In unknown clause with no tables: user is typing SQL structure.
        if query.clause == .unknown && query.tablesInScope.isEmpty && query.pathComponents.isEmpty {
            return false
        }
        // In FROM clause with tables in scope and user is typing on the same line
        // after a table — they may be typing an alias. Only suggest if on a new line.
        if query.clause == .from && !query.tablesInScope.isEmpty
            && query.precedingCharacter != ","
            && !query.pathComponents.isEmpty == false {
            // Check if there's a newline between the last non-whitespace content and cursor
            if !hasNewlineBetweenLastContentAndCursor(text: text, caretLocation: caretLocation) {
                // Same line as table — could be an alias, suppress keywords
                // But still allow if the token matches a keyword (handled by keyword filtering)
            }
        }
        return true
    }

    /// Extracts top-level column references from the SELECT list before the cursor.
    /// Returns a set of lowercased bare column names (without alias/table prefix).
    private func parseSelectedColumns(from text: String, caretLocation: Int) -> Set<String> {
        let nsText = text as NSString
        let clampedLocation = min(caretLocation, nsText.length)

        // Find SELECT keyword before cursor
        let textBeforeCursor = nsText.substring(to: clampedLocation)
        guard let selectRange = textBeforeCursor.range(of: "SELECT",
                                                        options: [.caseInsensitive, .backwards]) else {
            return []
        }
        let afterSelect = textBeforeCursor[selectRange.upperBound...]

        // Handle DISTINCT / TOP
        var columnsPart = afterSelect.trimmingCharacters(in: .whitespacesAndNewlines)
        if columnsPart.lowercased().hasPrefix("distinct") {
            columnsPart = String(columnsPart.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Split by comma, extract column identifiers
        // Only look at top-level commas (not inside parentheses)
        var columns = Set<String>()
        var depth = 0
        var current = ""

        for char in columnsPart {
            if char == "(" { depth += 1 }
            else if char == ")" { depth -= 1 }
            else if char == "," && depth == 0 {
                if let col = extractColumnName(from: current) {
                    columns.insert(col)
                }
                current = ""
                continue
            }
            current.append(char)
        }
        // Don't process the last segment — that's what the user is currently typing

        return columns
    }

    /// Extracts a bare column name from a SELECT expression.
    /// Handles: "col", "t.col", "t.col AS alias", "FUNC(col)" (returns nil for expressions).
    private func extractColumnName(from expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Skip expressions with parentheses (function calls, CASE, subqueries)
        if trimmed.contains("(") || trimmed.contains(")") { return nil }
        // Skip star
        if trimmed.contains("*") { return nil }

        // Handle AS alias — take the part before AS
        let parts = trimmed.components(separatedBy: " ")
        let identifier: String
        if let asIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("AS") == .orderedSame }) {
            identifier = parts[..<asIndex].joined(separator: " ")
        } else if parts.count <= 2 {
            // Could be "col alias" or just "col"
            identifier = parts[0]
        } else {
            return nil
        }

        // Extract bare column name (after last dot)
        let components = identifier.split(separator: ".")
        guard let last = components.last else { return nil }
        let bare = last.trimmingCharacters(in: CharacterSet(charactersIn: "\"[]`"))
        guard !bare.isEmpty else { return nil }
        return bare.lowercased()
    }

    /// Checks if the cursor is immediately after an object keyword (FROM, JOIN, etc.)
    /// with only whitespace between the keyword and cursor — meaning the user hasn't
    /// typed a table name yet after the keyword.
    private func isImmediatelyAfterObjectKeyword(text: String, caretLocation: Int) -> Bool {
        let nsText = text as NSString
        let clampedLocation = min(caretLocation, nsText.length)
        guard clampedLocation > 0 else { return false }

        // Scan backwards from cursor, skipping whitespace
        var pos = clampedLocation - 1
        while pos >= 0 {
            let char = nsText.character(at: pos)
            if char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D {
                pos -= 1
                continue
            }
            break
        }
        guard pos >= 0 else { return false }

        // Extract the word ending at this position
        let wordEnd = pos + 1
        while pos >= 0 {
            let char = nsText.character(at: pos)
            if let scalar = UnicodeScalar(char),
               CharacterSet.alphanumerics.contains(scalar) || char == 0x5F { // _
                pos -= 1
            } else {
                break
            }
        }
        let wordStart = pos + 1
        guard wordStart < wordEnd else { return false }
        let word = nsText.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart)).lowercased()
        return SQLAutoCompletionEngine.objectContextKeywords.contains(word)
    }

    /// Checks if there is a newline character between the last non-whitespace
    /// content before the cursor and the cursor position.
    private func hasNewlineBetweenLastContentAndCursor(text: String, caretLocation: Int) -> Bool {
        let nsText = text as NSString
        let clampedLocation = min(caretLocation, nsText.length)
        guard clampedLocation > 0 else { return false }

        // Scan backwards from cursor to find last non-space character
        var pos = clampedLocation - 1
        while pos >= 0 {
            let char = nsText.character(at: pos)
            if char == 0x0A || char == 0x0D { // \n or \r
                return true
            }
            if char != 0x20 && char != 0x09 { // not space or tab
                return false
            }
            pos -= 1
        }
        return false
    }

    private func isObjectContext(query: SQLAutoCompletionQuery) -> Bool {
        if !query.pathComponents.isEmpty { return true }
        switch query.clause {
        case .from, .joinTarget, .deleteWhere, .withCTE:
            return true
        default:
            break
        }
        guard let keyword = query.precedingKeyword else { return false }
        return SQLAutoCompletionEngine.objectContextKeywords.contains(keyword)
    }

    private func isColumnContext(query: SQLAutoCompletionQuery) -> Bool {
        if query.precedingCharacter == "," { return true }
        if !query.pathComponents.isEmpty { return true }
        switch query.clause {
        case .selectList, .whereClause, .joinCondition, .groupBy, .orderBy, .having, .values, .updateSet, .insertColumns, .deleteWhere:
            return true
        default:
            break
        }
        guard let keyword = query.precedingKeyword else { return false }
        if SQLAutoCompletionEngine.objectContextKeywords.contains(keyword) {
            return false
        }
        return SQLAutoCompletionEngine.columnContextKeywords.contains(keyword)
    }

    private func tablesForColumnSuggestions(query: SQLAutoCompletionQuery) -> [SQLAutoCompletionTableFocus] {
        var tables: [SQLAutoCompletionTableFocus] = []
        if !query.tablesInScope.isEmpty {
            tables = query.tablesInScope
        } else if let focus = query.focusTable {
            tables = [focus]
        }

        guard !tables.isEmpty else { return [] }

        var unique: [SQLAutoCompletionTableFocus] = []
        for table in tables {
            if !unique.contains(where: { $0.isEquivalent(to: table) }) {
                unique.append(table)
            }
        }
        return unique
    }

    static func builtInFunctions(for databaseType: DatabaseType) -> [String] {
        switch databaseType {
        case .microsoftSQL:
            return [
                // Aggregate
                "COUNT", "SUM", "AVG", "MIN", "MAX", "STRING_AGG", "COUNT_BIG",
                // String
                "LEN", "LOWER", "UPPER", "CONCAT", "CHARINDEX", "PATINDEX",
                "REPLACE", "STUFF", "QUOTENAME", "TRIM", "LTRIM", "RTRIM",
                "LEFT", "RIGHT", "SUBSTRING", "REVERSE", "REPLICATE",
                // Date/Time
                "GETDATE", "GETUTCDATE", "SYSDATETIME", "DATEADD", "DATEDIFF",
                "DATEPART", "DATENAME", "EOMONTH", "FORMAT",
                // Conversion
                "CONVERT", "CAST", "TRY_CONVERT", "TRY_CAST", "PARSE", "TRY_PARSE",
                // Null handling
                "ISNULL", "COALESCE", "NULLIF",
                // Math
                "ROUND", "ABS", "CEILING", "FLOOR", "POWER", "SQRT", "SIGN",
                // Window
                "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE",
                "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",
                // JSON
                "JSON_VALUE", "JSON_QUERY", "JSON_MODIFY", "ISJSON", "OPENJSON",
                // System
                "NEWID", "SCOPE_IDENTITY", "OBJECT_ID", "DB_NAME", "SCHEMA_NAME",
                "ERROR_MESSAGE", "ERROR_NUMBER",
                // Logic
                "IIF", "CHOOSE"
            ]
        case .postgresql:
            return [
                // Aggregate
                "COUNT", "SUM", "AVG", "MIN", "MAX", "STRING_AGG", "ARRAY_AGG",
                "BOOL_AND", "BOOL_OR", "JSONB_AGG", "JSON_AGG",
                // String
                "LOWER", "UPPER", "CONCAT", "LEFT", "RIGHT", "REPLACE",
                "REGEXP_REPLACE", "SPLIT_PART", "TRIM", "LTRIM", "RTRIM",
                "LENGTH", "CHAR_LENGTH", "POSITION", "SUBSTRING", "REVERSE",
                "INITCAP", "REPEAT", "LPAD", "RPAD",
                // Date/Time
                "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "AGE",
                "DATE_TRUNC", "DATE_PART", "EXTRACT", "TO_CHAR", "TO_DATE",
                "TO_TIMESTAMP", "MAKE_INTERVAL", "MAKE_DATE",
                // Conversion
                "CAST", "TO_NUMBER",
                // Null handling
                "COALESCE", "NULLIF",
                // Math
                "ROUND", "ABS", "CEIL", "FLOOR", "POWER", "SQRT", "SIGN",
                "GREATEST", "LEAST", "MOD", "RANDOM",
                // Window
                "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE",
                "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
                // JSON
                "JSON_BUILD_OBJECT", "JSON_BUILD_ARRAY",
                "JSONB_BUILD_OBJECT", "JSONB_BUILD_ARRAY",
                "JSON_EXTRACT_PATH_TEXT", "JSONB_EXTRACT_PATH_TEXT",
                "TO_JSON", "TO_JSONB", "JSON_TYPEOF", "JSONB_TYPEOF",
                // Array
                "UNNEST", "ARRAY_LENGTH", "ARRAY_POSITION", "ARRAY_REMOVE",
                "ARRAY_APPEND", "ARRAY_CAT",
                // Utility
                "GENERATE_SERIES", "GENERATE_SUBSCRIPTS",
                "PG_TYPEOF"
            ]
        case .mysql:
            return [
                "COUNT", "SUM", "AVG", "MIN", "MAX",
                "LOWER", "UPPER", "CONCAT", "LEFT", "RIGHT",
                "NOW", "CURDATE", "CURTIME", "DATE_ADD", "DATE_SUB",
                "COALESCE", "IFNULL", "ROUND", "TRIM",
                "REPLACE", "SUBSTRING", "CHAR_LENGTH", "LENGTH",
                "DATE_FORMAT", "STR_TO_DATE",
                "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY",
                "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD",
                "CAST", "CONVERT", "NULLIF", "IF", "GROUP_CONCAT"
            ]
        case .sqlite:
            return [
                "COUNT", "SUM", "AVG", "MIN", "MAX",
                "LOWER", "UPPER", "LENGTH", "REPLACE", "SUBSTR", "TRIM",
                "DATE", "DATETIME", "TIME", "STRFTIME", "JULIANDAY",
                "COALESCE", "IFNULL", "NULLIF",
                "ROUND", "ABS", "RANDOM",
                "TYPEOF", "UNICODE", "QUOTE",
                "INSTR", "HEX", "ZEROBLOB",
                "GROUP_CONCAT", "TOTAL",
                "JSON", "JSON_EXTRACT", "JSON_ARRAY", "JSON_OBJECT",
                "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD"
            ]
        }
    }

}

private extension DatabaseType {
    var sqlDialect: SQLDialect {
        switch self {
        case .postgresql:
            return .postgresql
        case .mysql:
            return .mysql
        case .sqlite:
            return .sqlite
        case .microsoftSQL:
            return .microsoftSQL
        }
    }
}
