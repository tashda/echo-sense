import Foundation

extension SQLAutoCompletionEngine {

    // MARK: - Clean API

    /// Returns completions for the given text at the specified cursor position.
    ///
    /// This is the primary entry point for the clean API. Consumers provide raw text
    /// and a cursor position; EchoSense handles all parsing, filtering, ranking, and
    /// deduplication internally.
    ///
    /// - Parameters:
    ///   - text: The full SQL text in the editor.
    ///   - caretLocation: The cursor position (UTF-16 offset) in the text.
    /// - Returns: A ``SQLCompletionResponse`` with ranked suggestions and metadata.
    public func completions(in text: String, at caretLocation: Int) -> SQLCompletionResponse {
        performCompletions(in: text, at: caretLocation)
    }

    /// Returns completions triggered manually (e.g. via keyboard shortcut).
    ///
    /// Behaves identically to ``completions(in:at:)`` but temporarily relaxes
    /// suppression rules so that suggestions appear even in contexts where
    /// automatic completion would stay silent.
    public func manualCompletions(in text: String, at caretLocation: Int) -> SQLCompletionResponse {
        manualTriggerInProgress = true
        defer { manualTriggerInProgress = false }
        return performCompletions(in: text, at: caretLocation)
    }

    /// Records that the user accepted a suggestion from a previous response.
    ///
    /// This feeds the history store so future completions can boost frequently
    /// selected items, and sets up post-commit suppression to avoid immediately
    /// re-showing the popover at the same position.
    public func recordSelection(_ suggestion: SQLAutoCompletionSuggestion,
                                from response: SQLCompletionResponse) {
        historyStore.record(suggestion, context: context)
        lastAcceptedClause = response.clause
        lastAcceptedCaretLocation = response.replacementRange.location + response.replacementRange.length
    }

    /// Updates all engine preferences from a consolidated struct.
    public func updatePreferences(_ preferences: SQLCompletionPreferences) {
        updateHistoryPreference(includeHistory: preferences.includeHistory)
        updateSystemSchemaVisibility(includeSystemSchemas: preferences.includeSystemSchemas)
        updateQualifiedInsertionPreference(includeSchema: preferences.qualifyTableInsertions)
        // autoJoinOnClause is reserved for future use when join-on-clause
        // generation is configurable at the engine level.
    }

    /// Records table usage from an executed query.
    ///
    /// Call this after a query is successfully executed. EchoSense parses the
    /// FROM/JOIN clauses to extract table references and records them to history.
    /// This allows history to learn from all queries, not just popover selections.
    ///
    /// - Parameter sql: The SQL text that was executed.
    public func recordQueryExecution(_ sql: String) {
        guard let context else { return }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let catalogForParser: SQLDatabaseCatalog
        if let provider = catalog?.metadataProvider {
            catalogForParser = provider.catalog(for: context.selectedDatabase) ?? SQLDatabaseCatalog(schemas: [])
        } else {
            catalogForParser = SQLDatabaseCatalog(schemas: [])
        }

        let parser = SQLContextParser(text: sql,
                                       caretLocation: sql.count,
                                       dialect: context.databaseType.completionDialect,
                                       catalog: catalogForParser)
        let parsed = parser.parse()

        for tableRef in parsed.tablesInScope {
            // Build a minimal suggestion for history recording
            let schemaName = tableRef.schema ?? context.defaultSchema ?? ""
            let id = "object|\(schemaName.lowercased())|\(tableRef.name.lowercased())"

            // Look up the table in the catalog for full metadata
            var tableColumns: [SQLAutoCompletionSuggestion.TableColumn]?
            for schema in catalogForParser.schemas {
                if let obj = schema.objects.first(where: { $0.name.caseInsensitiveCompare(tableRef.name) == .orderedSame }) {
                    tableColumns = obj.columns.map {
                        SQLAutoCompletionSuggestion.TableColumn(name: $0.name, dataType: $0.dataType,
                                                                 isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey)
                    }
                    break
                }
            }

            let suggestion = SQLAutoCompletionSuggestion(
                id: id,
                title: tableRef.name,
                subtitle: schemaName.isEmpty ? nil : schemaName,
                detail: schemaName.isEmpty ? tableRef.name : "\(schemaName).\(tableRef.name)",
                insertText: tableRef.name,
                kind: .table,
                origin: .init(database: context.selectedDatabase, schema: schemaName, object: tableRef.name),
                tableColumns: tableColumns
            )

            historyStore.record(suggestion, context: context)
        }
    }

