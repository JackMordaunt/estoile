/*
Package licence reads the Key the licence speaks of: a licence Librium signs
and the buyer pastes into leita, or opens as a file. leita checks it here,
offline, against the public key it was built with, and never asks anyone else:
nothing about the buyer or the machine leaves it.

A licence is one line of text:

	leita1.<payload>.<signature>

payload is the licence's terms as JSON in standard base64, and signature the
Ed25519 signature, in standard base64, of everything before the second dot. The
server that sells leita mints them; this package only checks them.

	{"licensee": "Acme Ltd", "tier": "office", "order": "…", "issued": "2026-10-11"}

A licence does not expire. The one in use is kept as a file of its own in
leita's data folder, beside the history store.
*/
package leita_licence

import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// PREFIX begins every licence of this format, and names the format's version.
PREFIX :: "leita1."

// KEY is the public key licences are checked against, in hex, set with
// -define:LEITA_LICENCE_KEY=<hex>. A build without one takes no licence.
KEY :: #config(LEITA_LICENCE_KEY, "")

// Tier is what a licence was bought for, as the price list sells them.
Tier :: enum u8 {
	Supporter, // an individual's, for the paid features at home
	Office, // an organisation of up to 10 people, one site
	Team, // up to 50 people, one site
	Site, // anyone at one site
	Multi_Site, // anyone at any of its sites
}

// TIER_NAMES are the tiers as a licence's payload names them.
TIER_NAMES := [Tier]string {
	.Supporter  = "supporter",
	.Office     = "office",
	.Team       = "team",
	.Site       = "site",
	.Multi_Site = "multi_site",
}

// Licence is a licence's terms, once its signature is checked. Its strings are
// owned; destroy frees them.
Licence :: struct {
	licensee: string, // who it was sold to, person or organisation
	tier:     Tier,
	order:    string, // the order it was sold in, as the seller numbers them
	issued:   string, // the day it was signed, YYYY-MM-DD
}

Error :: enum u8 {
	None,
	No_Key, // this build was made without a key to check licences with
	Malformed, // not a licence: not three parts, or not base64
	Version, // a licence, but of a format this leita does not read
	Signature, // not signed by Librium, or changed since
	Terms, // signed, but its terms do not say what this leita needs
	Unreadable, // the file could not be read
	Unwritable, // the file could not be written
}

// public_key is KEY, decoded; false when the build has none or it is not a key.
public_key :: proc() -> (key: [ed25519.PUBLIC_KEY_SIZE]byte, ok: bool) {
	b := hex.decode(transmute([]byte)string(KEY), context.temp_allocator) or_return
	if len(b) != len(key) {
		return
	}
	copy(key[:], b)
	return key, true
}

/*
check reads pasted as a licence and checks it was signed with key, returning
its terms. pasted may carry whitespace around it, as a paste or a file does. Only a
licence whose signature holds is read past its prefix.
*/
check :: proc(
	pasted: string,
	key: []byte,
	allocator := context.allocator,
) -> (
	l: Licence,
	err: Error,
) {
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, key) {
		return {}, .No_Key
	}
	text := strings.trim_space(pasted)
	if !strings.has_prefix(text, PREFIX) {
		// leita2. and on are a later format; anything else is not a licence.
		if strings.has_prefix(text, "leita") && strings.index_byte(text, '.') > 0 {
			return {}, .Version
		}
		return {}, .Malformed
	}
	cut := strings.last_index_byte(text, '.')
	if cut <= len(PREFIX) {
		return {}, .Malformed
	}
	signed, encoded_sig := text[:cut], text[cut + 1:]
	encoded_terms := signed[len(PREFIX):]
	if strings.index_byte(encoded_terms, '.') >= 0 {
		return {}, .Malformed
	}
	sig, serr := base64.decode(encoded_sig, allocator = context.temp_allocator)
	if serr != nil || len(sig) != ed25519.SIGNATURE_SIZE {
		return {}, .Malformed
	}
	if !ed25519.verify(&pub, transmute([]byte)signed, sig) {
		return {}, .Signature
	}
	raw, terr := base64.decode(encoded_terms, allocator = context.temp_allocator)
	if terr != nil {
		return {}, .Malformed
	}

	Terms :: struct {
		licensee, tier, order, issued: string,
	}
	terms: Terms
	if json.unmarshal(raw, &terms, allocator = context.temp_allocator) != nil {
		return {}, .Terms
	}
	tier, known := tier_of(terms.tier)
	if !known || strings.trim_space(terms.licensee) == "" || terms.order == "" {
		return {}, .Terms
	}
	return {
			licensee = strings.clone(strings.trim_space(terms.licensee), allocator),
			tier = tier,
			order = strings.clone(terms.order, allocator),
			issued = strings.clone(terms.issued, allocator),
		},
		.None
}

