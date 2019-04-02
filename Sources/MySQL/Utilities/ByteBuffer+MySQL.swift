import Bits
import Debugging
import Foundation

/// MARK: Assert

extension ByteBuffer {
    mutating func requireInteger<T>(endianness: Endianness = .big, as type: T.Type = T.self) throws -> T
        where T: FixedWidthInteger
    {
        guard let int = readInteger(endianness: endianness, as: T.self) else {
            throw MySQLError(identifier: "integer", reason: "Could not parse \(T.self).")
        }
        return int
    }

    mutating func requireFloatingPoint<T>(as type: T.Type = T.self) throws -> T
        where T: BinaryFloatingPoint
    {
        guard let float = readFloatingPoint(as: T.self) else {
            throw MySQLError(identifier: "floatingPoint", reason: "Could not parse \(T.self).")
        }
        return float
    }

    mutating func requireNullTerminatedString() throws -> String {
        guard let string = readNullTerminatedString() else {
            throw MySQLError(identifier: "nullTerminatedString", reason: "Could not parse null terminated string.")
        }
        return string
    }

    mutating func requireString(length: Int) throws -> String {
        guard let string = readString(length: length) else {
            throw MySQLError(identifier: "string", reason: "Could not parse \(length) character string.")
        }
        return string
    }

    mutating func requireBytes(length: Int) throws -> [UInt8] {
        guard let bytes = readBytes(length: length) else {
            throw MySQLError(identifier: "bytes", reason: "Could not parse \(length) bytes.")
        }
        return bytes
    }

    mutating func requireLengthEncodedInteger() throws -> UInt64 {
        guard let int = readLengthEncodedInteger() else {
            throw MySQLError(identifier: "lengthEncodedInt", reason: "Could not parse length encoded integer.")
        }
        return int
    }

    mutating func requireLengthEncodedString() throws -> String {
        guard let string = readLengthEncodedString() else {
            throw MySQLError(identifier: "lengthEncodedString", reason: "Could not parse length encoded string.")
        }
        return string
    }

    mutating func requireLengthEncodedData() throws -> Data {
        guard let data = readLengthEncodedData() else {
            throw MySQLError(identifier: "lengthEncodedData", reason: "Could not parse length encoded data.")
        }
        return data
    }
}

/// MARK: Null-terminated string

extension ByteBuffer {
    mutating func write(nullTerminated string: String) {
        self.write(string: string)
        self.write(integer: Byte(0))
    }
}

/// MARK: Length Encoded Int

extension ByteBuffer {
    /// Returns packet length if there are enough readable bytes.
    mutating func checkPacketLength() throws -> Int32? {
        guard var length = peekInteger(endianness: .little, as: Int32.self) else {
            return nil
        }
        // erase sequence id
        length = length & 0x00FFFFFF
        if readableBytes >= length + 4 /* must be enough bytes to read length too */ {
            moveReaderIndex(forwardBy: 4)
            return length
        } else {
            return nil
        }
    }
    
    func peekInteger<T>(endianness: Endianness = .big, as type: T.Type = T.self, skipping: Int = 0) -> T? where T: FixedWidthInteger {
        guard readableBytes >= MemoryLayout<T>.size + skipping else {
            return nil
        }
        return getInteger(at: readerIndex + skipping, endianness: endianness)
    }

    mutating func readLengthEncodedString() -> String? {
        guard let size = readLengthEncodedInteger() else {
            return nil
        }

        if size == 0 {
            return ""
        }

        return readString(length: Int(size))
    }

    mutating func readLengthEncodedData() -> Data? {
        guard let size = readLengthEncodedInteger() else {
            return nil
        }

        if size == 0 {
            return .init()
        }

        return readData(length: Int(size))
    }

