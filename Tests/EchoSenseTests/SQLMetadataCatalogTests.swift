import Foundation
import Testing
@testable import EchoSense

private func makeStructure() -> EchoSenseDatabaseStructure {
    let idColumn = EchoSenseColumnInfo(name: "id", dataType: "integer", isPrimaryKey: true, isNullable: false)
    let nameColumn = EchoSenseColumnInfo(name: "name", dataType: "text", isPrimaryKey: false, isNullable: true)
    let fk = EchoSenseForeignKeyReference(constraintName: "fk_orders_user",
                                          referencedSchema: "public",
                                          referencedTable: "users",
                                          referencedColumn: "id")
    let userIdColumn = EchoSenseColumnInfo(name: "user_id", dataType: "integer",
                                            isPrimaryKey: false, isNullable: false,
                                            foreignKey: fk)
    let amountColumn = EchoSenseColumnInfo(name: "amount", dataType: "numeric",
                                            isPrimaryKey: false, isNullable: true)

    let usersTable = EchoSenseSchemaObjectInfo(name: "users", schema: "public",
                                                type: .table, columns: [idColumn, nameColumn])
    let ordersTable = EchoSenseSchemaObjectInfo(name: "orders", schema: "public",
                                                 type: .table, columns: [idColumn, userIdColumn, amountColumn])
    let usersView = EchoSenseSchemaObjectInfo(name: "active_users", schema: "public",
                                               type: .view, columns: [idColumn, nameColumn])
    let trigger = EchoSenseSchemaObjectInfo(name: "audit_trigger", schema: "public",
                                             type: .trigger, columns: [])

    let publicSchema = EchoSenseSchemaInfo(name: "public", objects: [usersTable, ordersTable, usersView, trigger])
    let database = EchoSenseDatabaseInfo(name: "testdb", schemas: [publicSchema])
    return EchoSenseDatabaseStructure(databases: [database])
}

private func makeCatalog(includeSystemSchemas: Bool = false) -> SQLMetadataCatalog {
    let context = SQLEditorCompletionContext(databaseType: .postgresql,
                                              selectedDatabase: "testdb",
                                              defaultSchema: "public",
                                              structure: makeStructure())
    return SQLMetadataCatalog(context: context, builtInFunctions: ["count", "sum", "avg"],
                               includeSystemSchemas: includeSystemSchemas)
}

// MARK: - Object Lookup

@Test
func findsObjectByName() {
    let catalog = makeCatalog()
    let entry = catalog.object(database: "testdb", schema: "public", name: "users")

    #expect(entry != nil)
    #expect(entry?.object.name == "users")
    #expect(entry?.object.type == .table)
}

@Test
func objectLookupIsCaseInsensitive() {
    let catalog = makeCatalog()
    let entry = catalog.object(database: "TESTDB", schema: "PUBLIC", name: "USERS")

    #expect(entry != nil)
    #expect(entry?.object.name == "users")
}

@Test
func findsObjectWithoutDatabase() {
    let catalog = makeCatalog()
    let entry = catalog.object(database: nil, schema: "public", name: "orders")

    #expect(entry != nil)
    #expect(entry?.object.name == "orders")
}

@Test
func returnsNilForNonexistentObject() {
    let catalog = makeCatalog()
    let entry = catalog.object(database: "testdb", schema: "public", name: "nonexistent")

    #expect(entry == nil)
}

// MARK: - Objects Named

@Test
func findsAllObjectsNamed() {
    let catalog = makeCatalog()
    let entries = catalog.objects(named: "users")

    #expect(entries.count == 1)
    #expect(entries[0].object.name == "users")
}

@Test
func objectsNamedIsCaseInsensitive() {
    let catalog = makeCatalog()
    let entries = catalog.objects(named: "USERS")

    #expect(entries.count == 1)
}

// MARK: - Triggers/Procedures Filtered

@Test
func triggersAreFilteredFromMetadata() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider
    let defaultCatalog = provider.catalog(for: "testdb")

    #expect(defaultCatalog != nil)
    let allObjects = defaultCatalog?.schemas.flatMap(\.objects) ?? []
    let triggerObjects = allObjects.filter { $0.name == "audit_trigger" }
    #expect(triggerObjects.isEmpty)
}

// MARK: - Built-in Functions

@Test
func builtInFunctionsIncluded() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let builtInSchema = dbCatalog?.schemas.first { $0.name == "Built-in" }
    #expect(builtInSchema != nil)

    let functionNames = builtInSchema?.objects.map(\.name) ?? []
    #expect(functionNames.contains("count"))
    #expect(functionNames.contains("sum"))
    #expect(functionNames.contains("avg"))
}

