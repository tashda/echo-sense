import Foundation

struct SQLStructureMetadataProvider: SQLMetadataProvider {
    let catalogsByDatabase: [String: SQLDatabaseCatalog]
    let defaultCatalog: SQLDatabaseCatalog
    let orderedDatabaseNames: [String]

    var databaseNames: [String] { orderedDatabaseNames }

    func catalog(for database: String?) -> SQLDatabaseCatalog? {
        if let database,
           let catalog = catalogsByDatabase[database.lowercased()] {
            return catalog
        }
        return defaultCatalog
    }

    static var empty: SQLStructureMetadataProvider {
        SQLStructureMetadataProvider(catalogsByDatabase: [:],
                                     defaultCatalog: SQLDatabaseCatalog(schemas: []),
                                     orderedDatabaseNames: [])
    }
}

struct SQLMetadataCatalog {
    struct ObjectEntry {
        let database: String
        let schema: String
        let object: EchoSenseSchemaObjectInfo
    }

    struct ObjectKey: Hashable {
        let database: String
        let schema: String
        let name: String
    }

    struct NameKey: Hashable {
        let schema: String
        let name: String
    }

    let objectsByKey: [ObjectKey: [ObjectEntry]]
    /// The same entries by schema and name, and by name alone, so lookups without a database
    /// don't scan every object: completion maps hundreds of suggestions on each keystroke.
    let objectsBySchemaAndName: [NameKey: [ObjectEntry]]
    let objectsByName: [String: [ObjectEntry]]
    let metadataProvider: SQLStructureMetadataProvider

    init(context: SQLEditorCompletionContext,
         builtInFunctions: [String],
         includeSystemSchemas: Bool) {
        guard let structure = context.structure else {
            let builtIns = SQLMetadataCatalog.builtInSchema(functions: builtInFunctions)
            let defaultCatalog = builtIns.objects.isEmpty ? SQLDatabaseCatalog(schemas: []) : SQLDatabaseCatalog(schemas: [builtIns])
            self.objectsByKey = [:]
            self.objectsBySchemaAndName = [:]
            self.objectsByName = [:]
            self.metadataProvider = SQLStructureMetadataProvider(catalogsByDatabase: [:],
                                                                 defaultCatalog: defaultCatalog,
                                                                 orderedDatabaseNames: [])
            return
        }

        var objectsIndex: [ObjectKey: [ObjectEntry]] = [:]
        var bySchemaAndName: [NameKey: [ObjectEntry]] = [:]
        var byName: [String: [ObjectEntry]] = [:]
        var catalogsByDatabase: [String: SQLDatabaseCatalog] = [:]
        var orderedDatabaseNames: [String] = []
        // The same Built-in schema goes into every database: made once, not per database (with
        // hundreds of databases it was most of the time spent rebuilding a catalog).
        let builtInSchema = builtInFunctions.isEmpty ? nil : SQLMetadataCatalog.builtInSchema(functions: builtInFunctions)

        for database in structure.databases {
            let databaseLower = database.name.lowercased()
            orderedDatabaseNames.append(database.name)
            var schemasForDatabase: [SQLSchema] = []

            for schema in database.schemas {
                if !includeSystemSchemas,
                   SQLMetadataCatalog.isSystemSchema(schema.name, databaseType: context.databaseType) {
                    continue
                }
                let schemaName = schema.name
                let schemaLower = schemaName.lowercased()
                var sqlObjects: [SQLObject] = []

                for object in schema.objects {
                    guard let sqlObject = SQLMetadataCatalog.sqlObject(from: object) else { continue }
                    sqlObjects.append(sqlObject)

                    let nameLower = object.name.lowercased()
                    let key = ObjectKey(database: databaseLower,
                                        schema: schemaLower,
                                        name: nameLower)
                    let entry = ObjectEntry(database: database.name,
                                            schema: schemaName,
                                            object: object)
                    objectsIndex[key, default: []].append(entry)
                    bySchemaAndName[NameKey(schema: schemaLower, name: nameLower), default: []].append(entry)
                    byName[nameLower, default: []].append(entry)
                }

                schemasForDatabase.append(SQLSchema(name: schemaName, objects: sqlObjects))
            }

            if let builtInSchema {
                schemasForDatabase.append(builtInSchema)
            }

            catalogsByDatabase[databaseLower] = SQLDatabaseCatalog(schemas: schemasForDatabase)
        }

        let defaultCatalog: SQLDatabaseCatalog
        if let selected = context.selectedDatabase?.lowercased(),
           let selectedCatalog = catalogsByDatabase[selected] {
            defaultCatalog = selectedCatalog
        } else if let first = catalogsByDatabase.values.first {
            defaultCatalog = first
        } else {
            let builtIns = builtInSchema ?? SQLMetadataCatalog.builtInSchema(functions: builtInFunctions)
            defaultCatalog = builtIns.objects.isEmpty ? SQLDatabaseCatalog(schemas: []) : SQLDatabaseCatalog(schemas: [builtIns])
        }

        self.objectsByKey = objectsIndex
        self.objectsBySchemaAndName = bySchemaAndName
        self.objectsByName = byName
        self.metadataProvider = SQLStructureMetadataProvider(catalogsByDatabase: catalogsByDatabase,
                                                             defaultCatalog: defaultCatalog,
                                                             orderedDatabaseNames: orderedDatabaseNames)
    }