    mutating func readLengthEncodedInteger() -> UInt64? {
        guard let first: Byte = peekInteger() else {
            return nil
        }

        switch first {
        case 0xFC:
            guard let _ = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            guard let uint16 = readInteger(endianness: .little, as: UInt16.self) else {
                return nil
            }
            return numericCast(uint16)
        case 0xFD:
            guard let _ = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            guard let one = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            guard let two = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            guard let three = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            var num: UInt64 = 0
            num += numericCast(one)   << 0
            num += numericCast(two)   << 8
            num += numericCast(three) << 16
            return num
        case 0xFE:
            guard let _ = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            guard let uint64 = readInteger(endianness: .little, as: UInt64.self) else {
                return nil
            }
            return uint64
        default:
            guard let byte = readInteger(endianness: .little, as: UInt8.self) else {
                return nil
            }
            return numericCast(byte)
        }
    }

    mutating func write(lengthEncoded int: UInt64) {
        switch int {
        case 0..<251:
            /// If the value is < 251, it is stored as a 1-byte integer.
            write(integer: Byte(int))
        case 251..<65_536:
            /// If the value is ≥ 251 and < (216), it is stored as fc + 2-byte integer.
            write(integer: Byte(0xFC))
            write(integer: UInt16(int), endianness: .little)
        case 65_536..<16_777_216:
            /// If the value is ≥ (216) and < (224), it is stored as fd + 3-byte integer.
            write(integer: Byte(0xFD))
            write(integer: Byte((int >> 0) & 0xFF))
            write(integer: Byte((int >> 8) & 0xFF))
            write(integer: Byte((int >> 16) & 0xFF))
        case 16_777_216..<UInt64.max:
            /// If the value is ≥ (224) and < (264) it is stored as fe + 8-byte integer.
            write(integer: Byte(0xFE), endianness: .little)
            write(integer: int)
        default: fatalError() // will never hit
        }
    }
}

/// MARK: Floating point

extension ByteBuffer {

    /// Read an integer off this `ByteBuffer`, move the reader index forward by the floating point's byte size and return the result.
    ///
    /// - parameters:
    ///     - as: the desired `BinaryFloatingPoint` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if there aren't enough bytes readable.
    mutating func readFloatingPoint<T>(as: T.Type = T.self) -> T?
        where T: BinaryFloatingPoint
    {
        guard self.readableBytes >= MemoryLayout<T>.size else {
            return nil
        }

        let value: T = self.getFloatingPoint(at: self.readerIndex)! /* must work as we have enough bytes */
        self.moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return value
    }

    /// Get the floating point at `index` from this `ByteBuffer`. Does not move the reader index.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes for the floating point into the `ByteBuffer`.
    ///     - as: the desired `BinaryFloatingPoint` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if the bytes of interest aren't contained in the `ByteBuffer`.
    func getFloatingPoint<T>(at index: Int, as: T.Type = T.self) -> T?
        where T: BinaryFloatingPoint
    {
        precondition(index >= 0, "index must not be negative")
        return self.withVeryUnsafeBytes { ptr in
            guard index <= ptr.count - MemoryLayout<T>.size else {
                return nil
            }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { valuePtr in
                valuePtr.copyMemory(from: UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: index),
                                                                 count: MemoryLayout<T>.size))
            }
            return value
        }
    }

    /// Write `integer` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - endianness: The endianness to use, defaults to big endian.
    /// - returns: The number of bytes written.
    @discardableResult
    mutating func write<T>(floatingPoint: T) -> Int where T: BinaryFloatingPoint {
        let bytesWritten = self.set(floatingPoint: floatingPoint, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: bytesWritten)
        return Int(bytesWritten)
    }

    /// Write `integer` into this `ByteBuffer` starting at `index`. This does not alter the writer index.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - index: The index of the first byte to write.
    ///     - endianness: The endianness to use, defaults to big endian.
    /// - returns: The number of bytes written.
    @discardableResult
    mutating func set<T>(floatingPoint: T, at index: Int) -> Int where T: BinaryFloatingPoint {
        var value = floatingPoint
        return Swift.withUnsafeBytes(of: &value) { ptr in
            self.set(bytes: ptr, at: index)
        }
    }
}
