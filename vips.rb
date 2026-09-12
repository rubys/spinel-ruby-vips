# ruby-vips for Spinel — a subset of the ruby-vips gem's surface over the
# system libvips, bound through the carried C in sp_vips.c. The require
# string is "vips" and the names are the gem's (Vips::Image
# .new_from_buffer / .thumbnail_buffer, #thumbnail_image,
# #write_to_buffer, Vips.block_untrusted, Vips.block, Vips::Error), so
# code written against the gem — image_processing's vips pipeline and a
# Rails app's config/initializers/vips.rb included — resolves here
# unchanged.
#
# Subset notes (vs ruby-vips): the gem wraps a live VipsImage handle and
# exposes every libvips operation through GObject introspection. This
# port has no handle: an Image is a VALUE — the source bytes, the
# dimensions libvips read from their header, and at most one pending
# thumbnail — and every operation runs as one call into C
# (load -> thumbnail -> encode), so nothing native outlives a call and
# there is nothing to finalise. Chaining a second thumbnail materialises
# the first through a lossless PNG. Operations beyond thumbnail and
# encode (crop, rotate, composite, ...) are not provided.

# Direct binding to the carried C. Top-level module (FFI plumbing must
# stay out of nested modules), distinctly named to coexist with other
# packages' extern modules in one program. Error returns are "" — the
# Vips layer reads sp_vips_error and raises Vips::Error.
#
# libvips is a system library, not vendored: `-lvips` plus the two glib
# libraries its API is built on. The -L entries are where Homebrew puts
# them on macOS; a directory that does not exist is ignored by the
# linker, so they cost nothing on Linux, where the distro's
# libvips-dev is on the default search path.
module VipsExt
  ffi_lib "vips"
  ffi_lib "gobject-2.0"
  ffi_lib "glib-2.0"
  ffi_cflags "-L/opt/homebrew/lib -L/usr/local/lib"

  ffi_func :sp_vips_version,          [],                                       :str
  ffi_func :sp_vips_error,            [],                                       :str
  ffi_func :sp_vips_block_untrusted,  [:int],                                   :void
  ffi_func :sp_vips_block,            [:str, :int],                             :void
  ffi_func :sp_vips_find_load,        [:str],                                   :str
  ffi_func :sp_vips_find_load_buffer, [:str, :size_t],                          :str
  ffi_func :sp_vips_dims,             [:str, :size_t],                          :str
  ffi_func :sp_vips_thumb_dims,       [:str, :size_t, :int, :int, :int],        :str
  ffi_func :sp_vips_encode,           [:str, :size_t, :int, :int, :int, :str],  :binstr
end

module Vips
  class Error < StandardError
  end

  # The gem's Vips::LIBRARY_VERSION: the linked libvips, e.g. "8.18.4".
  LIBRARY_VERSION = VipsExt.sp_vips_version

  # Refuse every loader/saver libvips does not consider fuzzed
  # (vips_block_untrusted_set). What Rails apps call from their
  # initializer; note it takes effect process-wide, as in the gem.
  def self.block_untrusted(state)
    VipsExt.sp_vips_block_untrusted(state ? 1 : 0)
  end

  # Block (or unblock) one operation class by name, e.g.
  # "VipsForeignLoadOpenslide" (vips_operation_block_set).
  def self.block(name, state)
    VipsExt.sp_vips_block(name, state ? 1 : 0)
  end

  # The loader libvips selects for a file, from its bytes rather than
  # its name — "VipsForeignLoadPngFile" — or nil when no (unblocked)
  # loader claims it.
  def self.vips_foreign_find_load(path)
    r = VipsExt.sp_vips_find_load(path)
    r == "" ? nil : r
  end

  # The gem exposes the raw C signature here: (data, size).
  def self.vips_foreign_find_load_buffer(bytes, size)
    r = VipsExt.sp_vips_find_load_buffer(bytes, size)
    r == "" ? nil : r
  end

  # The gem's VipsSize enum spelling: :both / :up / :down / :force.
  def self.size_code(size)
    s = size.to_s
    if s == "up"
      1
    elsif s == "down"
      2
    elsif s == "force"
      3
    else
      0
    end
  end

  # "<w> <h> <bands> <alpha>" from C, or "" for not-an-image.
  def self.parse_dims(dims, what)
    if dims == ""
      raise Error, VipsExt.sp_vips_error + " (" + what + ")"
    end
    dims.split(" ").map { |s| s.to_i }
  end

  class Image
    # The source bytes and what libvips read from their header. A
    # pending thumbnail (width > 0) is applied on top when the image is
    # asked for pixels (write_to_buffer / write_to_file).
    def initialize(bytes, width, height, bands, alpha, thumb_w, thumb_h, thumb_size)
      @bytes = bytes
      @width = width
      @height = height
      @bands = bands
      @alpha = alpha
      @thumb_w = thumb_w
      @thumb_h = thumb_h
      @thumb_size = thumb_size
    end

    def width
      @width
    end

    def height
      @height
    end

    def bands
      @bands
    end

    def has_alpha?
      @alpha
    end

    # The gem's Image#size: [width, height].
    def size
      [@width, @height]
    end

    # The gem's `new_from_buffer(data, option_string)`. The option
    # string is accepted for signature parity and not read: the loader
    # is chosen from the bytes, which is the case the gem's callers
    # mean by passing "".
    def self.new_from_buffer(bytes, option_string = "")
      d = Vips.parse_dims(VipsExt.sp_vips_dims(bytes, bytes.bytesize), "new_from_buffer")
      Image.new(bytes, d[0], d[1], d[2], d[3] == 1, 0, 0, 0)
    end

    def self.new_from_file(path)
      Image.new_from_buffer(File.binread(path), "")
    end

    # vips_thumbnail_buffer: fit within width x height (height
    # unconstrained when omitted). `size: :down` never enlarges, which
    # is what image_processing's resize_to_limit asks for.
    def self.thumbnail_buffer(bytes, width, height: 0, size: :both)
      code = Vips.size_code(size)
      d = Vips.parse_dims(VipsExt.sp_vips_thumb_dims(bytes, bytes.bytesize, width, height, code), "thumbnail_buffer")
      Image.new(bytes, d[0], d[1], d[2], d[3] == 1, width, height, code)
    end

    # The gem's Image#thumbnail_image. A thumbnail of a thumbnail is
    # built on the first one's pixels, encoded losslessly.
    def thumbnail_image(width, height: 0, size: :both)
      src = @thumb_w > 0 ? write_to_buffer(".png") : @bytes
      Image.thumbnail_buffer(src, width, height: height, size: size)
    end

    # Encode to the format the suffix names, with libvips' own option
    # syntax: ".png", ".webp[Q=80]", ".jpg[strip]". Binary-safe.
    def write_to_buffer(suffix)
      out = VipsExt.sp_vips_encode(@bytes, @bytes.bytesize, @thumb_w, @thumb_h, @thumb_size, suffix)
      if out == ""
        raise Error, VipsExt.sp_vips_error + " (write_to_buffer " + suffix + ")"
      end
      out
    end

    # The format is taken from the path's extension, as vips does.
    def write_to_file(path)
      dot = path.rindex(".")
      suffix = dot.nil? ? "" : path[dot, path.length - dot]
      File.binwrite(path, write_to_buffer(suffix))
      nil
    end
  end
end