    func object(database: String?, schema: String, name: String) -> ObjectEntry? {
        let schemaLower = schema.lowercased()
        let nameLower = name.lowercased()

        if let database {
            let key = ObjectKey(database: database.lowercased(),
                                schema: schemaLower,
                                name: nameLower)
            if let entries = objectsByKey[key], !entries.isEmpty {
                return entries.first
            }
        }

        let matches = objectsBySchemaAndName[NameKey(schema: schemaLower, name: nameLower)] ?? []

        guard !matches.isEmpty else { return nil }

        if let database {
            let lowered = database.lowercased()
            if let match = matches.first(where: { $0.database.lowercased() == lowered }) {
                return match
            }
        }

        return matches.first
    }

    func objects(named name: String) -> [ObjectEntry] {
        objectsByName[name.lowercased()] ?? []
    }

    private static func sqlObject(from object: EchoSenseSchemaObjectInfo) -> SQLObject? {
        let type: SQLObject.ObjectType
        switch object.type {
        case .table:
            type = .table
        case .view:
            type = .view
        case .materializedView:
            type = .materializedView
        case .function:
            type = .function
        case .trigger:
            return nil
        case .procedure:
            return nil
        }

        let columns = object.columns.map {
            SQLColumn(name: $0.name,
                      dataType: $0.dataType,
                      isPrimaryKey: $0.isPrimaryKey,
                      isForeignKey: $0.foreignKey != nil,
                      isNullable: $0.isNullable)
        }
        let foreignKeys = SQLMetadataCatalog.foreignKeys(from: object.columns)

        return SQLObject(name: object.name,
                         type: type,
                         columns: columns,
                         foreignKeys: foreignKeys)
    }

    private static func foreignKeys(from columns: [EchoSenseColumnInfo]) -> [SQLForeignKey] {
        var grouped: [String: (columns: [String], schema: String?, table: String, referenced: [String])] = [:]

        for column in columns {
            guard let fk = column.foreignKey else { continue }
            var entry = grouped[fk.constraintName] ?? ([], fk.referencedSchema, fk.referencedTable, [])
            entry.columns.append(column.name)
            entry.referenced.append(fk.referencedColumn)
            entry.schema = fk.referencedSchema
            entry.table = fk.referencedTable
            grouped[fk.constraintName] = entry
        }

        return grouped.map { name, payload in
            SQLForeignKey(name: name,
                          columns: payload.columns,
                          referencedSchema: payload.schema,
                          referencedTable: payload.table,
                          referencedColumns: payload.referenced)
        }
    }

    private static func builtInSchema(functions: [String]) -> SQLSchema {
        let objects = functions.map { functionName in
            SQLObject(name: functionName,
                      type: .function,
                      columns: [],
                      foreignKeys: [])
        }
        return SQLSchema(name: "Built-in", objects: objects)
    }

    private static func isSystemSchema(_ name: String, databaseType: EchoSenseDatabaseType) -> Bool {
        let lower = name.lowercased()
        switch databaseType {
        case .postgresql:
            if lower == "pg_catalog" || lower == "information_schema" { return true }
            if lower.hasPrefix("pg_temp") || lower.hasPrefix("pg_toast") { return true }
            return false
        case .mysql:
            return lower == "information_schema" ||
                lower == "performance_schema" ||
                lower == "mysql" ||
                lower == "sys"
        case .microsoftSQL:
            return lower == "sys" || lower == "information_schema"
        case .sqlite:
            return false
        }
    }
}
