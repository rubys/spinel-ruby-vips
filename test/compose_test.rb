# flatten / resize / insert against the ruby-vips gem, ending with the
# pipeline lobsters' StoryImage#add_logo runs. Pixels are read from a PPM
# encoding (its header carries a date, so only the trailing pixel bytes
# are compared); `sh oracle/run.sh` runs this same file under CRuby with
# the gem.
#
# Fixture: alpha8.png is 8x8 sRGB (200, 100, 50) with alpha rising
# 31, 63, ... 255 left to right, made with the gem.
require "vips"

def dir
  File.dirname(__FILE__)
end

def show(label, img)
  puts "#{label}: #{img.width}x#{img.height} bands=#{img.bands} format=#{img.format.inspect}"
end

# Row y's pixels at the given columns. ".ppm" would widen one
# band to three, so a one-band image goes out as ".pgm".
def row(img, y, cols)
  ppm = img.write_to_buffer(img.bands == 1 ? ".pgm" : ".ppm")
  w = img.width
  b = img.bands
  start = ppm.bytesize - w * img.height * b
  cols.map { |x| (0...b).map { |i| ppm.getbyte(start + (y * w + x) * b + i) }.join(",") }.join(" ")
end

alpha = Vips::Image.new_from_file(File.join(dir, "alpha8.png"))
show "alpha8", alpha

# --- flatten: onto white (what lobsters passes), the default black, a
# single number for every band, and max_alpha
white = alpha.flatten(background: [255, 255, 255])
show "flatten white", white
puts "flatten white row0: #{row(white, 0, [0, 3, 7])}"
black = alpha.flatten
puts "flatten default row0: #{row(black, 0, [0, 3, 7])}"
grey = alpha.flatten(background: 128)
puts "flatten 128 row0: #{row(grey, 0, [0, 3, 7])}"
half = alpha.flatten(background: [255, 255, 255], max_alpha: 510)
puts "flatten max_alpha 510 row0: #{row(half, 0, [0, 7])}"
moon = Vips::Image.new_from_file(File.join(dir, "moon.jpg"))
# libvips takes the last band as alpha whatever the image is, so an RGB
# image has two colour bands left and a 3-vector does not fit -- hence
# lobsters' `if image.bands > 3`
begin
  moon.flatten(background: [255, 255, 255])
  puts "flatten RGB onto a 3-vector: MISSED"
rescue Vips::Error => e
  puts "flatten RGB onto a 3-vector: #{e.message.chomp.inspect}"
end
begin
  alpha.flatten(background: [1, 2])
  puts "flatten with a 2-vector: MISSED"
rescue Vips::Error => e
  puts "flatten with a 2-vector: #{e.message.chomp.inspect}"
end

# --- resize: a scale, a separate vscale, a kernel
logo = Vips::Image.new_from_file(File.join(dir, "moon64.png"))
show "resize 0.5", logo.resize(0.5)
show "resize 0.25 vscale 0.5", logo.resize(0.25, vscale: 0.5)
show "resize 1.5", logo.resize(1.5)
puts "resize 0.5 png bytes: #{logo.resize(0.5).write_to_buffer(".png").bytesize}"
puts "resize 0.5 nearest png bytes: #{logo.resize(0.5, kernel: :nearest).write_to_buffer(".png").bytesize}"

# --- insert: at an offset, expanded with a background, and refused
base = Vips::Image.black(8, 8).add(10).cast("uchar")
dot = Vips::Image.black(2, 2).add(200).cast("uchar")
put = base.insert(dot, 3, 0)
show "insert", put
puts "insert row0: #{row(put, 0, [2, 3, 4, 5])}"
grown = base.insert(dot, 7, 0, expand: true, background: 99)
show "insert expand", grown
puts "insert expand row0: #{row(grown, 0, [6, 7, 8])}"
puts "insert expand row7: #{row(grown, 7, [6, 7, 8])}"
begin
  moon.insert(logo, 0, 0)
  puts "insert 4 bands into 3: MISSED"
rescue Vips::Error => e
  puts "insert 4 bands into 3: #{e.message.chomp.inspect}"
end

# --- StoryImage#add_logo, as lobsters writes it: a 144px RGB logo (the
# touch icon's shape) onto a card image that has an alpha band
touch_icon = logo.flatten(background: [255, 255, 255]).resize(2.25).write_to_buffer(".png")
card = logo.resize(6.25).write_to_buffer(".png")
lobsters_logo = Vips::Image.new_from_buffer(touch_icon, "")
show "logo", lobsters_logo
image = Vips::Image.new_from_buffer(card, "")
image = image.flatten(background: [255, 255, 255]) if image.bands > 3
show "card", image
if lobsters_logo.height > image.height / 5
  lobsters_logo = lobsters_logo.resize((image.height / 5.0) / lobsters_logo.height)
end
show "logo resized", lobsters_logo
combined_image = image.insert(lobsters_logo, 0, image.height - lobsters_logo.height)
show "combined", combined_image
puts "combined png bytes: #{combined_image.write_to_buffer(".png").bytesize}"