// MARK: - Foreign Keys

@Test
func foreignKeysExtracted() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let publicSchema = dbCatalog?.schemas.first { $0.name == "public" }
    let ordersObject = publicSchema?.objects.first { $0.name == "orders" }

    #expect(ordersObject != nil)
    #expect(!ordersObject!.foreignKeys.isEmpty)

    let fk = ordersObject?.foreignKeys.first
    #expect(fk?.referencedTable == "users")
    #expect(fk?.columns == ["user_id"])
    #expect(fk?.referencedColumns == ["id"])
}

// MARK: - Metadata Provider

@Test
func metadataProviderReturnsDefaultCatalog() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider

    let result = provider.catalog(for: nil)
    #expect(result != nil)
}

@Test
func metadataProviderReturnsNamedCatalog() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider

    let result = provider.catalog(for: "testdb")
    #expect(result != nil)
}

@Test
func metadataProviderFallsBackToDefault() {
    let catalog = makeCatalog()
    let provider = catalog.metadataProvider

    let result = provider.catalog(for: "nonexistent")
    #expect(result != nil) // Falls back to default
}

// MARK: - System Schema Filtering

@Test
func systemSchemasFilteredByDefault() {
    let pgCatalogSchema = EchoSenseSchemaInfo(name: "pg_catalog", objects: [])
    let infoSchema = EchoSenseSchemaInfo(name: "information_schema", objects: [])
    let publicSchema = EchoSenseSchemaInfo(name: "public", objects: [])
    let database = EchoSenseDatabaseInfo(name: "testdb", schemas: [pgCatalogSchema, infoSchema, publicSchema])
    let structure = EchoSenseDatabaseStructure(databases: [database])
    let context = SQLEditorCompletionContext(databaseType: .postgresql,
                                              selectedDatabase: "testdb",
                                              structure: structure)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: [],
                                      includeSystemSchemas: false)
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let schemaNames = dbCatalog?.schemas.map(\.name) ?? []
    #expect(!schemaNames.contains("pg_catalog"))
    #expect(!schemaNames.contains("information_schema"))
    #expect(schemaNames.contains("public"))
}

@Test
func systemSchemasIncludedWhenRequested() {
    let pgCatalogSchema = EchoSenseSchemaInfo(name: "pg_catalog", objects: [])
    let publicSchema = EchoSenseSchemaInfo(name: "public", objects: [])
    let database = EchoSenseDatabaseInfo(name: "testdb", schemas: [pgCatalogSchema, publicSchema])
    let structure = EchoSenseDatabaseStructure(databases: [database])
    let context = SQLEditorCompletionContext(databaseType: .postgresql,
                                              selectedDatabase: "testdb",
                                              structure: structure)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: [],
                                      includeSystemSchemas: true)
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let schemaNames = dbCatalog?.schemas.map(\.name) ?? []
    #expect(schemaNames.contains("pg_catalog"))
    #expect(schemaNames.contains("public"))
}

// MARK: - Empty Context

@Test
func handlesEmptyStructure() {
    let context = SQLEditorCompletionContext(databaseType: .postgresql)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: [],
                                      includeSystemSchemas: false)

    #expect(catalog.objectsByKey.isEmpty)
    let provider = catalog.metadataProvider
    let result = provider.catalog(for: nil)
    #expect(result != nil) // Returns empty catalog, not nil
}

@Test
func handlesEmptyStructureWithBuiltIns() {
    let context = SQLEditorCompletionContext(databaseType: .postgresql)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: ["now"],
                                      includeSystemSchemas: false)

    let provider = catalog.metadataProvider
    let result = provider.catalog(for: nil)
    let builtInSchema = result?.schemas.first { $0.name == "Built-in" }
    #expect(builtInSchema != nil)
    #expect(builtInSchema?.objects.first?.name == "now")
}

// MARK: - SQL Server System Schemas

@Test
func sqlServerSystemSchemas() {
    let sysSchema = EchoSenseSchemaInfo(name: "sys", objects: [])
    let infoSchema = EchoSenseSchemaInfo(name: "information_schema", objects: [])
    let dboSchema = EchoSenseSchemaInfo(name: "dbo", objects: [])
    let database = EchoSenseDatabaseInfo(name: "testdb", schemas: [sysSchema, infoSchema, dboSchema])
    let structure = EchoSenseDatabaseStructure(databases: [database])
    let context = SQLEditorCompletionContext(databaseType: .microsoftSQL,
                                              selectedDatabase: "testdb",
                                              structure: structure)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: [],
                                      includeSystemSchemas: false)
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let schemaNames = dbCatalog?.schemas.map(\.name) ?? []
    #expect(!schemaNames.contains("sys"))
    #expect(!schemaNames.contains("information_schema"))
    #expect(schemaNames.contains("dbo"))
}

