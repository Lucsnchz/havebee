import Foundation

/// Un valor JSON tipado y `Sendable` (en lugar de `[String: Any]`).
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Convierte lo que devuelve `JSONSerialization`.
    public init(any value: Any) {
        switch value {
        case let string as String: self = .string(string)
        case let number as NSNumber:
            // NSNumber también representa booleanos.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let array as [Any]: self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: object)
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    /// Lo que espera `JSONSerialization` para escribir.
    public var anyValue: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? NSNumber(value: Int64(n)) : NSNumber(value: n)
        case .bool(let b): b
        case .array(let a): a.map(\.anyValue)
        case .object(let o): o.mapValues(\.anyValue)
        case .null: NSNull()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringArray: [String]? {
        array?.compactMap(\.string)
    }

    public var stringDictionary: [String: String]? {
        object?.compactMapValues(\.string)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
