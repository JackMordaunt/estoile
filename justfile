# Standard recipes: build, run, clean, test, install.
#
#   just build [release]      the command line and the window, debug with ASan by
#                             default, release optimised
#   just cli [release]        the command line alone -> build/<mode>/leita
#   just gui [release]        the window alone -> build/<mode>/app/Leita
#   just run [release] [dir]  build the window, then open it on a directory, the
#                             home directory by default
#   just test                 run every imported package's tests under ASan -> build/test/
#   just btrfs-test [--sudo]  the btrfs and walk tests on a throw-away btrfs image,
#                             as root too with --sudo where sudo asks no password
#   just mount-test [--sudo]  the delete test that mounts, in a namespace of its own
#   just install              put the release command line on PATH as leita and le
#   just check                type-check both modes without producing a binary
#   just clean                remove build/
#   just deps                 fetch the jm submodule and the native libraries the window links
#   just sqlite               fetch the jm submodule and build SQLite, all the command line links
#   just hot [dir]            run's debug window without the sanitizer, the view reloaded
#                             in place on every edit
#   just gui-test             run the window's tests, the host's on a real directory
#
# The debug allocator, flow, sqlite3, stream and ui come from the jm collection, pinned as
# the jm submodule (https://mordaunt.dev/code/jm); JM=<path> builds against another
# checkout instead.
#
# Debug and test builds carry -sanitize:address. The debug allocator poisons its
# guard bytes and freed blocks, so instrumented reads past the end or after free
# trap at the faulting instruction. Pass SAN= to build without it:
# `SAN= just build`. The hot-reload window alone builds without it, hot_opt
# below. Odin does not create output directories, hence the mkdir.

odin  := env("ODIN", "odin")
# Forward slashes throughout: justfile_directory() on Windows returns
# backslashes, and passing those mixed with the "/" below straight to a
# native exe (odin.exe is not an MSYS program) through Git Bash corrupts
# the path, as jm's own justfile already normalises root for the same
# reason.
root  := replace(justfile_directory(), "\\", "/")
jm    := env("JM", root / "jm")
# Which leita a build is, the one place either binary learns it: the tag
# described, or a bare commit as git describe names one, g and its hash, so Odin
# never reads it as a number; dev without git. LEITA_VERSION=<v> sets it instead.
version := env("LEITA_VERSION", `git describe --tags --dirty 2>/dev/null || { h=$(git describe --always --dirty 2>/dev/null) && echo "g$h"; } || echo dev`)
# check_flags is what odin check takes; flags adds the macOS minimum, which
# only build, run and test accept.
check_flags := "-vet -strict-style -collection:jm=" + jm + " -define:LEITA_VERSION=" + version + " -define:LEITA_SHORT=" + short
flags := check_flags + minos
# macOS 11.0 is the oldest Odin targets, and jm builds its native libraries
# for it. Without the flag a binary carries the building Mac's own version as
# its minimum, and an older Mac refuses to start it.
minos := if os() == "macos" { " -minimum-os-version:11.0" } else { "" }
san   := env("SAN", "-sanitize:address")
# What just hot builds the host and the view with, instead of -debug {{san}}:
# the loop is for editing the view, and every edit waits on a child build, so
# the profile buys frame time only where it costs no compile time. No ASan: a
# frame in the view costs 5.5x release with it, 2.3x without (measured
# 2026-10-16, scanning ~/Source); just gui, just test and just gui-test keep
# it. -o:minimal: the frame median goes from 28 ms to 17 ms and the child
# build from 0.97 s to 1.02 s; -o:speed reaches 8 ms but builds in 15 s. No
# allocation backtraces: the debug allocator captures a call chain at every
# allocation, and the scan's workers allocate enough that the scan keeps in
# 1.6 s instead of 2.6 s without them. A leak or issue report still names
# the allocating file, line and proc; it loses the call chain under them,
# so a leak hunt is a job for just gui.
hot_opt := "-debug -o:minimal -define:DEBUG_ALLOC_BACKTRACES=false"
exe   := if os() == "windows" { ".exe" } else { "" }
bin   := "leita"
# The short name install puts beside leita, the same command in two letters, as
# fd and rg are. Debian and Homebrew carry an old editor called le; it is rare
# enough that leita takes the name. The build hands it to version.SHORT, so a
# change here fails just test until -h names the new one.
short := "le"
# The window is Leita and builds into app/ beside the CLI: macOS and Windows
# fold case by default, so leita and Leita in one directory are one file.
gui   := "Leita"
# What links jm:ui/shell on macOS: the static SDL3 jm's sdl3 recipe builds, so
# the window starts on a Mac without Homebrew, and the frameworks a static
# SDL3 needs, the Libs line of the sdl3.pc that build writes. vendor:sdl3 asks
# for -lSDL3, and Odin puts -L/opt/homebrew/lib ahead of any -L given here, so
# ld would take a Homebrew dylib where one is installed: the archive is loaded
# whole by path instead, and the dylib, then unused, dropped. Linux finds its
# SDL3 in a system lib directory and Windows loads the DLL, so neither adds
# anything.
sdl3_dir  := jm / "ui/shell/lib"
sdl3_link := if os() == "macos" { "-extra-linker-flags:\"-L" + sdl3_dir + " -Wl,-force_load," + sdl3_dir + "/libSDL3.a -Wl,-dead_strip_dylibs" + \
    " -framework CoreMedia -framework CoreVideo -framework Cocoa -Wl,-weak_framework,UniformTypeIdentifiers" + \
    " -framework IOKit -framework ForceFeedback -framework Carbon -framework CoreAudio -framework AudioToolbox" + \
    " -framework AVFoundation -framework Foundation -framework GameController -framework Metal -framework QuartzCore" + \
    " -Wl,-weak_framework,CoreHaptics\"" } else { "" }

