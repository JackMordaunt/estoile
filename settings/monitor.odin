package leita_settings

import "core:strings"

import "jm:sqlite3"

/*
What monitoring keeps (a paid feature): the places watched and how often each
is scanned, whether monitoring is on at all, and how each scan the monitor ran
went. The window and the command line share these through settings.db, so a
place added in one is watched by the other's next run.

Monitoring is off until the person turns it on: MONITOR unset reads as off, and
no place is watched until one is added.
*/

// MONITOR is the key of the off switch: ON while the system's scheduler runs
// the monitor, anything else or absent for off.
MONITOR :: "monitor"
ON      :: "on"
OFF     :: "off"

// Frequency is how often a watched place is scanned.
Frequency :: enum u8 {
	Hourly,
	Daily,
	Weekly,
}

// FREQUENCY_NAMES name each Frequency as the store and the command line write it.
FREQUENCY_NAMES := [Frequency]string {
	.Hourly = "hourly",
	.Daily  = "daily",
	.Weekly = "weekly",
}

// frequency_named is the Frequency name names, and whether there is one.
frequency_named :: proc(name: string) -> (Frequency, bool) {
	for n, e in FREQUENCY_NAMES {
		if strings.equal_fold(n, name) {
			return e, true
		}
	}
	return .Daily, false
}

// Watch is one place the monitor scans.
Watch :: struct {
	place: string, // as the person gave it
	every: Frequency,
	added: i64, // Unix seconds
}

// Run is one scan of a watched place the monitor ran: when it started, how
// long it took, what the place held and the disk it was on then, and why it
// failed, "" when it did not.
Run :: struct {
	id:         i64,
	place:      string,
	started:    i64, // Unix seconds
	seconds:    f64,
	bytes:      u64,
	disk_total: u64,
	disk_free:  u64,
	problem:    string,
}

// RUNS_KEPT is how many runs of each place are kept, newest first.
RUNS_KEPT :: 50

@(private)
MONITOR_SCHEMA :: `
	CREATE TABLE IF NOT EXISTS watch(
		place TEXT PRIMARY KEY,
		every TEXT NOT NULL,
		added INTEGER NOT NULL) WITHOUT ROWID;
	CREATE TABLE IF NOT EXISTS run(
		id INTEGER PRIMARY KEY,
		place TEXT NOT NULL,
		started INTEGER NOT NULL,
		seconds REAL NOT NULL,
		bytes INTEGER NOT NULL,
		disk_total INTEGER NOT NULL,
		disk_free INTEGER NOT NULL,
		problem TEXT NOT NULL);
	CREATE INDEX IF NOT EXISTS run_place ON run(place, started);`

// monitoring is whether the person turned monitoring on.
monitoring :: proc(st: ^Store) -> bool {
	v, _ := get(st, MONITOR, context.temp_allocator)
	return v == ON
}

// set_monitoring keeps whether monitoring is on.
set_monitoring :: proc(st: ^Store, on: bool) -> sqlite3.Error {
	return set(st, MONITOR, ON if on else OFF)
}

// watch keeps w, in place of any watch of the same place.
watch :: proc(st: ^Store, w: Watch) -> sqlite3.Error {
	return sqlite3.exec_args(
		st.db,
		`INSERT INTO watch(place, every, added) VALUES (?, ?, ?)
			ON CONFLICT(place) DO UPDATE SET every = excluded.every`,
		w.place,
		FREQUENCY_NAMES[w.every],
		w.added,
	)
}

// unwatch stops watching place and forgets its runs, and says whether it was
// watched.
unwatch :: proc(st: ^Store, place: string) -> (found: bool, err: sqlite3.Error) {
	sqlite3.exec_args(st.db, "DELETE FROM watch WHERE place = ?", place) or_return
	found = sqlite3.changes(st.db) > 0
	sqlite3.exec_args(st.db, "DELETE FROM run WHERE place = ?", place) or_return
	return
}

// watches is every place watched, in the order they were added, in allocator.
watches :: proc(st: ^Store, allocator := context.allocator) -> (out: []Watch, err: sqlite3.Error) {
	rows := sqlite3.query(
		st.db,
		"SELECT place, every, added FROM watch ORDER BY added, place",
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Watch, allocator)
	for sqlite3.next(&rows) {
		every, _ := frequency_named(sqlite3.text(rows, 1))
		append(
			&found,
			Watch {
				place = strings.clone(sqlite3.text(rows, 0), allocator),
				every = every,
				added = sqlite3.integer(rows, 2),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		watches_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// watches_destroy frees what watches returned.
watches_destroy :: proc(ws: []Watch, allocator := context.allocator) {
	for w in ws {
		delete(w.place, allocator)
	}
	delete(ws, allocator)
}

// record keeps r as the newest run of its place and forgets the oldest past
// RUNS_KEPT, and returns its id.
record :: proc(st: ^Store, r: Run) -> (id: i64, err: sqlite3.Error) {
	sqlite3.exec_args(
		st.db,
		`INSERT INTO run(place, started, seconds, bytes, disk_total, disk_free, problem)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
		r.place,
		r.started,
		r.seconds,
		i64(r.bytes),
		i64(r.disk_total),
		i64(r.disk_free),
		r.problem,
	) or_return
	id = sqlite3.last_id(st.db)
	sqlite3.exec_args(
		st.db,
		`DELETE FROM run WHERE place = ? AND id NOT IN
			(SELECT id FROM run WHERE place = ? ORDER BY started DESC, id DESC LIMIT ?)`,
		r.place,
		r.place,
		i64(RUNS_KEPT),
	) or_return
	return
}

// runs is the runs of place, newest first, at most limit, in allocator.
runs :: proc(
	st: ^Store,
	place: string,
	limit := RUNS_KEPT,
	allocator := context.allocator,
) -> (
	out: []Run,
	err: sqlite3.Error,
) {
	rows := sqlite3.query(
		st.db,
		`SELECT id, place, started, seconds, bytes, disk_total, disk_free, problem
			FROM run WHERE place = ? ORDER BY started DESC, id DESC LIMIT ?`,
		place,
		i64(limit),
		allocator = context.temp_allocator,
	) or_return
	found := make([dynamic]Run, allocator)
	for sqlite3.next(&rows) {
		append(
			&found,
			Run {
				id = sqlite3.integer(rows, 0),
				place = strings.clone(sqlite3.text(rows, 1), allocator),
				started = sqlite3.integer(rows, 2),
				seconds = sqlite3.real(rows, 3),
				bytes = u64(sqlite3.integer(rows, 4)),
				disk_total = u64(sqlite3.integer(rows, 5)),
				disk_free = u64(sqlite3.integer(rows, 6)),
				problem = strings.clone(sqlite3.text(rows, 7), allocator),
			},
		)
	}
	if err = sqlite3.finish(&rows); err != nil {
		runs_destroy(found[:], allocator)
		return nil, err
	}
	return found[:], nil
}

// runs_destroy frees what runs returned.
runs_destroy :: proc(rs: []Run, allocator := context.allocator) {
	for r in rs {
		delete(r.place, allocator)
		delete(r.problem, allocator)
	}
	delete(rs, allocator)
}

// last_run is the newest run of place, in allocator, and whether there is one.
last_run :: proc(st: ^Store, place: string, allocator := context.allocator) -> (Run, bool) {
	rs, err := runs(st, place, 1, context.temp_allocator)
	if err != nil || len(rs) == 0 {
		return {}, false
	}
	r := rs[0]
	r.place = strings.clone(r.place, allocator)
	r.problem = strings.clone(r.problem, allocator)
	return r, true
}
