# Dependencies

## Linked components

### Crystal standard library

The runtime library of the Crystal language, version 1.21.0, compiled into the
[netwrangler] binaries and node-tool.

Home page: <https://crystal-lang.org/>\
License:
[Apache-2.0 WITH Swift-exception](https://github.com/crystal-lang/crystal/blob/1.21.0/LICENSE)

### Boehm GC

The garbage collector that Crystal programs link, from the Crystal build image;
linked into the [netwrangler] binaries but not into node-tool.

Home page: <https://github.com/bdwgc/bdwgc>\
License: [Boehm-GC](https://github.com/bdwgc/bdwgc/blob/master/LICENSE)

### PCRE2

The regular expression library that Crystal's `Regex` uses, from the Alpine
package; linked into the [netwrangler] binaries but not into node-tool.

Home page: <https://github.com/PCRE2Project/pcre2>\
License:
[BSD-3-Clause WITH PCRE2-exception](https://github.com/PCRE2Project/pcre2/blob/master/LICENCE.md)

### musl

The C library from the Alpine packages, linked into every binary but BusyBox.

Home page: <https://musl.libc.org/>\
License: [MIT](https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT)

## Bundled in the images

### BusyBox

The small set of Unix tools that make up the images' base layer, from
`busybox:1.37.0-uclibc`.

Home page: <https://busybox.net/>\
License: [GPL-2.0-only](https://busybox.net/license.html)

### uClibc-ng

The C library of the BusyBox base image, linked into BusyBox.

Home page: <https://uclibc-ng.org/>\
License:
[LGPL-2.1-only](https://github.com/wbx-github/uclibc-ng/blob/master/COPYING.LIB)

### shell-operator

The Kubernetes hook runner that watches resources for the controller and the
agent and calls the [netwrangler] hooks; version v1.14.2, built with Go 1.24.

Home page: <https://github.com/flant/shell-operator>\
License:
[Apache-2.0](https://github.com/flant/shell-operator/blob/v1.14.2/LICENSE)

### Go and shell-operator's Go modules

The Go standard library and the Go modules that the shell-operator binary
links. Each module's license is on
`https://pkg.go.dev/<module path>?tab=licenses`. The source of the two MPL-2.0
modules is on the Go module proxy,
`https://proxy.golang.org/<module path>/@v/`.

Home page: <https://go.dev/>\
License: [BSD-3-Clause](https://go.dev/LICENSE)

[netwrangler]: https://github.com/jochenseeber/netwrangler
