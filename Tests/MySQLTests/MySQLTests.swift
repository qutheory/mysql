import XCTest
@testable import MySQL
import JSON
import Core
import Dispatch

#if os(Linux)
    #if MARIADB
        import CMariaDBLinux
    #else
        import CMySQLLinux
    #endif
#else
    import CMySQLMac
#endif


class MySQLTests: XCTestCase {
    static let allTests = [
        ("testSelectVersion", testSelectVersion),
        ("testTables", testTables),
        ("testParameterization", testParameterization),
    ]

    var mysql: MySQL.Database!

    override func setUp() {
        mysql = MySQL.Database.makeTestConnection()
    }

    func testSelectVersion() {
        do {
            let results = try mysql.execute("SELECT @@version, @@version, 1337, 3.14, 'what up', NULL")

            guard let version = results.first?["@@version"] else {
                XCTFail("Version not in results")
                return
            }
            #if MARIADB
            XCTAssert(version.string?.characters.first == "1")
            #else
            XCTAssert(version.string?.characters.first == "5")
            #endif
        } catch {
            XCTFail("Could not select version: \(error)")
        }
    }

    func testTables() {
        do {
            try mysql.execute("DROP TABLE IF EXISTS foo")
            try mysql.execute("CREATE TABLE foo (bar INT(4), baz VARCHAR(16))")
            try mysql.execute("INSERT INTO foo VALUES (42, 'Life')")
            try mysql.execute("INSERT INTO foo VALUES (1337, 'Elite')")
            try mysql.execute("INSERT INTO foo VALUES (9, NULL)")

            if let resultBar = try mysql.execute("SELECT * FROM foo WHERE bar = 42").first {
                XCTAssertEqual(resultBar["bar"]?.int, 42)
                XCTAssertEqual(resultBar["baz"]?.string, "Life")
            } else {
                XCTFail("Could not get bar result")
            }

            if let resultBaz = try mysql.execute("SELECT * FROM foo where baz = 'elite'").first {
                XCTAssertEqual(resultBaz["bar"]?.int, 1337)
                XCTAssertEqual(resultBaz["baz"]?.string, "Elite")
            } else {
                XCTFail("Could not get baz result")
            }

            if let resultBaz = try mysql.execute("SELECT * FROM foo where bar = 9").first {
                XCTAssertEqual(resultBaz["bar"]?.int, 9)
                XCTAssertEqual(resultBaz["baz"]?.string, nil)
            } else {
                XCTFail("Could not get null result")
            }
        } catch {
            XCTFail("Testing tables failed: \(error)")
        }
    }

    func testParameterization() {
        do {
            try mysql.execute("DROP TABLE IF EXISTS parameterization")
            try mysql.execute("CREATE TABLE parameterization (d DOUBLE, i INT, s VARCHAR(16), u INT UNSIGNED)")

            try mysql.execute("INSERT INTO parameterization VALUES (3.14, NULL, 'pi', NULL)")
            try mysql.execute("INSERT INTO parameterization VALUES (NULL, NULL, 'life', 42)")
            try mysql.execute("INSERT INTO parameterization VALUES (NULL, -1, 'test', NULL)")
            try mysql.execute("INSERT INTO parameterization VALUES (NULL, -1, 'test', NULL)")

            if let result = try mysql.execute("SELECT * FROM parameterization WHERE d = ?", ["3.14"]).first {
                XCTAssertEqual(result["d"]?.double, 3.14)
                XCTAssertEqual(result["i"]?.int, nil)
                XCTAssertEqual(result["s"]?.string, "pi")
                XCTAssertEqual(result["u"]?.int, nil)
            } else {
                XCTFail("Could not get pi result")
            }

            if let result = try mysql.execute("SELECT * FROM parameterization WHERE u = ?", [Node.number(.uint(42))]).first {
                XCTAssertEqual(result["d"]?.double, nil)
                XCTAssertEqual(result["i"]?.int, nil)
                XCTAssertEqual(result["s"]?.string, "life")
                XCTAssertEqual(result["u"]?.int, 42)
            } else {
                XCTFail("Could not get life result")
            }

            if let result = try mysql.execute("SELECT * FROM parameterization WHERE i = ?", [-1]).first {
                XCTAssertEqual(result["d"]?.double, nil)
                XCTAssertEqual(result["i"]?.int, -1)
                XCTAssertEqual(result["s"]?.string, "test")
                XCTAssertEqual(result["u"]?.int, nil)
            } else {
                XCTFail("Could not get test by int result")
            }

            if let result = try mysql.execute("SELECT * FROM parameterization WHERE s = ?", ["test"]).first {
                XCTAssertEqual(result["d"]?.double, nil)
                XCTAssertEqual(result["i"]?.int, -1)
                XCTAssertEqual(result["s"]?.string, "test")
                XCTAssertEqual(result["u"]?.int, nil)
            } else {
                XCTFail("Could not get test by string result")
            }
        } catch {
            XCTFail("Testing tables failed: \(error)")
        }
    }