// tier_of is the tier name names, as a payload does.
tier_of :: proc(name: string) -> (Tier, bool) {
	for n, t in TIER_NAMES {
		if n == name {
			return t, true
		}
	}
	return {}, false
}

destroy :: proc(l: ^Licence, allocator := context.allocator) {
	delete(l.licensee, allocator)
	delete(l.order, allocator)
	delete(l.issued, allocator)
	l^ = {}
}

// path_beside is where the licence in use is kept: a file named name in the
// folder that holds the history store at kept. "" when kept is.
path_beside :: proc(kept: string, allocator := context.allocator, name := "licence") -> string {
	if kept == "" {
		return ""
	}
	path, _ := filepath.join({filepath.dir(kept), name}, allocator)
	return path
}

// TRIAL_DAYS is how long the paid features, reports and change tracking, work
// without a licence from the day leita first ran. It matches the evaluation
// LICENSE.md §4 gives an organisation: to run the Software "for up to 30 days"
// before it must buy a Commercial Licence.
TRIAL_DAYS :: 30

// DAY is a day of the trial.
DAY :: 24 * time.Hour

/*
CLOCK_SLACK is how far ahead of the clock a trial's start may be and still
count as now, so that a clock corrected back by minutes or hours after the
first run does not end the trial. A start further ahead than this means the
clock was turned back past it, and the trial is over.
*/
CLOCK_SLACK :: DAY

// FIRST_USE is the file beside the history store that holds when the trial
// began (first_use).
FIRST_USE :: "first-use"

// TRIAL_OVER is the start first_use gives when it has no honest one: so long
// ago that the trial is over.
TRIAL_OVER :: time.Time{}

// unlocked is whether the paid features work at now: under a licence, or in the
// trial that began at first.
unlocked :: proc(licensed: bool, first, now: time.Time) -> bool {
	return licensed || days_left(first, now) > 0
}

// days_left is how many days of the trial that began at first are left at now,
// counting the day under way; 0 once it is over, or when the clock was turned
// back past its start.
days_left :: proc(first, now: time.Time) -> int {
	gone := time.diff(first, now)
	if gone < -CLOCK_SLACK || gone >= TRIAL_DAYS * DAY {
		return 0
	}
	return TRIAL_DAYS - int(max(gone, 0) / DAY)
}

/*
Ledger is the second place the trial's start is kept, beside the first-use
file: settings.db, which the caller holds, since this package keeps to files of
its own (settings.trial_ledger). get is the text kept there and whether there is
any; set keeps text there and says whether it did. The zero Ledger keeps
nothing.
*/
Ledger :: struct {
	user: rawptr,
	get:  proc(user: rawptr) -> (text: string, found: bool),
	set:  proc(user: rawptr, text: string) -> bool,
}

// Holding is what one place holds of the trial's start.
@(private)
Holding :: enum u8 {
	Nothing, // no file, no setting: never written, or deleted
	Garbled, // there, but unreadable or not a number
	Stamp, // a start, in unix seconds
}

@(private)
Stamp :: struct {
	held: Holding,
	secs: i64,
}