// MARK: - MySQL System Schemas

@Test
func mysqlSystemSchemas() {
    let mysqlSchema = EchoSenseSchemaInfo(name: "mysql", objects: [])
    let perfSchema = EchoSenseSchemaInfo(name: "performance_schema", objects: [])
    let appSchema = EchoSenseSchemaInfo(name: "app", objects: [])
    let database = EchoSenseDatabaseInfo(name: "testdb", schemas: [mysqlSchema, perfSchema, appSchema])
    let structure = EchoSenseDatabaseStructure(databases: [database])
    let context = SQLEditorCompletionContext(databaseType: .mysql,
                                              selectedDatabase: "testdb",
                                              structure: structure)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: [],
                                      includeSystemSchemas: false)
    let provider = catalog.metadataProvider
    let dbCatalog = provider.catalog(for: "testdb")

    let schemaNames = dbCatalog?.schemas.map(\.name) ?? []
    #expect(!schemaNames.contains("mysql"))
    #expect(!schemaNames.contains("performance_schema"))
    #expect(schemaNames.contains("app"))
}

// MARK: - Lookups without a database (indexed)

@Test
func findsObjectBySchemaAndNameWithoutADatabase() {
    let catalog = makeCatalog()
    let entry = catalog.object(database: nil, schema: "Public", name: "Orders")
    #expect(entry?.object.name == "orders")
    #expect(entry?.database == "testdb")
}

@Test
func findsObjectsByNameAlone() {
    let catalog = makeCatalog()
    #expect(catalog.objects(named: "ACTIVE_USERS").map(\.object.name) == ["active_users"])
    #expect(catalog.objects(named: "missing").isEmpty)
}

// MARK: - Built-in schema

@Test
func everyDatabaseGetsTheSameBuiltInSchema() {
    let usersTable = EchoSenseSchemaObjectInfo(name: "users", schema: "public", type: .table, columns: [])
    let schema = EchoSenseSchemaInfo(name: "public", objects: [usersTable])
    let structure = EchoSenseDatabaseStructure(databases: [
        EchoSenseDatabaseInfo(name: "one", schemas: [schema]),
        EchoSenseDatabaseInfo(name: "two", schemas: [schema]),
        EchoSenseDatabaseInfo(name: "three", schemas: [])
    ])
    let context = SQLEditorCompletionContext(databaseType: .postgresql, selectedDatabase: "one",
                                              defaultSchema: "public", structure: structure)
    let catalog = SQLMetadataCatalog(context: context, builtInFunctions: ["count", "sum"], includeSystemSchemas: false)

    for name in ["one", "two", "three"] {
        let schemas = catalog.metadataProvider.catalog(for: name)?.schemas ?? []
        let builtIn = schemas.first { $0.name == "Built-in" }
        #expect(builtIn?.objects.map(\.name) == ["count", "sum"], "\(name) has the built-in functions")
    }
}

// MARK: - The engine builds the catalog when asked

@Test
func engineUsesTheLatestContextAfterSeveralUpdates() {
    let engine = SQLAutoCompletionEngine()
    let old = SQLEditorCompletionContext(databaseType: .postgresql, selectedDatabase: "testdb",
                                          defaultSchema: "public", structure: makeStructure())
    engine.updateContext(old)
    engine.updateContext(nil)
    engine.updateContext(old)

    // Only the last context counts, and the catalog is made from it on first use.
    #expect(engine.context == old)
    let entry = engine.catalog?.object(database: "testdb", schema: "public", name: "orders")
    #expect(entry?.object.name == "orders")
    #expect(engine.isMetadataLimited == false)
}

@Test
func engineWithoutStructureIsLimitedAndHasNoObjects() {
    let engine = SQLAutoCompletionEngine()
    engine.updateContext(SQLEditorCompletionContext(databaseType: .postgresql, selectedDatabase: nil,
                                                     defaultSchema: nil, structure: nil))
    #expect(engine.isMetadataLimited)
    #expect(engine.catalog?.objectsByKey.isEmpty == true)

    engine.updateContext(nil)
    #expect(engine.catalog == nil)
    #expect(engine.isMetadataLimited == false)
}
