# ruby-vips (spinel-ruby-vips)

A subset of the [ruby-vips](https://github.com/libvips/ruby-vips) gem for
Spinel, over the system [libvips](https://www.libvips.org/). The require
string is `vips` and the names are the gem's, so code written against the
gem — image_processing's vips pipeline, a Rails app's
`config/initializers/vips.rb`, the tests that exercise its loader
policy — resolves here unchanged:

```ruby
require "vips"

image = Vips::Image.new_from_buffer(bytes, "")   # or .new_from_file(path)
image.width, image.height, image.bands, image.has_alpha?

# resize_to_limit(512, 512) + format: :webp, as image_processing lowers it
thumb = Vips::Image.thumbnail_buffer(bytes, 512, height: 512, size: :down)
webp  = thumb.write_to_buffer(".webp")            # binary-safe String
image.thumbnail_image(192, height: 192, size: :down).write_to_file("small.png")

# an image made in code; nothing is computed until it is written
png = Vips::Image.black(8, 8).add(128).cast("uchar").write_to_buffer(".png")

Vips::Image.pngload("avatar.png")                 # a loader, by name
Vips::Image.public_send(:openslideload, path)     # ... also through public_send

Vips.block_untrusted(true)                        # only fuzzed loaders/savers
Vips.block("VipsForeignLoadOpenslide", true)
Vips.vips_foreign_find_load("upload.bin")         # "VipsForeignLoadPngFile" / nil
Vips::LIBRARY_VERSION                             # "8.18.4"
```

Errors raise `Vips::Error`, with libvips' own message.

## How it is built

`Vips::Image` is what it is in the gem: an object holding a live
`VipsImage` reference, released by the garbage collector. The reference
is a Spinel `native_struct` (`VipsImageRef`), allocated in `sp_vips.c`
with `sp_gc_alloc` and a finalizer that calls `g_object_unref`, so
operations chain on real images and libvips stays lazy — nothing is
decoded until an image is written. The finalizer may run on a GC sweeper
thread; `g_object_unref` is safe from any thread and does nothing else.
`test/finalizer.rb` makes fifteen thousand images and checks that a
collection releases them.

`Vips::Image` itself is an ordinary Ruby class holding a `VipsImageRef`,
rather than being the native class: Spinel keys a native class's constant
by its last segment, so a native `Vips::Image` would merge with any other
`Image` in the program (Campfire has `Sound::Image`).

Bytes handed in (`new_from_buffer`, `thumbnail_buffer`) are copied into a
libvips blob behind a `VipsSource`. libvips reads a buffer lazily and does
not copy it, and its operation cache can keep a pipeline alive after the
call that built it; with the copy, libvips' own reference counting decides
when the bytes are freed, rather than Spinel's GC.

An operation libvips refuses answers an empty reference and the Ruby side
raises `Vips::Error` with libvips' error text, unmodified (trailing
newline included, as the gem has it — callers `chomp` it and match it line
by line). Encoded output comes back through a module-level `:binstr`
function rather than straight from the image's method: a `native_method`
returning bytes is copied at the call site by `strlen`, which would cut a
PNG at its first NUL.

The glue is **headerless on purpose**: `spin` compiles carried C with
`-I <package> -I <spinel>/lib` and nothing else, and `<vips/vips.h>`
pulls in glib's arch-specific include directories that only `pkg-config`
knows. Every libvips symbol used is declared in `sp_vips.c` instead —
the image, blob and source types are opaque, the rest is `int` / `size_t`
/ `double` / `const char *` / varargs — so the declarations are the ABI.
The varargs calls (`vips_thumbnail_source`, `vips_call`,
`vips_image_write_to_buffer`, …) have to stay in C: an `ffi_func`
prototype cannot spell `...`.

Linking is `ffi_lib "vips"` + `gobject-2.0` + `glib-2.0`, plus
`-L/opt/homebrew/lib -L/usr/local/lib` for macOS (a nonexistent `-L`
directory is ignored, so it costs nothing on Linux).

## Requirements

libvips has to be linkable at build time and loadable at run time:

- macOS: `brew install vips`
- Debian/Ubuntu: `libvips-dev` to build, `libvips42` to run

## Subset vs ruby-vips

- The gem reaches every libvips operation at run time through GObject
  introspection and `method_missing`. Spinel compiles ahead of time, so
  the operations are the ones declared in `vips.rb`: loading
  (`new_from_buffer`, `new_from_file`, and the file loaders by name —
  `jpegload`, `openslideload`, … — every loader whose only required
  argument is the filename), `thumbnail_buffer` / `thumbnail_image`,
  `black`, `add` with a number, `cast`, header reads (`width`, `height`,
  `bands`, `has_alpha?`, `format`, `size`), and encoding. No crop,
  rotate, composite, or arithmetic between two images.
- A named loader this libvips was built without answers libvips' own
  `VipsOperation: class "…" not found`, as in the gem.
- `write_to_buffer` / `write_to_file` take libvips' own suffix syntax
  (`".webp[Q=80]"`); the gem's keyword form (`Q: 80`) is not provided.
  Loaders take no keyword options either (the gem's `access:`, `page:`,
  …); `new_from_buffer`'s option string is passed to the loader.
- `Vips.vips_foreign_find_load_buffer(data, size)` keeps the gem's raw
  two-argument C signature.

## Tests

```sh
spin test          # compiled port against the committed snapshots
sh oracle/run.sh   # the SAME test files under CRuby with the real gem
```

`test/*_test.rb` are the conformance tests. Their snapshots were frozen
from the gem, and the compiled port is held to them: dimensions, byte counts of every encoding, format magic, loader
names and error behaviour are byte-identical between the two (both link
the same libvips, so the encoders agree). No hand-authored expectations.
A different libvips shows up as a byte-count diff, which is the honest
answer. `test/finalizer.rb` is not a conformance test (the gem has no
count to compare), so it has no `_test` suffix and the oracle skips it.

Fixtures: `test/moon.jpg` is once-campfire's test fixture (MIT);
`test/moon64.png` is its 64px thumbnail with an alpha band, made with
the gem.

## License

MIT, like the gem.
