import Foundation

/// Encodes an `Encodable` value straight into a `JSONValue`, with the result `JSONEncoder` plus
/// `JSONValue.parse` give (`JSONValue(encoding:)`): numbers as doubles, non-finite doubles as
/// "NaN", "Infinity" and "-Infinity", `nil` properties left out, a nested value that encodes
/// nothing as an empty object. Without writing and reading JSON text: storing a Schreiben session
/// of 540 cards that way took 5.7 ms per answer (measured 26.11.2026).
///
/// What `JSONEncoder` writes in a way of its own (`Data`, `URL`, `Decimal`) and any misuse of the
/// containers make `encode` throw; `JSONValue(encoding:)` then takes the text round trip. Coding
/// paths are not kept (only error messages read them, and an error takes the text round trip).
enum JSONValueEncoder {
    struct Unsupported: Error {}

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let context = Context()
        let slot = try slot(for: value, codingPath: [], context: context)
        guard !context.isInvalid else { throw Unsupported() }
        if case let .node(node) = slot, node.isEmpty {
            // `JSONEncoder` throws for a top-level value that encodes nothing.
            throw Unsupported()
        }
        return slot.resolved
    }

    // MARK: Values

    /// A value already turned into JSON, or a container still being filled.
    enum Slot {
        case value(JSONValue)
        case node(Node)

        var resolved: JSONValue {
            switch self {
            case let .value(value): value
            case let .node(node): node.resolved
            }
        }
    }

    /// What one encoder (or nested container) wrote: a single value, an object or an array.
    final class Node {
        var single: JSONValue?
        var object: [String: Slot]?
        var array: [Slot]?

        var isEmpty: Bool { single == nil && object == nil && array == nil }

        var resolved: JSONValue {
            if let object { return .object(object.mapValues(\.resolved)) }
            if let array { return .array(array.map(\.resolved)) }
            return single ?? .object([:])
        }
    }

    final class Context {
        var isInvalid = false
    }

    static func slot<T: Encodable>(for value: T, codingPath: [any CodingKey], context: Context) throws -> Slot {
        if let scalar = scalar(value) { return .value(scalar) }
        if value is Data || value is URL || value is Decimal { throw Unsupported() }
        let node = Node()
        try value.encode(to: DirectEncoder(node: node, codingPath: codingPath, context: context))
        return .node(node)
    }

    /// The JSON of a value `JSONEncoder` writes as a plain number, string or boolean. By the static
    /// type (no dynamic casts: this runs for every value of a session).
    static func scalar<T>(_ value: T) -> JSONValue? {
        if T.self == String.self { return .string(unsafeBitCast(value, to: String.self)) }
        if T.self == Int.self { return .number(Double(unsafeBitCast(value, to: Int.self))) }
        if T.self == Double.self { return double(unsafeBitCast(value, to: Double.self)) }
        if T.self == Bool.self { return .bool(unsafeBitCast(value, to: Bool.self)) }
        if T.self == Float.self { return float(unsafeBitCast(value, to: Float.self)) }
        if T.self == Int64.self { return .number(Double(unsafeBitCast(value, to: Int64.self))) }
        if T.self == Int32.self { return .number(Double(unsafeBitCast(value, to: Int32.self))) }
        if T.self == Int16.self { return .number(Double(unsafeBitCast(value, to: Int16.self))) }
        if T.self == Int8.self { return .number(Double(unsafeBitCast(value, to: Int8.self))) }
        if T.self == UInt.self { return .number(Double(unsafeBitCast(value, to: UInt.self))) }
        if T.self == UInt64.self { return .number(Double(unsafeBitCast(value, to: UInt64.self))) }
        if T.self == UInt32.self { return .number(Double(unsafeBitCast(value, to: UInt32.self))) }
        if T.self == UInt16.self { return .number(Double(unsafeBitCast(value, to: UInt16.self))) }
        if T.self == UInt8.self { return .number(Double(unsafeBitCast(value, to: UInt8.self))) }
        return nil
    }

    /// `JSONValue(encoding:)` writes non-finite doubles as strings.
    static func double(_ value: Double) -> JSONValue {
        if value.isNaN { return .string("NaN") }
        if value.isInfinite { return .string(value > 0 ? "Infinity" : "-Infinity") }
        return .number(value)
    }

    /// `JSONEncoder` writes a float in its own shortest form ("0.1"), which reads back as that
    /// double, not as the float's exact value.
    static func float(_ value: Float) -> JSONValue {
        if value.isNaN { return .string("NaN") }
        if value.isInfinite { return .string(value > 0 ? "Infinity" : "-Infinity") }
        return .number(Double(value.description) ?? Double(value))
    }

    // MARK: Encoder

    struct DirectEncoder: Encoder {
        let node: Node
        let codingPath: [any CodingKey]
        let context: Context
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            if node.object == nil {
                if node.single != nil || node.array != nil { context.isInvalid = true }
                node.object = [:]
            }
            return KeyedEncodingContainer(KeyedContainer<Key>(node: node, codingPath: codingPath, context: context))
        }

        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            if node.array == nil {
                if node.single != nil || node.object != nil { context.isInvalid = true }
                node.array = []
            }
            return UnkeyedContainer(node: node, codingPath: codingPath, context: context)
        }

        func singleValueContainer() -> any SingleValueEncodingContainer {
            if node.object != nil || node.array != nil { context.isInvalid = true }
            return SingleContainer(node: node, codingPath: codingPath, context: context)
        }
    }

    struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let node: Node
        let codingPath: [any CodingKey]
        let context: Context

        private func set(_ slot: Slot, _ key: Key) { node.object?[key.stringValue] = slot }

        mutating func encodeNil(forKey key: Key) throws { set(.value(.null), key) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { set(.value(.bool(value)), key) }
        mutating func encode(_ value: String, forKey key: Key) throws { set(.value(.string(value)), key) }
        mutating func encode(_ value: Double, forKey key: Key) throws { set(.value(double(value)), key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { set(.value(float(value)), key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { set(.value(.number(Double(value))), key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { set(.value(.number(Double(value))), key) }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            set(try slot(for: value, codingPath: [], context: context), key)
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key)
            -> KeyedEncodingContainer<NestedKey>
        {
            let child = Node()
            child.object = [:]
            set(.node(child), key)
            return KeyedEncodingContainer(
                KeyedContainer<NestedKey>(node: child, codingPath: [], context: context))
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            let child = Node()
            child.array = []
            set(.node(child), key)
            return UnkeyedContainer(node: child, codingPath: [], context: context)
        }

        mutating func superEncoder() -> any Encoder {
            let child = Node()
            node.object?["super"] = .node(child)
            return DirectEncoder(node: child, codingPath: [], context: context)
        }

        mutating func superEncoder(forKey key: Key) -> any Encoder {
            let child = Node()
            set(.node(child), key)
            return DirectEncoder(node: child, codingPath: [], context: context)
        }
    }

    struct UnkeyedContainer: UnkeyedEncodingContainer {
        let node: Node
        let codingPath: [any CodingKey]
        let context: Context

        var count: Int { node.array?.count ?? 0 }
        private func append(_ slot: Slot) { node.array?.append(slot) }

        mutating func encodeNil() throws { append(.value(.null)) }
        mutating func encode(_ value: Bool) throws { append(.value(.bool(value))) }
        mutating func encode(_ value: String) throws { append(.value(.string(value))) }
        mutating func encode(_ value: Double) throws { append(.value(double(value))) }
        mutating func encode(_ value: Float) throws { append(.value(float(value))) }
        mutating func encode(_ value: Int) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: Int8) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: Int16) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: Int32) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: Int64) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: UInt) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: UInt8) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: UInt16) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: UInt32) throws { append(.value(.number(Double(value)))) }
        mutating func encode(_ value: UInt64) throws { append(.value(.number(Double(value)))) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            append(try slot(for: value, codingPath: [], context: context))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type)
            -> KeyedEncodingContainer<NestedKey>
        {
            let child = Node()
            child.object = [:]
            append(.node(child))
            return KeyedEncodingContainer(KeyedContainer<NestedKey>(node: child, codingPath: [], context: context))
        }

        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            let child = Node()
            child.array = []
            append(.node(child))
            return UnkeyedContainer(node: child, codingPath: [], context: context)
        }

        mutating func superEncoder() -> any Encoder {
            let child = Node()
            append(.node(child))
            return DirectEncoder(node: child, codingPath: [], context: context)
        }
    }

    struct SingleContainer: SingleValueEncodingContainer {
        let node: Node
        let codingPath: [any CodingKey]
        let context: Context

        private func set(_ value: JSONValue) {
            if node.single != nil { context.isInvalid = true }
            node.single = value
        }

        mutating func encodeNil() throws { set(.null) }
        mutating func encode(_ value: Bool) throws { set(.bool(value)) }
        mutating func encode(_ value: String) throws { set(.string(value)) }
        mutating func encode(_ value: Double) throws { set(double(value)) }
        mutating func encode(_ value: Float) throws { set(float(value)) }
        mutating func encode(_ value: Int) throws { set(.number(Double(value))) }
        mutating func encode(_ value: Int8) throws { set(.number(Double(value))) }
        mutating func encode(_ value: Int16) throws { set(.number(Double(value))) }
        mutating func encode(_ value: Int32) throws { set(.number(Double(value))) }
        mutating func encode(_ value: Int64) throws { set(.number(Double(value))) }
        mutating func encode(_ value: UInt) throws { set(.number(Double(value))) }
        mutating func encode(_ value: UInt8) throws { set(.number(Double(value))) }
        mutating func encode(_ value: UInt16) throws { set(.number(Double(value))) }
        mutating func encode(_ value: UInt32) throws { set(.number(Double(value))) }
        mutating func encode(_ value: UInt64) throws { set(.number(Double(value))) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            switch try slot(for: value, codingPath: codingPath, context: context) {
            case let .value(json):
                set(json)
            case let .node(child):
                // The value wrote into an encoder of its own: it takes this one's place.
                if node.single != nil || node.object != nil || node.array != nil { context.isInvalid = true }
                node.single = child.single
                node.object = child.object
                node.array = child.array
            }
        }
    }
}
