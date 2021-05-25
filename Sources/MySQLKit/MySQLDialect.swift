import enum Crypto.Insecure

public struct MySQLDialect: SQLDialect {
    public init() {}
    
    public var name: String {
        "mysql"
    }
    
    public var identifierQuote: SQLExpression {
        return SQLRaw("`")
    }
    
    public var literalStringQuote: SQLExpression {
        return SQLRaw("'")
    }
    
    public func bindPlaceholder(at position: Int) -> SQLExpression {
        return SQLRaw("?")
    }

    public func literalBoolean(_ value: Bool) -> SQLExpression {
        switch value {
        case false:
            return SQLRaw("0")
        case true:
            return SQLRaw("1")
        }
    }
    
    public var autoIncrementClause: SQLExpression {
        return SQLRaw("AUTO_INCREMENT")
    }

    public var supportsAutoIncrement: Bool {
        true
    }

    public var enumSyntax: SQLEnumSyntax {
        .inline
    }

    public func customDataType(for dataType: SQLDataType) -> SQLExpression? {
        switch dataType {
        case .text:
            return SQLRaw("TEXT")
        default:
            return nil
        }
    }

    public var alterTableSyntax: SQLAlterTableSyntax {
        .init(
            alterColumnDefinitionClause: SQLRaw("MODIFY COLUMN"),
            alterColumnDefinitionTypeKeyword: nil
        )
    }
    
    public func normalizeSQLConstraint(identifier: SQLExpression) -> SQLExpression {
        if let sqlIdentifier = identifier as? SQLIdentifier {
            let hashed = Insecure.SHA1.hash(data: Data(sqlIdentifier.string.utf8))
            let digest = hashed.reduce("") { $0 + String(format: "%02x", $1) }
            return SQLIdentifier(digest)
        } else {
            return identifier
        }
    }

    public var triggerSyntax: SQLTriggerSyntax {
        return .init(create: [.supportsBody, .conditionRequiresParentheses, .supportsOrder])
    }
}
