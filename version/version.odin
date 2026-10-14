/*
Package version says which leita this is, the one place every binary learns
it: the command line's --version and its reports, and the window's title.
*/
package version

// VERSION is set with -define:LEITA_VERSION=x by whatever builds leita (the
// justfile's version, from git describe); "dev" otherwise.
VERSION :: #config(LEITA_VERSION, "dev")

// NAME is the product's name, the one place it is spelled: the command line's
// messages, the window's title and toolbar, its About dialog, and every message
// that names it. The binaries' file names and the LEITA_ variables are the
// build's and the environment's, and change apart from it.
NAME :: "leita"

// SHORT is the command line's short name, installed beside leita as the same
// binary: set with -define:LEITA_SHORT=x from the justfile's short, so -h
// names what install put on PATH.
SHORT :: #config(LEITA_SHORT, "le")
