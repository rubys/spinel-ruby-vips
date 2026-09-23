# ruby-vips for Spinel — a subset of the ruby-vips gem's surface over the
# system libvips, bound through the carried C in sp_vips.c. The require
# string is "vips" and the names are the gem's, so code written against
# the gem — image_processing's vips pipeline, a Rails app's
# config/initializers/vips.rb, and the tests that exercise its loader
# policy — resolves here unchanged.
#
# Vips::Image is a native object, as in the gem: each one holds a live
# VipsImage reference and the GC releases it (sp_vips.c's finalizer), so
# operations chain on real images and libvips stays lazy — nothing is
# decoded until the image is written. What differs from the gem is reach:
# the gem finds every libvips operation at run time through GObject
# introspection and method_missing; Spinel compiles ahead of time, so the
# operations provided are the ones declared below.

# Module-level functions, bound directly to the carried C. Top-level module
# (FFI plumbing must stay out of nested modules), distinctly named to
# coexist with other packages' extern modules in one program.
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

  ffi_func :sp_vips_version,          [],              :str
  ffi_func :sp_vips_error,            [],              :str
  ffi_func :sp_vips_block_untrusted,  [:int],          :void
  ffi_func :sp_vips_block,            [:str, :int],    :void
  ffi_func :sp_vips_find_load,        [:str],          :str
  ffi_func :sp_vips_find_load_buffer, [:str, :size_t], :str
  ffi_func :sp_vips_encoded,          [],              :binstr
  ffi_func :sp_vips_live_images,      [],              :int
end

# The native half of Vips::Image: a GC-managed reference to one VipsImage,
# and the operations on it. Every operation answers a fresh reference,
# which holds no image when libvips refused (`__ok?` false, the reason in
# VipsExt.sp_vips_error); Vips::Image below checks and raises.
# Constructors are an empty `new` plus a `:self` method, the way
# IO::Buffer.for is built.
#
# Its own top-level name, not `Vips::Image`: Spinel keys a native class's
# constant by its last segment, so a native `Vips::Image` would be merged
# with any other `Image` the program has (Campfire has `Sound::Image`),
# and the merged class fails to compile. An ordinary Ruby class is keyed
# by its full path, so Vips::Image is one, holding a VipsImageRef.
module VipsImagePackage
  native_struct "VipsImageRef", "sp_VipsImage", "sp_VipsImage_fin"
  native_new [], "sp_VipsImage_new"

  native_method :__ok?,              [], :bool,                          "sp_VipsImage_ok_p"
  native_method :__load_buffer,      [:string, :string], :self,          "sp_VipsImage_load_buffer"
  native_method :__load_file,        [:string], :self,                   "sp_VipsImage_load_file"
  native_method :__load_op,          [:string, :string], :self,          "sp_VipsImage_load_op"
  native_method :__thumbnail_buffer, [:string, :int, :int, :int], :self, "sp_VipsImage_thumbnail_buffer"
  native_method :__thumbnail_image,  [:int, :int, :int], :self,          "sp_VipsImage_thumbnail_image"
  native_method :__black,            [:int, :int], :self,                "sp_VipsImage_black"
  native_method :__add_const,        [:float], :self,                    "sp_VipsImage_add_const"
  native_method :__cast,             [:int], :self,                      "sp_VipsImage_cast"
  native_method :__format,           [], :int,                           "sp_VipsImage_format"
  native_method :__encode,           [:string], :int,                    "sp_VipsImage_encode"
  native_method :__write_to_file,    [:string], :int,                    "sp_VipsImage_write_to_file"
  native_method :width,              [], :int,                           "sp_VipsImage_width"
  native_method :height,             [], :int,                           "sp_VipsImage_height"
  native_method :bands,              [], :int,                           "sp_VipsImage_bands"
  native_method :has_alpha?,         [], :bool,                          "sp_VipsImage_has_alpha_p"
end

module Vips
  # The gem's error: the message is libvips' own error text, trailing
  # newline and all (callers `chomp` it, and match it line by line).
  class Error < StandardError
  end

  # The gem's Vips::LIBRARY_VERSION: the linked libvips, e.g. "8.18.4".
  LIBRARY_VERSION = VipsExt.sp_vips_version

  # VipsBandFormat, in enum order, spelled as the gem spells formats.
  BAND_FORMATS = %w[uchar char ushort short uint int float complex double dpcomplex]

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

  def self.band_format_code(format)
    code = BAND_FORMATS.index(format.to_s)
    raise Error, "cast: no band format \"#{format}\"\n" if code.nil?
    code
  end
end