/*
first_use is when the trial of the paid features began on this machine, as the
file at path and ledger remember it, at now. The first time it is asked it
writes now to both. Either may lose it, so the earlier of the two is the start,
and a place that lost it, or holds a later one, is given it again: deleting the
file, or settings.db, does not start the trial again while the other holds it.

Every other doubt ends the trial, and first_use returns TRIAL_OVER: a start that
is not a number, a file that is there but cannot be read, a start further ahead
of now than CLOCK_SLACK, and a machine where neither place can be written, which
would be told now again on every run. This fails closed on purpose. What it
guards is the paid features, reports and change tracking; scanning and Reclaim
never ask. Failing open would let a deleted file, a stamp set years ahead or a
read-only folder keep the trial for ever.
*/
first_use :: proc(path: string, ledger: Ledger, now: time.Time) -> time.Time {
	file, kept := stamp_of_file(path), stamp_of_ledger(ledger)
	secs, found := earliest(file, kept)
	if !found {
		if file.held == .Garbled || kept.held == .Garbled {
			return TRIAL_OVER
		}
		secs = time.to_unix_seconds(now)
	}
	start := time.unix(secs, 0)
	if time.diff(start, now) < -CLOCK_SLACK {
		return TRIAL_OVER
	}
	text := fmt.tprintf("%d\n", secs)
	wrote := false
	if file != (Stamp{.Stamp, secs}) {
		wrote = write_stamp(path, text) || wrote
	}
	if kept != (Stamp{.Stamp, secs}) && ledger.set != nil {
		wrote = ledger.set(ledger.user, strings.trim_space(text)) || wrote
	}
	if !found && !wrote {
		return TRIAL_OVER
	}
	return start
}

// earliest is the earlier start of a and b, and whether either holds one.
@(private)
earliest :: proc(a, b: Stamp) -> (secs: i64, found: bool) {
	for s in ([2]Stamp{a, b}) {
		if s.held == .Stamp && (!found || s.secs < secs) {
			secs, found = s.secs, true
		}
	}
	return
}

// stamp_of_file is what the file at path holds of the trial's start.
@(private)
stamp_of_file :: proc(path: string) -> Stamp {
	if path == "" || !os.exists(path) {
		return {}
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {held = .Garbled}
	}
	return stamp_of(string(data))
}

// stamp_of_ledger is what ledger holds of the trial's start.
@(private)
stamp_of_ledger :: proc(ledger: Ledger) -> Stamp {
	if ledger.get == nil {
		return {}
	}
	text, found := ledger.get(ledger.user)
	if !found {
		return {}
	}
	return stamp_of(text)
}

// stamp_of reads text as a start in unix seconds.
@(private)
stamp_of :: proc(text: string) -> Stamp {
	secs, ok := strconv.parse_i64(strings.trim_space(text))
	if !ok {
		return {held = .Garbled}
	}
	return {.Stamp, secs}
}

// write_stamp writes text to the file at path, making its folder if need be,
// and says whether it did.
@(private)
write_stamp :: proc(path, text: string) -> bool {
	if path == "" {
		return false
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		os.make_directory_all(dir)
	}
	return os.write_entire_file(path, text) == nil
}

// read is the text of the file at path, in the temp allocator.
read :: proc(path: string) -> (string, Error) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", .Unreadable
	}
	return string(data), .None
}

// save keeps text, a licence already checked, at path as the one in use,
// making its folder if need be, and replacing any licence kept before.
save :: proc(path, text: string) -> Error {
	if path == "" {
		return .Unwritable
	}
	if dir := filepath.dir(path); !os.exists(dir) {
		if os.make_directory_all(dir) != nil {
			return .Unwritable
		}
	}
	line := strings.concatenate({strings.trim_space(text), "\n"}, context.temp_allocator)
	if os.write_entire_file(path, transmute([]byte)line) != nil {
		return .Unwritable
	}
	return .None
}

// licensee_kept is whose licence is kept at path, checked against the key leita
// was built with: "" when there is none that checks. In the temp allocator.
licensee_kept :: proc(path: string) -> string {
	key, ok := public_key()
	if !ok || path == "" {
		return ""
	}
	text, err := read(path)
	if err != .None {
		return ""
	}
	l, cerr := check(text, key[:], context.temp_allocator)
	if cerr != .None {
		return ""
	}
	return l.licensee
}
