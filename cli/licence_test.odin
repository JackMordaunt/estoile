package leita_cli

import "core:crypto"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../licence"
import "../monitor"

// A key pair made for a test, standing in for Librium's.
@(private = "file")
Signer :: struct {
	priv: ed25519.Private_Key,
	pub:  [ed25519.PUBLIC_KEY_SIZE]byte,
}

@(private = "file")
signer :: proc() -> (s: Signer) {
	context.random_generator = crypto.random_generator()
	ok := ed25519.private_key_generate(&s.priv)
	assert(ok)
	ed25519.private_key_public_bytes(&s.priv, s.pub[:])
	return
}

// mint signs terms as a licence, in the temp allocator.
@(private = "file")
mint :: proc(s: ^Signer, terms: string) -> string {
	signed := strings.concatenate(
		{licence.PREFIX, base64.encode(transmute([]byte)terms, allocator = context.temp_allocator)},
		context.temp_allocator,
	)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&s.priv, transmute([]byte)signed, sig[:])
	return strings.concatenate(
		{signed, ".", base64.encode(sig[:], allocator = context.temp_allocator)},
		context.temp_allocator,
	)
}

@(private = "file")
TERMS :: `{"licensee": "Acme Ltd", "tier": "office", "order": "ord_1", "issued": "2026-10-11"}`

// A data folder for one test, and the history store in it.
@(private = "file")
data_folder :: proc(t: ^testing.T) -> (dir, kept: string) {
	err: os.Error
	dir, err = os.make_directory_temp("", "leita-licence-cli-*", context.temp_allocator)
	testing.expect(t, err == nil)
	return dir, fmt.tprintf("%s/data/history.db", dir)
}

// licence_says runs leita licence args, returning the exit code and what it said
// on standard output.
@(private = "file")
licence_says :: proc(c: Licence_Context, args: ..string) -> (int, string) {
	b := strings.builder_make(context.temp_allocator)
	code := licence_dispatch(c, args, strings.to_writer(&b))
	return code, strings.to_string(b)
}

// leita licence add keeps a licence where the window keeps its own, leita
// licence shows whose it is and that it does not expire, and leita licence
// remove forgets it, after which the trial is all there is.
@(test)
a_licence_is_added_shown_and_removed :: proc(t: ^testing.T) {
	s := signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept = kept,
		key  = s.pub[:],
		now  = time.unix(1_800_000_000, 0),
	}
	kept_at := licence.path_beside(kept, context.temp_allocator)

	code, said := licence_says(c, "add", mint(&s, TERMS))
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "licensed to Acme Ltd, Office, up to 10 people"), said)
	testing.expect(t, os.exists(kept_at), "it is kept beside the history store")

	code, said = licence_says(c)
	testing.expect_value(t, code, EXIT_OK)
	for want in ([]string{"to Acme Ltd", "Office, up to 10 people", "ord_1, issued 2026-10-11", "expires    never"}) {
		testing.expectf(t, strings.contains(said, want), "%q is not in %q", want, said)
	}

	code, said = licence_says(c, "remove")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, !os.exists(kept_at), "it is forgotten")
	code, said = licence_says(c)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "no licence; the trial"), said)
	code, said = licence_says(c, "remove")
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "no licence is kept here"), said)
}

// The file from the receipt is taken as well as the line it holds; anything
// else, a licence key or a licence another key signed, is refused and nothing
// is kept.
@(test)
a_licence_file_is_added_and_what_is_not_a_licence_refused :: proc(t: ^testing.T) {
	s, other := signer(), signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	c := Licence_Context {
		kept = kept,
		key  = s.pub[:],
		now  = time.unix(1_800_000_000, 0),
	}
	kept_at := licence.path_beside(kept, context.temp_allocator)

	for offered in ([]string{"polar_cl_0a1b2c3d", mint(&other, TERMS), "leita1.e30=.AAAA"}) {
		code, _ := licence_says(c, "add", offered)
		testing.expectf(t, code == EXIT_ERROR, "%s was taken", offered)
	}
	testing.expect(t, !os.exists(kept_at), "nothing is kept")
	code, _ := licence_says(c, "add")
	testing.expect_value(t, code, EXIT_ERROR)
	code, _ = licence_says(c, "add", "a", "b")
	testing.expect_value(t, code, EXIT_ERROR)
	code, _ = licence_says(c, "show")
	testing.expect_value(t, code, EXIT_ERROR)

	file := fmt.tprintf("%s/leita-licence.txt", dir)
	testing.expect(t, os.write_entire_file(file, fmt.tprintf("%s\n", mint(&s, TERMS))) == nil)
	code, _ = licence_says(c, "add", file)
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, os.exists(kept_at), "the file's licence is kept")
}

// LEITA_LICENCE holds a licence for one run in place of the one kept, for the
// report and the monitor alike, and leita licence says it is in use; one that
// does not check is said, and the run goes on without it.
@(test)
leita_licence_holds_a_licence_for_one_run :: proc(t: ^testing.T) {
	s := signer()
	dir, kept := data_folder(t)
	defer os.remove_all(dir)
	began := time.unix(1_800_000_000, 0)
	month := time.time_add(began, 31 * licence.DAY)
	line := mint(&s, TERMS)

	licensee, unlocked, problem := monitor.licence_beside(kept, "", began, s.pub[:])
	testing.expect(t, unlocked && licensee == "", "the trial begins")
	licensee, unlocked, problem = monitor.licence_beside(kept, "", month, s.pub[:])
	testing.expect(t, !unlocked, "a month on, it is over")

	licensee, unlocked, problem = monitor.licence_beside(kept, line, month, s.pub[:])
	testing.expect(t, unlocked, "LEITA_LICENCE unlocks this run")
	testing.expect_value(t, licensee, "Acme Ltd")
	testing.expect_value(t, problem, "")
	testing.expect(
		t,
		!os.exists(licence.path_beside(kept, context.temp_allocator)),
		"and keeps nothing",
	)

	licensee, unlocked, problem = monitor.licence_beside(kept, "leita1.x.y", month, s.pub[:])
	testing.expect(t, !unlocked && licensee == "", "a bad one unlocks nothing")
	testing.expect(t, strings.contains(problem, "LEITA_LICENCE holds no licence"), problem)

	code, said := licence_says({kept = kept, given = line, key = s.pub[:], now = month})
	testing.expect_value(t, code, EXIT_OK)
	testing.expect(t, strings.contains(said, "LEITA_LICENCE, for this run"), said)
}
