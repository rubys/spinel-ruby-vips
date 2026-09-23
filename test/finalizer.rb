# The finalizer, observed. Not a conformance test -- the gem has no count
# to compare -- so it is named without `_test` and the oracle (which runs
# test/*_test.rb under CRuby) leaves it alone; `spin test` runs it.
#
# Every Vips::Image holds a VipsImage reference that only the GC gives
# back. Five thousand chains of three images each, then a collection: if
# the finalizer never ran, all fifteen thousand would still be counted
# live. Each chain is also encoded now and then, so the references being
# released include ones libvips has actually computed pixels through.
require "vips"

made = 0
5000.times do |i|
  img = Vips::Image.black(32, 32).add(i % 200).cast("uchar")
  made += 3
  img.write_to_buffer(".png") if i % 500 == 0
end
GC.start
live = VipsExt.sp_vips_live_images
puts "made: #{made}"
puts "released after GC: #{live < made / 2}"
