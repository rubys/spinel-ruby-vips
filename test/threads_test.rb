# The per-thread result buffers under real concurrency: four threads
# thumbnail and encode the same source at once, each checking its own
# bytes against the single-threaded answer. A shared buffer would show
# up as a length or magic mismatch; a missing pthread_once would show up
# as a crash. Under spinel, `Thread` makes this a threaded (SP_THREADS)
# build, which is the shape a server links.
require "vips"

jpg = File.binread(File.join(File.dirname(__FILE__), "moon.jpg"))
reference = Vips::Image.thumbnail_buffer(jpg, 256, height: 256, size: :down).write_to_buffer(".png")
puts "reference: #{reference.bytesize} bytes"

results = []
threads = []
4.times do |i|
  threads << Thread.new do
    ok = 0
    8.times do
      out = Vips::Image.thumbnail_buffer(jpg, 256, height: 256, size: :down).write_to_buffer(".png")
      ok += 1 if out == reference
    end
    ok
  end
end
threads.each { |t| results << t.value }
puts "threads: #{results.inspect}"