    /// Clears post-commit suppression state so completions can appear again
    /// at the current cursor position.
    public func clearSuppression() {
        clearPostCommitSuppression()
    }

    // MARK: - Internal

    private func performCompletions(in text: String, at caretLocation: Int) -> SQLCompletionResponse {
        let empty = SQLCompletionResponse(suggestions: [],
                                           replacementRange: NSRange(location: caretLocation, length: 0),
                                           token: "",
                                           clause: .unknown,
                                           isMetadataLimited: isMetadataLimited,
                                           caretLocation: caretLocation)

        guard let context else { return empty }
        guard !text.isEmpty else { return empty }

        let nsText = text as NSString
        let clampedCaret = max(0, min(caretLocation, nsText.length))

        // Parse the SQL context at the cursor position.
        let catalogForParser: SQLDatabaseCatalog
        if let provider = catalog?.metadataProvider {
            catalogForParser = provider.catalog(for: context.selectedDatabase) ?? SQLDatabaseCatalog(schemas: [])
        } else {
            catalogForParser = SQLDatabaseCatalog(schemas: [])
        }

        // A long script is parsed around the caret only: tokenising and segmenting all of it on each
        // keystroke made typing in a script of a few hundred lines lag (the parser scopes to the
        // statement at the caret anyway).
        let parseRange = Self.parseWindow(in: nsText, caret: clampedCaret)
        let parser = SQLContextParser(text: parseRange.length == nsText.length ? text : nsText.substring(with: parseRange),
                                       caretLocation: clampedCaret - parseRange.location,
                                       dialect: context.databaseType.completionDialect,
                                       catalog: catalogForParser)
        let parsed = parser.parse()

        // Extract token, prefix, and path components from the parsed context.
        let token = parsed.currentToken
        let components = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let prefix = components.last ?? ""
        let pathComponents = Array(components.dropLast().filter { !$0.isEmpty })

        // Compute the replacement range: covers only the prefix portion.
        let replacementRange = NSRange(location: clampedCaret - prefix.count, length: prefix.count)

        // Compute the preceding character by scanning backward from the token start.
        let tokenStart = clampedCaret - token.count
        let precedingCharacter = Self.findPrecedingCharacter(in: nsText, before: tokenStart)

        // Convert parsed tables to the query model.
        let tablesInScope = parsed.tablesInScope.map {
            SQLAutoCompletionTableFocus(database: $0.database, schema: $0.schema, name: $0.name, alias: $0.alias)
        }
        let focusTable = parsed.focusTable.map {
            SQLAutoCompletionTableFocus(database: $0.database, schema: $0.schema, name: $0.name, alias: $0.alias)
        }

        // ── Suppression rules (per spec) ──────────────────────────────

        let emptyResponse = SQLCompletionResponse(suggestions: [],
                                                    replacementRange: replacementRange,
                                                    token: token,
                                                    clause: parsed.clause,
                                                    isMetadataLimited: isMetadataLimited,
                                                    caretLocation: clampedCaret)

        if !manualTriggerInProgress {
            // 1. Inside string literals → silence
            if Self.isInsideStringLiteral(in: nsText, at: clampedCaret) {
                return emptyResponse
            }

            // 2. Inside comments → silence
            if Self.isInsideComment(in: nsText, at: clampedCaret) {
                return emptyResponse
            }

            // 3. Column contexts without tables → silence
            if tablesInScope.isEmpty && pathComponents.isEmpty {
                let columnClauses: Set<SQLClause> = [
                    .selectList, .whereClause, .groupBy, .orderBy, .having,
                    .joinCondition, .values, .updateSet, .unknown
                ]
                if columnClauses.contains(parsed.clause) {
                    return emptyResponse
                }
            }

            // 4. Alias typing: on same line after a table in FROM, no dot → silence
            //    e.g., "from ba_tbl ba" — "ba" is an alias
            if (parsed.clause == .from || parsed.clause == .joinTarget)
                && !tablesInScope.isEmpty
                && !token.isEmpty
                && pathComponents.isEmpty
                && precedingCharacter != "," {
                // Check if the token is on the same line as a table name (not after a keyword)
                if !Self.isImmediatelyAfterObjectKeyword(in: nsText, before: tokenStart) {
                    return emptyResponse
                }
            }

            // 5. Reserved keyword typing → silence (user knows what they're typing)
            let tokenLower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !tokenLower.isEmpty && pathComponents.isEmpty {
                let reservedKeywords: Set<String> = [
                    "select", "from", "where", "join", "inner", "left", "right", "full",
                    "outer", "cross", "on", "group", "by", "having", "order", "limit",
                    "offset", "insert", "into", "values", "update", "set", "delete",
                    "create", "drop", "alter", "and", "or", "not", "in", "between",
                    "like", "is", "null", "as", "case", "when", "then", "else", "end",
                    "union", "intersect", "except", "exists", "with", "distinct",
                    "asc", "desc", "top", "returning", "using", "go", "begin", "end",
                    "declare", "exec", "execute", "if", "while", "return", "print"
                ]
                if reservedKeywords.contains(tokenLower) {
                    return emptyResponse
                }
            }

            // 6. After a completed expression in WHERE/HAVING — silence until
            //    continuation keyword (AND, OR, ORDER, GROUP, etc.)
            //    e.g., "WHERE user = 'John' " → silence
            //    e.g., "WHERE user = 'John' AND " → show columns (handled by keyword space trigger)
            //    The preceding character after a completed expression is typically:
            //    ' (closing string), ) (closing paren), digit, or identifier end
            if (parsed.clause == .whereClause || parsed.clause == .having)
                && !token.isEmpty
                && pathComponents.isEmpty {
                let precKw = parsed.precedingKeyword?.lowercased()
                let isAfterContinuation = precKw == "and" || precKw == "or"
                    || precKw == "where" || precKw == "having" || precKw == "on"
                    || precKw == "not" || precKw == "between"
                if !isAfterContinuation {
                    // Check if the preceding context is a completed expression
                    // (preceding char is closing quote, paren, digit, or identifier)
                    if let prevChar = precedingCharacter {
                        let completedExpressionChars: Set<Character> = ["'", ")", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
                        if completedExpressionChars.contains(prevChar) {
                            return emptyResponse
                        }
                    }
                }
            }
        }

        // Build the query for the existing pipeline.
        // First, run the pipeline and check if we got meaningful results.
        // If the result only has keywords (no tables/columns/schemas), and the user
        // typed a dot-path (e.g., "employees."), suppress — it means the path
        // couldn't be resolved to known schemas.
        let query = SQLAutoCompletionQuery(token: token,
                                            prefix: prefix,
                                            pathComponents: pathComponents,
                                            replacementRange: replacementRange,
                                            precedingKeyword: parsed.precedingKeyword,
                                            precedingCharacter: precedingCharacter,
                                            focusTable: focusTable,
                                            tablesInScope: tablesInScope,
                                            clause: parsed.clause)

        // Run through the existing suggestions pipeline.
        let result = suggestions(for: query, text: text, caretLocation: clampedCaret)

        // Flatten sections into a single ranked list, limited to 60 items.
        var allSuggestions = result.sections.flatMap(\.suggestions)

        // If the user typed a dot-path (e.g., "employees.") and the results only
        // contain keywords (no tables/columns/schemas), suppress — the path
        // couldn't be resolved to known schemas. Show nothing instead of noise.
        if !pathComponents.isEmpty {
            let hasObjectSuggestions = allSuggestions.contains {
                $0.kind == .table || $0.kind == .view || $0.kind == .materializedView
                || $0.kind == .column || $0.kind == .schema || $0.kind == .function
            }
            if !hasObjectSuggestions {
                allSuggestions = []
            }
        }

        let limited = allSuggestions.count > 60 ? Array(allSuggestions.prefix(60)) : allSuggestions

        return SQLCompletionResponse(suggestions: limited,
                                      replacementRange: replacementRange,
                                      token: token,
                                      clause: parsed.clause,
                                      isMetadataLimited: isMetadataLimited,
                                      caretLocation: clampedCaret)
    }

    /// Scripts longer than this are parsed around the caret (see `parseWindow`).
    nonisolated(unsafe) static var parseWindowThreshold = 8_000

    /// The part of the script the parser needs: from just after the last `;` before the caret (at
    /// most 4000 characters back, else the start of that line) to the next `;` after it (at most
    /// 6000 on, else the end of that line). All of a script up to `parseWindowThreshold`.
    static func parseWindow(in text: NSString, caret: Int) -> NSRange {
        let full = NSRange(location: 0, length: text.length)
        guard text.length > parseWindowThreshold else { return full }
        let lower = max(caret - 4_000, 0)
        var start = text.lineRange(for: NSRange(location: lower, length: 0)).location
        if caret > start {
            let before = text.range(of: ";", options: [.literal, .backwards], range: NSRange(location: start, length: caret - start))
            if before.location != NSNotFound { start = before.location + 1 }
        }
        let upper = min(caret + 6_000, text.length)
        var end = NSMaxRange(text.lineRange(for: NSRange(location: upper, length: 0)))
        if upper > caret {
            let after = text.range(of: ";", options: .literal, range: NSRange(location: caret, length: upper - caret))
            if after.location != NSNotFound { end = after.location + 1 }
        }
        return NSRange(location: start, length: max(min(end, text.length) - start, 0))
    }

    /// Checks if the caret is inside a string literal (single-quoted).
    private static func isInsideStringLiteral(in text: NSString, at position: Int) -> Bool {
        guard position > 0 else { return false }
        var inString = false
        var i = 0
        while i < position {
            let char = text.character(at: i)
            if char == 0x27 { // single quote '
                inString.toggle()
            }
            i += 1
        }
        return inString
    }

    /// Checks if the caret is inside a SQL comment (line or block).
    private static func isInsideComment(in text: NSString, at position: Int) -> Bool {
        guard position > 0 else { return false }
        var i = 0
        while i < position {
            let char = text.character(at: i)
            // Line comment: --
            if char == 0x2D && i + 1 < text.length && text.character(at: i + 1) == 0x2D {
                // Find end of line
                var j = i + 2
                while j < text.length && text.character(at: j) != 0x0A { j += 1 }
                if position <= j { return true }
                i = j + 1
                continue
            }
            // Block comment: /* ... */
            if char == 0x2F && i + 1 < text.length && text.character(at: i + 1) == 0x2A {
                var j = i + 2
                while j + 1 < text.length {
                    if text.character(at: j) == 0x2A && text.character(at: j + 1) == 0x2F {
                        j += 2
                        break
                    }
                    j += 1
                }
                if position < j { return true }
                i = j
                continue
            }
            // Skip string literals
            if char == 0x27 { // '
                i += 1
                while i < text.length && text.character(at: i) != 0x27 { i += 1 }
            }
            i += 1
        }
        return false
    }

    /// Checks if the position is immediately after an object keyword (FROM/JOIN/etc.)
    /// with only whitespace between the keyword and the position.
    private static func isImmediatelyAfterObjectKeyword(in text: NSString, before position: Int) -> Bool {
        guard position > 0 else { return false }
        // Scan backwards skipping whitespace to find the last word
        var pos = position - 1
        while pos >= 0 {
            let char = text.character(at: pos)
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
            let char = text.character(at: pos)
            if let scalar = UnicodeScalar(char),
               CharacterSet.alphanumerics.contains(scalar) || char == 0x5F {
                pos -= 1
            } else {
                break
            }
        }
        let wordStart = pos + 1
        guard wordStart < wordEnd else { return false }
        let word = text.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart)).lowercased()

        let objectKeywords: Set<String> = [
            "from", "join", "inner", "left", "right", "full", "outer", "cross",
            "update", "into", "delete"
        ]
        return objectKeywords.contains(word)
    }

    /// Scans backward from `position` in `text` to find the first non-whitespace character.
    private static func findPrecedingCharacter(in text: NSString, before position: Int) -> Character? {
        guard position > 0 else { return nil }
        var pos = position - 1
        while pos >= 0 {
            let unichar = text.character(at: pos)
            guard let scalar = UnicodeScalar(unichar) else {
                pos -= 1
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pos -= 1
                continue
            }
            return Character(scalar)
        }
        return nil
    }
}

// MARK: - DatabaseType dialect conversion (internal)

private extension EchoSenseDatabaseType {
    var completionDialect: SQLDialect {
        switch self {
        case .postgresql: return .postgresql
        case .mysql: return .mysql
        case .sqlite: return .sqlite
        case .microsoftSQL: return .microsoftSQL
        }
    }
}