    #if !NOJSON
    func testJSON() {
        do {
            try mysql.execute("DROP TABLE IF EXISTS json")
            try mysql.execute("CREATE TABLE json (i INT, b VARCHAR(64), j JSON)")

            let json = try JSON(node: [
                "string": "hello, world",
                "int": 42
            ])
            let bytes = try json.makeBytes()

            try mysql.execute("INSERT INTO json VALUES (?, ?, ?)", [
                1,
                Node.bytes(bytes),
                json
            ])

            if let result = try mysql.execute("SELECT * FROM json").first {
                XCTAssertEqual(result["i"]?.int, 1)
                XCTAssertEqual(result["b"]?.string, try String(bytes: bytes))
                XCTAssertEqual(result["j"]?.object?["string"]?.string, "hello, world")
                XCTAssertEqual(result["j"]?.object?["int"]?.int, 42)
            } else {
                XCTFail("No results")
            }
        } catch {
            XCTFail("Testing tables failed: \(error)")
        }
    }
    #endif

    func testTimestamps() {
        do {

            try mysql.execute("DROP TABLE IF EXISTS times")
            try mysql.execute("CREATE TABLE times (i INT, d DATE, t TIME, ts TIMESTAMP)")


            try mysql.execute("INSERT INTO times VALUES (?, ?, ?, ?)", [
                1.0,
                "2050-05-12",
                "13:42",
                "2016-05-05 05:05:05"
            ])


            if let result = try mysql.execute("SELECT i FROM times").first {
                XCTAssertEqual(result["i"]?.int, 1)
            } else {
                XCTFail("No results")
            }
        } catch {
            XCTFail("Testing tables failed: \(error)")
        }
    }

    func testSpam() {
        do {
            let c = try mysql.makeConnection()
            
            try c.execute("DROP TABLE IF EXISTS spam")
            try c.execute("CREATE TABLE spam (s VARCHAR(64), time TIME)")
            
            for _ in 0..<10_000 {
                try c.execute("INSERT INTO spam VALUES (?, ?)", ["hello", "13:42"])
            }
            
            let cn = try mysql.makeConnection()
            let result = try cn.execute("SELECT count(1) as total FROM spam")
            XCTAssertEqual(result.first?["total"]?.int, 10000)
        } catch {
            XCTFail("Testing multiple failed: \(error)")
        }
    }

    func testSpamConnectionPoolSequential() {
        do {
            try mysql.execute("DROP TABLE IF EXISTS spam_sequential")
            try mysql.execute("CREATE TABLE spam_sequential (s VARCHAR(64), time TIME)")

            for _ in 0..<10_000 {
                try mysql.execute("INSERT INTO spam_sequential VALUES (?, ?)", ["hello", "13:42"])
            }

            let result = try mysql.execute("SELECT count(1) as total FROM spam_sequential")
            XCTAssertEqual(result.first?["total"]?.int, 10000)
        } catch {
            XCTFail("Testing multiple failed: \(error)")
        }
    }

    func testSpamConnectionPoolParallel() {
        do {
            try mysql.execute("DROP TABLE IF EXISTS spam_parallel")
            try mysql.execute("CREATE TABLE spam_parallel (s VARCHAR(64), time TIME)")

            let threads = 100
            let group = DispatchGroup()
            for _ in 0..<threads {
                group.enter()
                DispatchQueue(label: "spam").async {
                    do {
                        for _ in 0..<(10_000/threads) {
                            try self.mysql.execute("INSERT INTO spam_parallel VALUES (?, ?)", ["hello", "13:42"])
                        }
                    } catch {
                        // failed to insert some
                    }
                    group.leave()
                }
            }
            group.wait()

            let result = try mysql.execute("SELECT count(1) as total FROM spam_parallel")
            XCTAssertEqual(result.first?["total"]?.int, 10000)
        } catch {
            XCTFail("Testing multiple failed: \(error)")
        }
    }

    func testError() {
        do {
            try mysql.execute("error")
            XCTFail("Should have errored.")
        } catch MySQL.Error.prepare(_) {
            
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    /// Test for "server gone" errors (typically produced when a connection is lost to the server
    /// due to inactivity or other reasons)
    /// This tests, closes all the connections in the pool and replaces them with new ones. Thus, 
    /// this test will never face the "server gone" error (2006) but instead receive the 
    /// error "commands out of sync" (2014).
    /// To test for 2006, temporary comment the "mysql_init" line below. This will trigger the error,
    /// however the Connection class will fail on dealloc when trying to close the already closed 
    /// connection.
    func testServerGone() {
        do {
            let result1 = try mysql.execute("SELECT 1 as one")
            XCTAssertEqual(result1.first?["one"]?.int, 1)
            // Forcibly terminate all the connections
            for connection in mysql.connectionPool {
                mysql_close(connection.cConnection)
                connection.cConnection = mysql_init(nil)
            }
            let result2 = try mysql.execute("SELECT 2 as two")
            XCTAssertEqual(result2.first?["two"]?.int, 2)
        } catch {
            XCTFail()
        }
    }
}
