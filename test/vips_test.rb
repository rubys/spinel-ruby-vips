# Conformance against the ruby-vips gem: every line printed here is a
# fact the gem answers identically (dimensions, byte counts, format
# magic, loader names, error class), so the same file is the oracle —
# `sh oracle/run.sh` runs it under CRuby with the gem (no -I, so
# `require "vips"` resolves to the gem) and diffs against the committed
# snapshot. Encoded bytes are compared by LENGTH and magic, not printed:
# libvips' encoders are deterministic for a given libvips, and the
# length pins the pipeline (shrink-on-load choice, size mode, format)
# without dumping a PNG into a snapshot.
#
# Fixtures: moon.jpg is once-campfire's test fixture (MIT); moon64.png is
# its 64px thumbnail with an alpha band added, made with the gem.
require "vips"

def dir
  File.dirname(__FILE__)
end

def show(label, img)
  puts "#{label}: #{img.width}x#{img.height} bands=#{img.bands} alpha=#{img.has_alpha?} size=#{img.size.inspect}"
end

jpg = File.binread(File.join(dir, "moon.jpg"))
png = File.binread(File.join(dir, "moon64.png"))
puts "jpg bytes: #{jpg.bytesize}"
puts "png bytes: #{png.bytesize}"

# --- header reads: from a buffer, from a file, binary-safe (the PNG has NULs)
show "new_from_buffer jpg", Vips::Image.new_from_buffer(jpg, "")
show "new_from_buffer png", Vips::Image.new_from_buffer(png, "")
show "new_from_file jpg", Vips::Image.new_from_file(File.join(dir, "moon.jpg"))

# --- resize_to_limit shape: thumbnail_buffer with size: :down
t = Vips::Image.thumbnail_buffer(jpg, 512, height: 512, size: :down)
show "thumbnail_buffer 512 down", t
up = Vips::Image.thumbnail_buffer(png, 512, height: 512, size: :down)
show "thumbnail_buffer 512 down (64px source, not enlarged)", up
both = Vips::Image.thumbnail_buffer(png, 128, height: 128)
show "thumbnail_buffer 128 both (enlarged)", both
wide = Vips::Image.thumbnail_buffer(jpg, 100, height: 50, size: :down)
show "thumbnail_buffer 100x50 down (fits within)", wide

# --- encode: format from the suffix, bytes binary-safe. A fresh
# thumbnail per encode: the gem's is a sequential-access pipeline that
# can be read once (a second write raises "out of order read"), and
# that is also image_processing's shape — one pipeline per output.
out_png = t.write_to_buffer(".png")
puts "png out: #{out_png.bytesize} bytes, magic #{out_png[0, 4].bytes.inspect}"
out_webp = Vips::Image.thumbnail_buffer(jpg, 512, height: 512, size: :down).write_to_buffer(".webp")
puts "webp out: #{out_webp.bytesize} bytes, magic #{out_webp[0, 4]} #{out_webp[8, 4]}"
out_jpg = Vips::Image.new_from_buffer(png, "").write_to_buffer(".jpg")
puts "jpg out: #{out_jpg.bytesize} bytes, magic #{out_jpg[0, 2].bytes.inspect}"

# --- the encoded thumbnail reads back at the thumbnail's size
show "re-read png out", Vips::Image.new_from_buffer(out_png, "")
show "re-read webp out", Vips::Image.new_from_buffer(out_webp, "")

# --- thumbnail_image on an image, chained
i = Vips::Image.new_from_buffer(jpg, "")
show "thumbnail_image 200", i.thumbnail_image(200, height: 200, size: :down)
show "thumbnail_image 200 then 50", i.thumbnail_image(200, height: 200, size: :down).thumbnail_image(50, height: 50, size: :down)

# --- write_to_file / round trip
path = File.join(dir, "..", "build", "vips_test_out.webp")
Dir.mkdir(File.join(dir, "..", "build")) unless Dir.exist?(File.join(dir, "..", "build"))
Vips::Image.thumbnail_buffer(jpg, 512, height: 512, size: :down).write_to_file(path)
puts "write_to_file: #{File.size(path)} bytes"
show "read back file", Vips::Image.new_from_file(path)
File.delete(path)

# --- loader selection, by bytes not name
puts "find_load jpg: #{Vips.vips_foreign_find_load(File.join(dir, "moon.jpg"))}"
puts "find_load png: #{Vips.vips_foreign_find_load(File.join(dir, "moon64.png"))}"
puts "find_load_buffer webp: #{Vips.vips_foreign_find_load_buffer(out_webp, out_webp.bytesize)}"
puts "find_load_buffer junk: #{Vips.vips_foreign_find_load_buffer("not an image", 12).inspect}"

# --- errors are Vips::Error
begin
  Vips::Image.new_from_buffer("not an image", "")
  puts "Vips::Error: MISSED"
rescue Vips::Error
  puts "Vips::Error: raised"
end
begin
  Vips::Image.new_from_buffer(png, "").write_to_buffer(".nosuchformat")
  puts "Vips::Error on bad suffix: MISSED"
rescue Vips::Error
  puts "Vips::Error on bad suffix: raised"
end

# --- loader policy: block_untrusted refuses what libvips does not trust
Vips.block_untrusted(true)
Vips.block("VipsForeignLoadOpenslide", true)
show "jpg still loads under block_untrusted", Vips::Image.new_from_buffer(jpg, "")
puts "LIBRARY_VERSION is a version: #{Vips::LIBRARY_VERSION.count(".") == 2}"
