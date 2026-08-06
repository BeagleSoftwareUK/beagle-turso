require "./beagle_turso_wrap"
db = Beagle::Turso::Database.open_local(":memory:")
conn = db.connect
conn.execute("CREATE TABLE t (id INTEGER, name TEXT)", [])
conn.execute("INSERT INTO t (id, name) VALUES (?, ?)", [1, "alice"])
rows = conn.query("SELECT id, name FROM t", [])
puts "rows=#{rows.inspect}"
raise "FAIL: #{rows.inspect}" unless rows == [[1, "alice"]]
puts "P2B_OK: persistent Database+Connection wrapped, round-trip works"