module Vips
  class Image
    # Wraps an operation's answer, or raises Vips::Error with libvips'
    # reason.
    def self.checked(ref)
      raise Vips::Error, VipsExt.sp_vips_error unless ref.__ok?
      Image.new(ref)
    end

    def initialize(ref)
      @ref = ref
    end

    def width
      @ref.width
    end

    def height
      @ref.height
    end

    def bands
      @ref.bands
    end

    def has_alpha?
      @ref.has_alpha?
    end

    # The gem's `new_from_buffer(data, option_string)`: the loader is
    # chosen from the bytes, and the option string ("[shrink=2]", or ""
    # for none) goes to it.
    def self.new_from_buffer(bytes, option_string = "")
      checked(VipsImageRef.new.__load_buffer(bytes, option_string))
    end

    def self.new_from_file(path)
      checked(VipsImageRef.new.__load_file(path))
    end

    # vips_thumbnail: fit within width x height (height unconstrained
    # when omitted). `size: :down` never enlarges, which is what
    # image_processing's resize_to_limit asks for. As in the gem, the
    # answer is a sequential pipeline: it can be written once.
    def self.thumbnail_buffer(bytes, width, height: 0, size: :both)
      checked(VipsImageRef.new.__thumbnail_buffer(bytes, width, height, Vips.size_code(size)))
    end

    def thumbnail_image(width, height: 0, size: :both)
      Image.checked(@ref.__thumbnail_image(width, height, Vips.size_code(size)))
    end

    # One band of zeros, uchar: the gem's way to make an image in code.
    def self.black(width, height)
      checked(VipsImageRef.new.__black(width, height))
    end

    # The gem's Image#add with a number: an image of that constant, then
    # the `add` operation, so uchar + uchar answers ushort. (Image#+ with a
    # number is `linear` in the gem, which answers float; not provided.)
    def add(value)
      Image.checked(@ref.__add_const(value.to_f))
    end

    def cast(format)
      Image.checked(@ref.__cast(Vips.band_format_code(format)))
    end

    # The gem answers the band format as a Symbol: :uchar, :ushort, ...
    def format
      Vips::BAND_FORMATS[@ref.__format].to_sym
    end

    # The gem's Image#size: [width, height].
    def size
      [width, height]
    end

    # Encode to the format the suffix names, with libvips' own option
    # syntax: ".png", ".webp[Q=80]", ".jpg[strip]". Binary-safe.
    def write_to_buffer(suffix)
      raise Vips::Error, VipsExt.sp_vips_error if @ref.__encode(suffix) < 0
      VipsExt.sp_vips_encoded
    end

    # The format is taken from the path's extension, as vips does.
    def write_to_file(path)
      raise Vips::Error, VipsExt.sp_vips_error if @ref.__write_to_file(path) == 0
      nil
    end

    # The file loaders, by operation name: what the gem reaches through
    # introspection (`Vips::Image.openslideload(path)`, or `public_send`
    # with the name). Each is called directly rather than through
    # new_from_file's sniffing, so a blocked loader answers libvips'
    # "<name>: operation is blocked" and one this libvips was built
    # without answers its "class not found". These are the loaders whose
    # only required argument is the filename; `rawload` also needs the
    # geometry and is not here.
    def self.analyzeload(filename) = checked(VipsImageRef.new.__load_op("analyzeload", filename))
    def self.csvload(filename) = checked(VipsImageRef.new.__load_op("csvload", filename))
    def self.dcrawload(filename) = checked(VipsImageRef.new.__load_op("dcrawload", filename))
    def self.fitsload(filename) = checked(VipsImageRef.new.__load_op("fitsload", filename))
    def self.gifload(filename) = checked(VipsImageRef.new.__load_op("gifload", filename))
    def self.heifload(filename) = checked(VipsImageRef.new.__load_op("heifload", filename))
    def self.jp2kload(filename) = checked(VipsImageRef.new.__load_op("jp2kload", filename))
    def self.jpegload(filename) = checked(VipsImageRef.new.__load_op("jpegload", filename))
    def self.jxlload(filename) = checked(VipsImageRef.new.__load_op("jxlload", filename))
    def self.magickload(filename) = checked(VipsImageRef.new.__load_op("magickload", filename))
    def self.matload(filename) = checked(VipsImageRef.new.__load_op("matload", filename))
    def self.matrixload(filename) = checked(VipsImageRef.new.__load_op("matrixload", filename))
    def self.niftiload(filename) = checked(VipsImageRef.new.__load_op("niftiload", filename))
    def self.openexrload(filename) = checked(VipsImageRef.new.__load_op("openexrload", filename))
    def self.openslideload(filename) = checked(VipsImageRef.new.__load_op("openslideload", filename))
    def self.pdfload(filename) = checked(VipsImageRef.new.__load_op("pdfload", filename))
    def self.pngload(filename) = checked(VipsImageRef.new.__load_op("pngload", filename))
    def self.ppmload(filename) = checked(VipsImageRef.new.__load_op("ppmload", filename))
    def self.radload(filename) = checked(VipsImageRef.new.__load_op("radload", filename))
    def self.svgload(filename) = checked(VipsImageRef.new.__load_op("svgload", filename))
    def self.tiffload(filename) = checked(VipsImageRef.new.__load_op("tiffload", filename))
    def self.uhdrload(filename) = checked(VipsImageRef.new.__load_op("uhdrload", filename))
    def self.vipsload(filename) = checked(VipsImageRef.new.__load_op("vipsload", filename))
    def self.webpload(filename) = checked(VipsImageRef.new.__load_op("webpload", filename))
  end
end
