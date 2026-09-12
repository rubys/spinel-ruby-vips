# ruby-vips (spinel-ruby-vips)

A subset of the [ruby-vips](https://github.com/libvips/ruby-vips) gem for
Spinel, over the system [libvips](https://www.libvips.org/). The require
string is `vips` and the names are the gem's, so code written against the
gem — image_processing's vips pipeline, a Rails app's
`config/initializers/vips.rb` — resolves here unchanged:

```ruby
require "vips"

image = Vips::Image.new_from_buffer(bytes, "")   # or .new_from_file(path)
image.width, image.height, image.bands, image.has_alpha?

# resize_to_limit(512, 512) + format: :webp, as image_processing lowers it
thumb = Vips::Image.thumbnail_buffer(bytes, 512, height: 512, size: :down)
webp  = thumb.write_to_buffer(".webp")            # binary-safe String
image.thumbnail_image(192, height: 192, size: :down).write_to_file("small.png")

Vips.block_untrusted(true)                        # only fuzzed loaders/savers
Vips.block("VipsForeignLoadOpenslide", true)
Vips.vips_foreign_find_load("upload.bin")         # "VipsForeignLoadPngFile" / nil
Vips::LIBRARY_VERSION                             # "8.18.4"
```

Errors raise `Vips::Error`, with libvips' own message.

## How it is built

`sp_vips.c` is the whole native side: a few entry points, each one a
complete operation (load → thumbnail → encode) so **no `VipsImage` handle
ever crosses the FFI boundary**. A `Vips::Image` here is a value — the
source bytes, the dimensions libvips read from their header, and at most
one pending thumbnail — and every question it is asked is answered from
the bytes in one call. Nothing native outlives a call, so there is nothing
to finalise and the threaded runtime needs no locking beyond libvips' own
(the result buffers are per-thread; `test/threads_test.rb` exercises it).

The glue is **headerless on purpose**: `spin` compiles carried C with
`-I <package> -I <spinel>/lib` and nothing else, and `<vips/vips.h>`
pulls in glib's arch-specific include directories that only `pkg-config`
knows. Every libvips symbol used is declared in `sp_vips.c` instead —
`VipsImage` is opaque, the rest is `int` / `size_t` / `const char *` /
varargs — so the declarations are the ABI. The varargs calls
(`vips_thumbnail_buffer`, `vips_image_write_to_buffer`) have to stay in
C: an `ffi_func` prototype cannot spell `...`.

Linking is `ffi_lib "vips"` + `gobject-2.0` + `glib-2.0`, plus
`-L/opt/homebrew/lib -L/usr/local/lib` for macOS (a nonexistent `-L`
directory is ignored, so it costs nothing on Linux).

## Requirements

libvips has to be linkable at build time and loadable at run time:

- macOS: `brew install vips`
- Debian/Ubuntu: `libvips-dev` to build, `libvips42` to run

## Subset vs ruby-vips

- The gem wraps a live handle and reaches every libvips operation through
  GObject introspection. This port provides **header reads, thumbnail
  and encode** — the image_processing / Active Storage variant surface —
  and nothing else (no crop, rotate, composite, band arithmetic, …).
- `new_from_buffer`'s option string is accepted and not read; the loader
  is chosen from the bytes.
- A thumbnail of a thumbnail materialises the first through a lossless
  PNG. The gem builds one lazy pipeline; there is no observable
  difference except time.
- `write_to_buffer` / `write_to_file` take libvips' own suffix syntax
  (`".webp[Q=80]"`); the gem's keyword form (`Q: 80`) is not provided.
- `Vips.vips_foreign_find_load_buffer(data, size)` keeps the gem's raw
  two-argument C signature.

## Tests

```sh
spin test          # compiled port against the committed snapshots
sh oracle/run.sh   # the SAME test files under CRuby with the real gem
```

The snapshots were frozen from the gem, and the compiled port is held to
them: dimensions, byte counts of every encoding, format magic, loader
names and error behaviour are byte-identical between the two (both link
the same libvips, so the encoders agree). No hand-authored expectations.
A different libvips shows up as a byte-count diff, which is the honest
answer.

Fixtures: `test/moon.jpg` is once-campfire's test fixture (MIT);
`test/moon64.png` is its 64px thumbnail with an alpha band, made with
the gem.

## License

MIT, like the gem.
