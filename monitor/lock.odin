package leita_monitor

/*
A run holds a lock on a file beside the settings store for as long as it runs,
so a run the scheduler starts while the last is still going, or one started by
hand beside it, sees it and stands aside rather than reading the disks twice at
once. The operating system holds the lock for the open file, so it goes with the
process however that ends; the file itself stays, empty, for the next to lock.
*/

// LOCK_FILE is the lock's name, beside settings.db.
LOCK_FILE :: "monitor.lock"

// Lock_Result is how taking the lock went.
Lock_Result :: enum u8 {
	Taken,
	Held, // another run holds it
	Failed, // the file could not be opened
}
