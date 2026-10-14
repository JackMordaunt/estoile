package leita_app

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import "jm:stream"
import "jm:ui"
import bl "jm:ui/blend2d"

import "../command"
import "../query"

/*
Thumbnails of pictures, for query.Thumb, made as jm/examples/files/app/app.odin
makes its own.

The view asks for one per picture it shows, so only those on screen are made. A
need waits THUMB_QUIET first, so a row scrolled past never starts one, then a
worker reads the picture with Blend2D, fits it into a square and writes it as a
PNG the renderer reads by path. A need that goes while its picture is read is
called off where the work next checks.

What is made is kept in the thumbnail folder, named by the picture's path, its
modification time and the size asked for, so a picture is read once until it
changes, in this run or the next.
*/

// THUMB_QUIET is how long a thumbnail's need must stay before it is made.
THUMB_QUIET :: 60 * time.Millisecond

// THUMB_MAX is the largest picture read for a thumbnail: one bigger is shown by
// its kind's icon, rather than a worker spending a second on it.
THUMB_MAX :: 64 << 20

// THUMB_MAX_AGE is how long a thumbnail may sit unused before thumbs_prune
// drops it: a month, assumed long enough that it is not worth keeping a
// thumbnail against a maybe-return to the same picture.
THUMB_MAX_AGE :: 30 * 24 * time.Hour

// THUMB_MAX_BYTES bounds the thumbnail folder once the stale ones are gone:
// past it, thumbs_prune drops the least recently used until it fits. 256 MiB,
// a size picked to let even a large library's thumbnails sit around a while
// without the folder growing without bound.
THUMB_MAX_BYTES :: 256 << 20

// Thumbs is the host's thumbnail half: the port needs go in by, the job for
// each live need, and the folder thumbnails are kept in. Only a need's key goes
// down the pipeline, since the quiet drops all but the last of a key: the job
// is looked up when its turn comes.
Thumbs :: struct {
	port:   stream.Port(ui.Need_Key),
	jobs:   map[ui.Need_Key]^Thumb_Job, // under mutex
	mutex:  sync.Mutex,
	folder: string,
	wake:   proc(),
	inbox:  ^ui.Inbox,
}

// Thumb_Job is one thumbnail to make, and the flag that calls it off.
Thumb_Job :: struct {
	cancel:  bool, // atomic
	running: bool, // a worker has it; under the mutex
	key:     ui.Need_Key,
	path:    command.Text,
	px:      int,
}

// Thumb_Made is a job's end: the image made, empty when none was.
Thumb_Made :: struct {
	job:   ^Thumb_Job,
	image: command.Text,
}

// thumbs_init builds the thumbnail half of the pipeline, keeping thumbnails in
// folder, "" for leita's own under the user's cache folder.
thumbs_init :: proc(h: ^Host, folder: string) {
	t := &h.thumbs
	t.jobs = make(map[ui.Need_Key]^Thumb_Job)
	t.wake = h.desk.wake
	t.inbox = &h.inbox
	if folder != "" {
		t.folder = strings.clone(folder)
	} else if cache, err := os.user_cache_dir(context.temp_allocator); err == nil {
		t.folder, _ = filepath.join({cache, "leita", "thumbnails"}, context.allocator)
	}
	if t.folder != "" {
		os.make_directory_all(t.folder)
		// Off the pool, so a large cache never holds up the first frame. The
		// pool is several threads pulling from one queue (jm/stream/workers.odin),
		// so nothing orders this ahead of thumb_make there, and a cold folder's
		// read could easily run past the view's first ask (THUMB_QUIET later);
		// thumbs_prune guards each remove against a hit landing mid-walk, rather
		// than relying on going first.
		job := new(Thumb_Prune_Job)
		job.folder = t.folder
		stream.submit(h.workers, thumb_prune_run, job)
	}
	requests: stream.Stream(ui.Need_Key)
	requests, t.port = stream.port(h.p, ui.Need_Key, cap = 256, name = "thumbs")
	settled := stream.debounce_by(requests, THUMB_QUIET, thumb_key, name = "thumbs quiet")
	made := stream.async_map(
		settled,
		h.workers,
		t,
		thumb_make,
		concurrency = 4,
		ordered = false,
		name = "thumbnail",
	)
	stream.for_each_with(made, t, thumb_deliver, name = "thumbnail delivered")
}

// Thumb_Prune_Job is thumbs_prune's call, boxed for stream.submit. folder
// points at the live Thumbs.folder: workers_stop runs every queued job before
// thumbs_destroy frees it, so the job never outlives the string it reads.
@(private = "file")
Thumb_Prune_Job :: struct {
	folder: string,
}

@(private = "file")
thumb_prune_run :: proc(data: rawptr) {
	job := (^Thumb_Prune_Job)(data)
	thumbs_prune(job.folder, THUMB_MAX_AGE, THUMB_MAX_BYTES)
	free(job)
}