# `just` alone lists the recipes.
default:
    @just --list --unsorted

# Build the command line and the window: just build [release]
build mode="debug": (cli mode) (gui mode)

# The command line, debug with AddressSanitizer or release optimised.
#
# Build the command line -> build/<mode>/leita: just cli [release]
cli mode="debug": sqlite
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
    debug) opt="-debug {{san}}" ;;
    release) opt="-o:speed" ;;
    *) echo "cli: the mode is debug or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}
    {{odin}} build . $opt {{flags}} -out:build/{{mode}}/{{bin}}{{exe}}

# The window, debug with AddressSanitizer or release optimised.
#
# Build the window -> build/<mode>/app/Leita: just gui [release]
gui mode="debug": deps
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
    debug) opt="-debug {{san}}" ;;
    release) opt="-o:speed" ;;
    *) echo "gui: the mode is debug or release, not {{mode}}" >&2; exit 1 ;;
    esac
    mkdir -p build/{{mode}}/app
    {{odin}} build gui $opt {{flags}} {{sdl3_link}} -out:build/{{mode}}/app/{{gui}}{{exe}}
    if [ "{{os()}}" = windows ]; then
        cp "$({{odin}} root)/vendor/sdl3/SDL3.dll" build/{{mode}}/app/
        cp "{{jm}}/ui/accesskit/lib/accesskit.dll" build/{{mode}}/app/ 2>/dev/null || true
    fi

# A first argument of release builds and runs the release build.
#
# Build the window, then open it on a directory: just run [release] [dir]
[positional-arguments]
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    mode=debug
    if [ "${1:-}" = release ] || [ "${1:-}" = debug ]; then mode=$1; shift; fi
    just --justfile "{{justfile()}}" gui "$mode"
    exec build/$mode/app/{{gui}}{{exe}} "$@"

# Run the tests of every package the binary imports, pdf among them, under ASan
# -> build/test/
test: sqlite
    mkdir -p build/test
    {{odin}} test . -all-packages -debug {{san}} {{flags}} -out:build/test/{{bin}}{{exe}}

