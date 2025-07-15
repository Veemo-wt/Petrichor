//
// DatabaseMigration.swift
//
// This file contains the database migration infrastructure for Petrichor
// using GRDB's built-in migration system.
//

import Foundation
import GRDB

/// Manages database migrations using GRDB's built-in migration system
struct DatabaseMigrator {
    /// Creates and configures the database migrator with all migrations
    static func setupMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()
        
        // MARK: - Initial Schema Migration
        migrator.registerMigration("v1_initial_schema") { db in
            // Check if this is a fresh database by looking for core tables
            let tracksExist = try db.tableExists("tracks")
            let foldersExist = try db.tableExists("folders")
            let artistsExist = try db.tableExists("artists")
            
            let tablesExist = tracksExist || foldersExist || artistsExist
            
            if !tablesExist {
                // Fresh database - create initial schema using static setup methods
                try DatabaseManager.setupDatabaseSchema(in: db)
            } else {
                // Existing database - this is our baseline
                Logger.info("Existing database detected, marking as v1 baseline")
            }
        }
        
        migrator.registerMigration("v2_add_folder_content_hash") { db in
            try db.alter(table: "folders") { t in
                t.add(column: "shasum_hash", .text)
            }
            Logger.info("Added shasum_hash column to folders table")
        }
        
        // MARK: - Future Migrations
        // Add new migrations here as: migrator.registerMigration("v2_description") { db in ... }
        
        return migrator
    }
    
    /// Apply all pending migrations to the database
    static func migrate(_ dbQueue: DatabaseQueue) throws {
        let migrator = setupMigrator()
        try migrator.migrate(dbQueue)
        
        Logger.info("Database migrations completed")
    }
    
    /// Check if there are unapplied migrations
    static func hasUnappliedMigrations(_ dbQueue: DatabaseQueue) -> Bool {
        do {
            let migrator = setupMigrator()
            return try dbQueue.read { db in
                try migrator.hasBeenSuperseded(db)
            }
        } catch {
            Logger.error("Failed to check migration status: \(error)")
            return false
        }
    }
    
    /// Get list of applied migrations
    static func appliedMigrations(_ dbQueue: DatabaseQueue) -> [String] {
        // Return empty array for now - can be implemented if needed
        []
    }
}

// MARK: - Migration Helpers

extension Database {
    /// Helper to safely add a column if it doesn't exist
    func addColumnIfNotExists(
        table: String,
        column: String,
        type: Database.ColumnType,
        defaultValue: DatabaseValueConvertible? = nil,
        notNull: Bool = false
    ) throws {
        let columns = try self.columns(in: table)
        let columnExists = columns.contains { $0.name == column }
        
        if !columnExists {
            try self.alter(table: table) { t in
                var columnDef = t.add(column: column, type)
                if let defaultValue = defaultValue {
                    columnDef = columnDef.defaults(to: defaultValue)
                }
                if notNull {
                    columnDef = columnDef.notNull()
                }
            }
        }
    }
    
    /// Helper to drop a column if it exists
    func dropColumnIfExists(table: String, column: String) throws {
        let columns = try self.columns(in: table)
        let columnExists = columns.contains { $0.name == column }
        
        if columnExists {
            try self.alter(table: table) { t in
                t.drop(column: column)
            }
        }
    }
    
    /// Helper to create an index if it doesn't exist
    func createIndexIfNotExists(
        name: String,
        table: String,
        columns: [String],
        unique: Bool = false
    ) throws {
        let indexExists = try self.indexes(on: table).contains { $0.name == name }
        
        if !indexExists {
            try self.create(
                index: name,
                on: table,
                columns: columns,
                unique: unique,
                ifNotExists: true
            )
        }
    }
    
    /// Helper to drop an index if it exists
    func dropIndexIfExists(_ name: String) throws {
        // Note: We need to find which table the index belongs to
        // For now, we'll try to drop it and ignore errors if it doesn't exist
        do {
            try self.drop(index: name)
        } catch {
            // Index might not exist, which is fine
        }
    }
    
    /// Helper to rename a table if it exists
    func renameTableIfExists(from oldName: String, to newName: String) throws {
        if try self.tableExists(oldName) && !self.tableExists(newName) {
            try self.rename(table: oldName, to: newName)
        }
    }
    
    /// Helper to create a table only if it doesn't exist
    func createTableIfNotExists(
        _ name: String,
        body: (TableDefinition) throws -> Void
    ) throws {
        try self.create(table: name, ifNotExists: true, body: body)
    }
    
    /// Helper to drop a table if it exists
    func dropTableIfExists(_ name: String) throws {
        if try self.tableExists(name) {
            try self.drop(table: name)
        }
    }
    
    /// Helper to rename a column if it exists
    func renameColumnIfExists(
        table: String,
        from oldName: String,
        to newName: String
    ) throws {
        let columns = try self.columns(in: table)
        let oldExists = columns.contains { $0.name == oldName }
        let newExists = columns.contains { $0.name == newName }
        
        if oldExists && !newExists {
            try self.alter(table: table) { t in
                t.rename(column: oldName, to: newName)
            }
        }
    }
}