// thumbs_cancel calls off every thumbnail being made, for a host stopping.
thumbs_cancel :: proc(h: ^Host) {
	t := &h.thumbs
	sync.mutex_guard(&t.mutex)
	for _, job in t.jobs {
		sync.atomic_store(&job.cancel, true)
	}
}

// thumbs_destroy frees the jobs no worker took, once the workers have stopped.
thumbs_destroy :: proc(h: ^Host) {
	t := &h.thumbs
	for _, job in t.jobs {
		free(job)
	}
	delete(t.jobs)
	delete(t.folder)
}

// thumb_follow starts or calls off a thumbnail as its need comes and goes, on
// the main thread.
thumb_follow :: proc(h: ^Host, need: ui.Need, added: bool) {
	t := &h.thumbs
	q, ok := ui.need_as(need, query.Thumb)
	if !ok {
		return
	}
	sync.mutex_lock(&t.mutex)
	was, have := t.jobs[need.key]
	if !added {
		switch {
		case !have:
		case was.running:
			sync.atomic_store(&was.cancel, true) // its worker frees it
		case:
			delete_key(&t.jobs, need.key)
			free(was)
		}
		sync.mutex_unlock(&t.mutex)
		return
	}
	if have && !sync.atomic_load(&was.cancel) {
		sync.mutex_unlock(&t.mutex)
		return
	}
	job := new(Thumb_Job)
	job^ = {
		key  = need.key,
		path = command.text_make(q.path),
		px   = q.px,
	}
	t.jobs[need.key] = job
	sync.mutex_unlock(&t.mutex)
	// Sent with the lock released: a full port waits on the pool.
	stream.port_send(t.port, need.key)
}

@(private)
thumb_key :: proc(key: ui.Need_Key) -> ui.Need_Key {
	return key
}

// thumb_make runs on a worker: the thumbnail kept from before, or one made now.
// A key whose job has gone, or is already being made, makes nothing.
@(private)
thumb_make :: proc(t: ^Thumbs, key: ui.Need_Key) -> (done: Thumb_Made) {
	sync.mutex_lock(&t.mutex)
	job := t.jobs[key]
	if job == nil || job.running {
		sync.mutex_unlock(&t.mutex)
		return
	}
	job.running = true
	sync.mutex_unlock(&t.mutex)
	done.job = job
	if sync.atomic_load(&job.cancel) || t.folder == "" {
		return
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)

	path := command.text_of(&job.path)
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.type != .Regular || info.size > THUMB_MAX {
		return
	}
	kept := thumb_file(t.folder, path, time.time_to_unix_nano(info.modification_time), job.px)
	if os.exists(kept) {
		// A hit: thumbs_prune reads modification time as "last used", so touch
		// it here rather than lean on access_time, which relatime and noatime
		// mounts (common defaults; see mount(8)) are meant not to move on a
		// plain read. Cheap enough, since a hit is the common case and a write
		// is one syscall.
		now := time.now()
		os.change_times(kept, now, now)
	} else {
		// Written beside, then renamed into place, so a reader never finds half
		// of one, and two workers making the same one do not collide. Still a
		// .png: bl.image_write_to_file picks its encoder by the extension, and
		// a .part failed to write in a_thumbnail_is_made_once_and_kept.
		part := fmt.tprintf("%s.%x.part.png", strings.trim_suffix(kept, ".png"), uintptr(job))
		if !thumbnail(path, part, job.px, &job.cancel) {
			os.remove(part)
			return
		}
		if os.rename(part, kept) != nil {
			os.remove(part)
			return
		}
	}
	done.image = command.text_make(kept)
	return
}

// thumb_file is where the thumbnail of path, as of modified, px across, is kept.
thumb_file :: proc(folder, path: string, modified: i64, px: int) -> string {
	name := hash.fnv64a(transmute([]byte)path)
	return fmt.tprintf("%s%c%016x-%x-%d.png", folder, filepath.SEPARATOR, name, modified, px)
}

// thumb_prune_is_unmoved re-stats path right before a remove thumbs_prune has
// otherwise decided on, and says whether its modification time still matches
// snapshot, the one the walk saw: false means something moved it since - a
// hit, thumb_make's touch landing between its exists check and handing back
// the path, a gap the walk itself cannot see - so the caller keeps it rather
// than drop a thumbnail in use. A brief window remains even so, between this
// stat and the remove that follows it; losing it costs one thumbnail remade
// on the next ask, the same cost thumb_make already pays for a miss.
@(private)
thumb_prune_is_unmoved :: proc(path: string, snapshot: time.Time) -> (unmoved: bool, size: i64) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return false, 0
	}
	return time.diff(snapshot, info.modification_time) == 0, info.size
}

