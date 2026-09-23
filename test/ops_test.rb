# The operations beyond thumbnail-and-encode, against the ruby-vips gem:
# building an image in code (black / add / cast, the band formats they
# answer), the file loaders called by name -- directly and through
# public_send, as a loader-policy test calls them -- and the errors, whose
# text is libvips' own. `sh oracle/run.sh` runs this same file under CRuby
# with the gem; every printed line is a fact the two answer identically.
require "vips"

def dir
  File.dirname(__FILE__)
end

# --- an image made in code, and the formats libvips' arithmetic answers
black = Vips::Image.black(8, 8)
puts "black: #{black.width}x#{black.height} bands=#{black.bands} format=#{black.format.inspect}"
sum = black.add(128)
puts "add(128): format=#{sum.format.inspect}"
px = sum.cast("uchar")
puts "cast(uchar): format=#{px.format.inspect}"

# --- the same chain encoded to each format a loader-policy test makes;
# the length pins the pixels as well as the encoder
%w[png gif jpg tif webp].each do |ext|
  bytes = Vips::Image.black(8, 8).add(128).cast("uchar").write_to_buffer(".#{ext}")
  back = Vips::Image.new_from_buffer(bytes, "")
  puts "#{ext}: #{bytes.bytesize} bytes, reads back #{back.width}x#{back.height} bands=#{back.bands}, loader #{Vips.vips_foreign_find_load_buffer(bytes, bytes.bytesize)}"
end

# --- loaders by name
png = Vips::Image.pngload(File.join(dir, "moon64.png"))
puts "pngload: #{png.width}x#{png.height} bands=#{png.bands}"
jpg = Vips::Image.public_send(:jpegload, File.join(dir, "moon.jpg"))
puts "public_send(:jpegload): #{jpg.width}x#{jpg.height} bands=#{jpg.bands}"

# --- errors carry libvips' text: a file that is not there, a blocked
# loader, and a band format libvips has no name for
begin
  Vips::Image.pngload(File.join(dir, "no-such-file.png"))
  puts "pngload of a missing file: MISSED"
rescue Vips::Error => e
  puts "pngload of a missing file: Vips::Error"
end
Vips.block("VipsForeignLoadVips", true)
begin
  Vips::Image.public_send(:vipsload, File.join(dir, "moon.jpg"))
  puts "blocked vipsload: MISSED"
rescue Vips::Error => e
  puts "blocked vipsload: #{e.message.chomp.inspect}"
end
Vips.block("VipsForeignLoadVips", false)
begin
  Vips::Image.black(8, 8).cast("nosuchformat")
  puts "cast to an unknown format: MISSED"
rescue Vips::Error, ArgumentError => e
  puts "cast to an unknown format: raised"
end