# The btrfs and walk tests on a btrfs image made, mounted and filled for them,
# against a total worked out from the image; skipped where nothing can mount one.
# --sudo lets it mount with sudo and test as root too, where sudo asks no password,
# as CI does. See tools/btrfs-fixture: just btrfs-test [--sudo] [--keep]
btrfs-test *args: sqlite
    tools/btrfs-fixture --odin "{{odin}}" --flags "{{san}} {{flags}}" {{args}}

# The delete test that mounts: a tmpfs and a bind inside a tree being deleted.
# It runs in a user and mount namespace of its own (unshare -rm), which needs no
# root and leaves nothing mounted; --sudo runs it as root instead, where sudo asks
# no password. Skipped where neither can mount. Linux only: just mount-test [--sudo]
mount-test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{os()}}" != linux ]; then echo "mount-test: skipped: the mounts are Linux's"; exit 0; fi
    mkdir -p build/test
    {{odin}} build gui/files -build-mode:test -debug {{san}} {{flags}} \
        -define:ODIN_TEST_NAMES=leita_files.a_delete_never_crosses_a_mount -out:build/test/mount-test
    if [ "{{args}}" = --sudo ]; then
        exec sudo -n env LEITA_MOUNT_TEST=1 build/test/mount-test
    elif unshare --user --map-root-user --mount true 2>/dev/null; then
        LEITA_MOUNT_TEST=1 exec unshare --user --map-root-user --mount build/test/mount-test
    fi
    echo "mount-test: skipped: no user namespaces here; give --sudo where sudo asks no password"

# Type-check both modes without producing a binary.
check:
    {{odin}} check . {{check_flags}}
    {{odin}} check . -debug {{check_flags}}

# The jm submodule, when JM does not name another checkout, and SQLite, which
# keeps both binaries' scans: all the command line links that is not Odin. Built
# by jm's own recipe, once.
sqlite:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{jm}}" = "{{root}}/jm" ] && [ ! -e jm/.git ]; then git submodule update --init jm; fi
    cd "{{jm}}"
    ls sqlite3/lib/sqlite3.* >/dev/null 2>&1 || just sqlite