/*
thumbs_prune keeps folder bounded: first it drops every thumbnail whose last
use (thumb_make's touch on a hit, or its making) is older than max_age, then,
if the folder still holds more than max_bytes, the least recently used go next
until it does. A file modified since this call began is left alone either
way - made or read by this same run, not stale from the last one.

thumb_make runs on the same pool as this and nothing orders the two, so a hit
can land between the walk below and a remove it decided on; thumb_prune_is_unmoved
guards each one.
*/
thumbs_prune :: proc(folder: string, max_age: time.Duration, max_bytes: i64) {
	cutoff := time.now()
	dir, open_err := os.open(folder)
	if open_err != nil {
		return
	}
	defer os.close(dir)
	entries, read_err := os.read_dir(dir, -1, context.temp_allocator)
	if read_err != nil {
		return
	}

	Live :: struct {
		path: string,
		size: i64,
		used: time.Time,
	}
	live := make([dynamic]Live, 0, len(entries), context.temp_allocator)
	total: i64
	for e in entries {
		if e.type != .Regular {
			continue
		}
		age := time.diff(e.modification_time, cutoff)
		switch {
		case age <= 0:
			// Made or touched since cutoff.
			total += e.size
		case age > max_age:
			if unmoved, size := thumb_prune_is_unmoved(e.fullpath, e.modification_time); unmoved {
				os.remove(e.fullpath)
			} else {
				total += size // kept live, not dropped out from under a hit
			}
		case:
			append(&live, Live{e.fullpath, e.size, e.modification_time})
			total += e.size
		}
	}
	if total <= max_bytes {
		return
	}

	slice.sort_by(
		live[:],
		proc(a, b: Live) -> bool {
			return time.diff(a.used, b.used) > 0 // oldest used first
		},
	)
	for l in live {
		if total <= max_bytes {
			break
		}
		// Its size is already in total, whether this drops it or, touched
		// since the walk, leaves it live.
		if unmoved, _ := thumb_prune_is_unmoved(l.path, l.used);
		   unmoved && os.remove(l.path) == nil {
			total -= l.size
		}
	}
}

/*
thumbnail reads the picture at src, fits it into a square px across keeping its
shape, on nothing, and writes the square to dst as a PNG. False when cancel was
set, or the picture could not be read or the square written. Each call has an
image and a context of its own, so workers call it side by side, as
jm/examples/files/fs/fs.odin's thumbnail is called.
*/
thumbnail :: proc(src, dst: string, px: int, cancel: ^bool) -> bool {
	if sync.atomic_load(cancel) {
		return false
	}
	img: bl.ImageCore
	bl.image_init(&img)
	defer bl.image_destroy(&img)
	if bl.image_read_from_file(&img, strings.clone_to_cstring(src, context.temp_allocator), nil) !=
	   0 {
		return false
	}
	bl.image_convert(&img, .PRGB32)
	data: bl.ImageData
	if bl.image_get_data(&img, &data) != 0 || data.size.w == 0 || data.size.h == 0 {
		return false
	}
	if sync.atomic_load(cancel) {
		return false
	}
	w, h := f64(data.size.w), f64(data.size.h)
	scale := min(f64(px) / w, f64(px) / h, 1)
	fit := bl.Rect{(f64(px) - w * scale) / 2, (f64(px) - h * scale) / 2, w * scale, h * scale}
	out: bl.ImageCore
	bl.image_init(&out)
	defer bl.image_destroy(&out)
	if bl.image_create(&out, i32(px), i32(px), .PRGB32) != 0 {
		return false
	}
	ctx: bl.ContextCore
	bl.context_init(&ctx)
	defer bl.context_destroy(&ctx)
	if bl.context_begin(&ctx, &out, nil) != 0 {
		return false
	}
	bl.context_clear_all(&ctx)
	bl.context_blit_scaled_image_d(&ctx, &fit, &img, nil)
	bl.context_end(&ctx)
	if sync.atomic_load(cancel) {
		return false
	}
	return(
		bl.image_write_to_file(&out, strings.clone_to_cstring(dst, context.temp_allocator), nil) ==
		0 \
	)
}

// thumb_deliver, on a pool thread, hands a thumbnail to the window if its need
// is still the job's, and retires the job.
@(private)
thumb_deliver :: proc(t: ^Thumbs, d: Thumb_Made) {
	job := d.job
	if job == nil {
		return
	}
	d := d
	sync.mutex_lock(&t.mutex)
	current := t.jobs[job.key] == job
	if current {
		delete_key(&t.jobs, job.key)
	}
	sync.mutex_unlock(&t.mutex)
	if current && !sync.atomic_load(&job.cancel) {
		buf: [2 * command.MAX_PATH + 256]byte
		stack: mem.Arena
		mem.arena_init(&stack, buf[:])
		context.temp_allocator = mem.arena_allocator(&stack)
		ui.inbox_put_value(
			t.inbox,
			query.Thumb{path = command.text_of(&job.path), px = job.px},
			query.Thumb_Result{image = command.text_of(&d.image)},
		)
		if t.wake != nil {
			t.wake()
		}
	}
	free(job)
}