# What sqlite fetches, and the libraries jm:ui links: Blend2D to draw,
# kb_text_shape to shape text, AccessKit for screen readers, and on macOS
# SDL3 itself. Each is built or fetched by jm's own recipe, once.
deps: sqlite
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{jm}}"
    ls ui/blend2d/lib/*blend2d* >/dev/null 2>&1 || just blend2d
    ls ui/kb/lib/kb_text_shape.* >/dev/null 2>&1 || just kb
    ls ui/accesskit/lib/*accesskit* >/dev/null 2>&1 || just accesskit
    just sdl3

# The window with its view hot-reloaded. The host (gui/host) owns the window and
# the scan; the view runs as gui/child in a subprocess, rebuilt here whenever an
# .odin file it is made of changes, into its own timestamped binary under
# build/hot, named in build/hot/view.watch, which the host re-reads and respawns
# from (ui/shell.run_host). The scan keeps running across reloads; a change to
# the scan or the pipeline (gui/app, survey, scan, walk, ntfs) needs the recipe
# run again. A shell loop rather than jm's tools/hot-watch, which passes its own
# checkout as the jm collection. stat is GNU's -c or BSD's -f, whichever runs.
# Both builds take hot_opt, the sanitizer-free profile, not -debug {{san}}.
#
# Open the window, reloading the view on every edit: just hot [dir]
hot *args: deps
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build/debug/app build/hot
    {{odin}} build gui/host {{hot_opt}} {{flags}} {{sdl3_link}} -out:build/debug/app/{{gui}}-host{{exe}}
    rm -f build/hot/view.watch
    (
      last=""
      n=0
      while true; do
        srcs=(gui/child/*.odin gui/view/*.odin gui/query/*.odin gui/command/*.odin human/*.odin)
        mt=$({ stat -c %Y "${srcs[@]}" 2>/dev/null || stat -f %m "${srcs[@]}"; } | sort -n | tail -1)
        if [ "$mt" != "$last" ]; then
          last=$mt
          n=$((n + 1))
          out=build/hot/view-$(date +%s)-${n}{{exe}}
          if {{odin}} build gui/child {{hot_opt}} {{flags}} -out:"$out"; then
            printf '%s' "$out" > build/hot/view.watch
            echo "hot: view ready $out"
            ls -t build/hot/view-* | tail -n +3 | xargs -r rm -f
          else
            echo "hot: build failed; the window keeps the last good view"
          fi
        fi
        sleep 0.4
      done
    ) &
    watcher=$!
    trap 'kill $watcher 2>/dev/null' EXIT
    while [ ! -f build/hot/view.watch ]; do sleep 0.2; done
    build/debug/app/{{gui}}-host{{exe}} build/hot/view.watch {{args}}

# Leita's own suite (which arguments open the window and which run leita), the
# view in a probe over the host on a real directory, the view's own suite,
# the messages' (every language has every message), the platform package's, and
# those of the packages only the window imports, search among them. Not -all-packages, which would run every jm:ui
# suite the window imports too.
#
# Run the window's suites under ASan
gui-test: deps
    mkdir -p build/test/app
    {{odin}} test gui -debug {{san}} {{flags}} {{sdl3_link}} -out:build/test/app/{{gui}}-main{{exe}}
    {{odin}} test gui/app -debug {{san}} {{flags}} {{sdl3_link}} -out:build/test/app/{{gui}}{{exe}}
    {{odin}} test gui/files -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-files{{exe}}
    {{odin}} test gui/view -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-view{{exe}}
    {{odin}} test gui/msg -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-msg{{exe}}
    {{odin}} test reclaim -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-reclaim{{exe}}
    {{odin}} test history -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-history{{exe}}
    {{odin}} test settings -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-settings{{exe}}
    {{odin}} test licence -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-licence{{exe}}
    {{odin}} test search -debug {{san}} {{flags}} -out:build/test/app/{{gui}}-search{{exe}}

# Remove build/.
clean:
    rm -rf build

# Copy the release binary to a directory on PATH, with the short name beside it:
# a symlink to leita on Unix, a second copy on Windows, where a symlink needs
# administrator rights or developer mode. An installed copy is replaced in place;
# otherwise ~/.local/bin, ~/bin, GOBIN, GOPATH/bin, /usr/local/bin, else the first
# writable PATH entry.
install: (cli "release")
    #!/usr/bin/env bash
    set -euo pipefail
    dest=""
    if existing=$(command -v {{bin}} 2>/dev/null) && [[ -w ${existing%/*} ]]; then
        dest=${existing%/*}
    fi
    gopath=$(go env GOPATH 2>/dev/null || true); gobin=$(go env GOBIN 2>/dev/null || true)
    for d in "$HOME/.local/bin" "$HOME/bin" "$gobin" "${gopath:+$gopath/bin}" /usr/local/bin; do
        [[ -z $dest && -n $d && -d $d && -w $d && ":$PATH:" == *":$d:"* ]] && dest=$d
    done
    if [[ -z $dest ]]; then
        IFS=: read -ra dirs <<<"$PATH"
        for d in "${dirs[@]}"; do [[ -d $d && -w $d ]] && { dest=$d; break; }; done
    fi
    [[ -n $dest ]] || { echo "install: no writable directory on PATH" >&2; exit 1; }
    install -m 755 build/release/{{bin}}{{exe}} "$dest/{{bin}}"
    if [[ "{{os()}}" == windows ]]; then
        install -m 755 build/release/{{bin}}{{exe}} "$dest/{{short}}"
    else
        ln -sf {{bin}} "$dest/{{short}}"
    fi
    echo "installed $dest/{{bin}} and $dest/{{short}}"

# leita against fd on one seeded tree: the host filesystem, then throw-away
# ext4 and btrfs images, then tmpfs. Loop images sit on this disk, so they
# are not a raw drive. Warm cache only. `just fsbench "--files 20000"`
# shortens the seed. vfat is opt-in (`--only vfat`); its desktop mount syncs
# every created file.
fsbench args="": (cli "release")
    python3 tools/fsbench {{args}}

