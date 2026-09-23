/*
 * Native side of the ruby-vips spin package, over the system libvips.
 *
 * A Vips::Image is a `native_struct`: a GC-managed object holding one live
 * VipsImage reference, allocated with sp_gc_alloc and a finalizer that
 * drops the reference when the collector frees the object. That is the
 * gem's model (a Ruby object per VipsImage, released by the GC), so a
 * chain like `black(8, 8).add(128).cast("uchar")` holds real images, each
 * libvips' own lazy pipeline, and nothing is decoded until it is written.
 *
 * Operations answer a FRESH object. When libvips refuses, the object holds
 * no image (sp_VipsImage_ok_p is false) and the error text has been copied
 * into this thread's buffer; the Ruby side checks and raises Vips::Error
 * with it, as the gem does. A NULL from a `:self` method would be a NULL
 * pointer typed as an Image, so the empty object stands in for it.
 *
 * BYTES THE CALLER HANDS IN ARE COPIED. libvips reads a buffer it was
 * given lazily and does not copy it, and its operation cache can keep a
 * pipeline alive after the call that built it -- so pointing it at a
 * Spinel String's bytes would leave it reading memory the GC may reuse.
 * The bytes go into a VipsBlob (vips_blob_copy) behind a VipsSource, and
 * libvips' own reference counting decides when they are freed.
 *
 * HEADERLESS ON PURPOSE. `spin` compiles carried C with `-I <package>
 * -I <spinel>/lib` and nothing else, and <vips/vips.h> pulls in glib's
 * arch-specific include directories that only pkg-config knows. Every
 * libvips symbol used here is declared below instead: the image, blob and
 * source types are opaque, the rest is int / size_t / double / const char
 * * / varargs, so the declarations are the ABI and need no header to agree
 * with. The varargs calls have to stay in C: an `ffi_func` prototype
 * cannot spell `...`, and on arm64 (Apple) variadic and fixed arguments
 * are passed differently.
 *
 * The finalizer may run on a GC sweeper thread; g_object_unref is safe
 * from any thread, and it neither allocates on the Spinel heap nor calls
 * back into Ruby.
 */

#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spinel/runtime.h" /* sp_gc_alloc, sp_str_byte_len, sp_ffi_bin_len, SP_TLS */

typedef struct _VipsImage VipsImage;
typedef struct _VipsBlob VipsBlob;
typedef struct _VipsSource VipsSource;

int vips_init(const char *argv0);
const char *vips_version_string(void);
const char *vips_error_buffer(void);
void vips_error_clear(void);
void vips_block_untrusted_set(int state);
void vips_operation_block_set(const char *name, int state);
const char *vips_foreign_find_load(const char *filename);
const char *vips_foreign_find_load_buffer(const void *data, size_t size);
VipsBlob *vips_blob_copy(const void *data, size_t length);
void vips_area_unref(void *area);
VipsSource *vips_source_new_from_blob(VipsBlob *blob);
VipsImage *vips_image_new_from_source(VipsSource *source,
				      const char *option_string, ...);
VipsImage *vips_image_new_from_file(const char *name, ...);
VipsImage *vips_image_new_from_image1(VipsImage *image, double c);
int vips_thumbnail_source(VipsSource *source, VipsImage **out, int width, ...);
int vips_thumbnail_image(VipsImage *in, VipsImage **out, int width, ...);
int vips_black(VipsImage **out, int width, int height, ...);
int vips_add(VipsImage *left, VipsImage *right, VipsImage **out, ...);
int vips_cast(VipsImage *in, VipsImage **out, int format, ...);
int vips_call(const char *operation_name, ...);
int vips_image_write_to_buffer(VipsImage *in, const char *suffix,
			       void **buf, size_t *size, ...);
int vips_image_write_to_file(VipsImage *image, const char *name, ...);
int vips_image_get_width(const VipsImage *image);
int vips_image_get_height(const VipsImage *image);
int vips_image_get_bands(const VipsImage *image);
int vips_image_get_format(const VipsImage *image);
int vips_image_hasalpha(VipsImage *image);
void g_object_unref(void *object);
void g_free(void *mem);

/* VipsSize, resample.h: BOTH, UP, DOWN, FORCE. The Ruby side maps the
   gem's :both / :up / :down / :force symbols onto these. */
#define SP_VIPS_SIZE_BOTH 0
#define SP_VIPS_SIZE_FORCE 3

static pthread_once_t sp_vips_once = PTHREAD_ONCE_INIT;
static int sp_vips_init_rc = 0;

static void sp_vips_do_init(void)
{
	sp_vips_init_rc = vips_init("spinel");
}

/* Every entry point starts here. libvips is initialised once per process,
   lazily, so `require "vips"` costs nothing until an image is touched. */
static int sp_vips_ready(void)
{
	pthread_once(&sp_vips_once, sp_vips_do_init);
	return sp_vips_init_rc == 0;
}

/* One per-thread buffer per shape of answer: the last failure's text, and
   the last encode's bytes (the FFI copies them out at the boundary). */
static SP_TLS char sp_vips_err_buf[1024];
static SP_TLS unsigned char *sp_vips_out_buf = NULL;
static SP_TLS size_t sp_vips_out_len = 0;

/* Takes libvips' error text for the failure that just happened, then
   clears it: the buffer accumulates, and a stale message from an earlier
   operation would otherwise be reported as this one's. The copy is kept
   per thread until the Ruby side reads it with sp_vips_error. */
static void sp_vips_fail(void)
{
	const char *e = vips_error_buffer();
	size_t n = e ? strlen(e) : 0;
	if (n >= sizeof(sp_vips_err_buf))
		n = sizeof(sp_vips_err_buf) - 1;
	memcpy(sp_vips_err_buf, e ? e : "", n);
	sp_vips_err_buf[n] = 0;
	vips_error_clear();
}

const char *sp_vips_error(void)
{
	return sp_vips_err_buf;
}

const char *sp_vips_version(void)
{
	if (!sp_vips_ready())
		return "";
	return vips_version_string();
}

void sp_vips_block_untrusted(intptr_t state)
{
	if (sp_vips_ready())
		vips_block_untrusted_set(state ? 1 : 0);
}

void sp_vips_block(const char *name, intptr_t state)
{
	if (sp_vips_ready())
		vips_operation_block_set(name, state ? 1 : 0);
}

/* The loader libvips would pick for a file / a buffer, by its bytes
   (the gem's Vips.vips_foreign_find_load). "" when none does. */
const char *sp_vips_find_load(const char *path)
{
	const char *r;
	if (!sp_vips_ready())
		return "";
	r = vips_foreign_find_load(path);
	return r ? r : "";
}

const char *sp_vips_find_load_buffer(const char *buf, intptr_t len)
{
	const char *r;
	if (!sp_vips_ready())
		return "";
	r = vips_foreign_find_load_buffer(buf, (size_t)len);
	return r ? r : "";
}

/* ---- Vips::Image ------------------------------------------------------ */

/* cls_id first: the compiler stamps the class id into every native object
   (it is how dispatch and #class find the Ruby class). */
typedef struct sp_VipsImage_s {
	sp_int cls_id;
	VipsImage *img;
} sp_VipsImage;

/* How many Vips::Image objects hold an image right now: up when one is
   wrapped, down when the finalizer drops it. Nothing reads it but
   test/finalizer.rb, which is how the release is observed at all -- a
   finalizer that never ran looks exactly like one that did until memory
   runs out. */
static long sp_vips_live = 0;

sp_int sp_vips_live_images(void)
{
	return (sp_int)__atomic_load_n(&sp_vips_live, __ATOMIC_RELAXED);
}

void sp_VipsImage_fin(void *p)
{
	sp_VipsImage *s = (sp_VipsImage *)p;
	if (s && s->img) {
		g_object_unref(s->img);
		s->img = NULL;
		__atomic_sub_fetch(&sp_vips_live, 1, __ATOMIC_RELAXED);
	}
}

sp_VipsImage *sp_VipsImage_new(sp_int cls_id)
{
	sp_VipsImage *s = (sp_VipsImage *)sp_gc_alloc(sizeof(sp_VipsImage),
						      sp_VipsImage_fin, NULL);
	s->cls_id = cls_id;
	s->img = NULL;
	return s;
}

/* A fresh object of the receiver's class, holding `img` (which it now
   owns) -- or no image, with the error recorded, when libvips refused. */
static sp_VipsImage *sp_vips_wrap(sp_int cls_id, VipsImage *img)
{
	sp_VipsImage *s = sp_VipsImage_new(cls_id);
	if (img) {
		s->img = img;
		__atomic_add_fetch(&sp_vips_live, 1, __ATOMIC_RELAXED);
	} else {
		sp_vips_fail();
	}
	return s;
}

sp_bool sp_VipsImage_ok_p(sp_VipsImage *self)
{
	return self->img != NULL;
}

/* A VipsSource over a private copy of the bytes. The source holds the
   blob, and every image loaded from it holds the source, so the copy
   lives exactly as long as something can still read it. */
static VipsSource *sp_vips_source(const char *buf)
{
	size_t len = sp_str_byte_len(buf);
	VipsBlob *blob = vips_blob_copy(buf, len);
	VipsSource *src;
	if (!blob)
		return NULL;
	src = vips_source_new_from_blob(blob);
	vips_area_unref(blob);
	return src;
}

/* The gem's Image.new_from_buffer(data, option_string). */
sp_VipsImage *sp_VipsImage_load_buffer(sp_VipsImage *self, const char *buf,
				       const char *options)
{
	VipsSource *src;
	VipsImage *img = NULL;
	if (sp_vips_ready() && (src = sp_vips_source(buf))) {
		img = vips_image_new_from_source(src, options, NULL);
		g_object_unref(src);
	}
	return sp_vips_wrap(self->cls_id, img);
}

/* The gem's Image.new_from_file(name): libvips picks the loader from the
   file's bytes and reads it lazily. */
sp_VipsImage *sp_VipsImage_load_file(sp_VipsImage *self, const char *path)
{
	VipsImage *img = NULL;
	if (sp_vips_ready())
		img = vips_image_new_from_file(path, NULL);
	return sp_vips_wrap(self->cls_id, img);
}

/* One named loader, called directly: Image.jpegload(filename),
   Image.openslideload(filename), ... The gem reaches these through
   GObject introspection; here the Ruby side declares each name and they
   all come through vips_call, which builds the operation by name -- so a
   blocked loader answers libvips' own "<name>: operation is blocked" and
   an absent one "VipsOperation: class "<name>" not found". */
sp_VipsImage *sp_VipsImage_load_op(sp_VipsImage *self, const char *op,
				   const char *path)
{
	VipsImage *img = NULL;
	if (sp_vips_ready() && vips_call(op, path, &img, NULL))
		img = NULL;
	return sp_vips_wrap(self->cls_id, img);
}

/* vips_thumbnail_source with the gem's keyword surface: width, an optional
   height (0 = unconstrained, libvips' own default of a very large number),
   and a VipsSize. Shrink-on-load, auto-rotation from EXIF and colour
   management are libvips' defaults and stay so. */
sp_VipsImage *sp_VipsImage_thumbnail_buffer(sp_VipsImage *self,
					    const char *buf, sp_int w,
					    sp_int h, sp_int size)
{
	VipsSource *src;
	VipsImage *img = NULL;
	int rc = -1;
	if (size < SP_VIPS_SIZE_BOTH || size > SP_VIPS_SIZE_FORCE)
		size = SP_VIPS_SIZE_BOTH;
	if (sp_vips_ready() && (src = sp_vips_source(buf))) {
		if (h > 0)
			rc = vips_thumbnail_source(src, &img, (int)w, "height",
						   (int)h, "size", (int)size,
						   NULL);
		else
			rc = vips_thumbnail_source(src, &img, (int)w, "size",
						   (int)size, NULL);
		g_object_unref(src);
	}
	return sp_vips_wrap(self->cls_id, rc ? NULL : img);
}

sp_VipsImage *sp_VipsImage_thumbnail_image(sp_VipsImage *self, sp_int w,
					   sp_int h, sp_int size)
{
	VipsImage *img = NULL;
	int rc;
	if (size < SP_VIPS_SIZE_BOTH || size > SP_VIPS_SIZE_FORCE)
		size = SP_VIPS_SIZE_BOTH;
	if (h > 0)
		rc = vips_thumbnail_image(self->img, &img, (int)w, "height",
					  (int)h, "size", (int)size, NULL);
	else
		rc = vips_thumbnail_image(self->img, &img, (int)w, "size",
					  (int)size, NULL);
	return sp_vips_wrap(self->cls_id, rc ? NULL : img);
}

/* The gem's Image.black(width, height): one band of zeros, uchar. */
sp_VipsImage *sp_VipsImage_black(sp_VipsImage *self, sp_int w, sp_int h)
{
	VipsImage *img = NULL;
	if (sp_vips_ready() && vips_black(&img, (int)w, (int)h, NULL))
		img = NULL;
	return sp_vips_wrap(self->cls_id, img);
}

/* The gem's Image#add with a number: the gem turns the constant into an
   image matching the receiver (same size, bands and format) and runs the
   `add` operation, so uchar + uchar answers ushort, as libvips' add
   promotes. (Image#+ with a number is `linear` instead, which answers
   float -- a different operation, not provided here.) */
sp_VipsImage *sp_VipsImage_add_const(sp_VipsImage *self, double c)
{
	VipsImage *k = vips_image_new_from_image1(self->img, c);
	VipsImage *img = NULL;
	if (!k || vips_add(self->img, k, &img, NULL))
		img = NULL;
	if (k)
		g_object_unref(k);
	return sp_vips_wrap(self->cls_id, img);
}

/* The gem's Image#cast(format); the Ruby side maps the format name onto
   VipsBandFormat. */
sp_VipsImage *sp_VipsImage_cast(sp_VipsImage *self, sp_int format)
{
	VipsImage *img = NULL;
	if (vips_cast(self->img, &img, (int)format, NULL))
		img = NULL;
	return sp_vips_wrap(self->cls_id, img);
}

sp_int sp_VipsImage_width(sp_VipsImage *self)
{
	return vips_image_get_width(self->img);
}

sp_int sp_VipsImage_height(sp_VipsImage *self)
{
	return vips_image_get_height(self->img);
}

sp_int sp_VipsImage_bands(sp_VipsImage *self)
{
	return vips_image_get_bands(self->img);
}

sp_int sp_VipsImage_format(sp_VipsImage *self)
{
	return vips_image_get_format(self->img);
}

sp_bool sp_VipsImage_has_alpha_p(sp_VipsImage *self)
{
	return vips_image_hasalpha(self->img) != 0;
}

/* Encodes to the format `suffix` names (".png", ".webp[Q=80]" -- libvips
   parses the options itself). Decoding happens here: every step before
   this only built the pipeline. The bytes land in this thread's buffer and
   the answer is their count, or -1 (with the error recorded) when libvips
   refuses; sp_vips_encoded then hands them to Ruby.

   TWO CALLS, NOT ONE, because a `native_method` declared `:cbinstr` is
   copied at the call site by strlen, not by sp_ffi_bin_len -- only the
   `native_func` / `ffi_func` paths honour the published length -- so an
   encoded PNG would come back cut at its first NUL. The module-level
   `ffi_func ... :binstr` below does honour it. */
sp_int sp_VipsImage_encode(sp_VipsImage *self, const char *suffix)
{
	void *out = NULL;
	size_t outlen = 0;
	sp_vips_out_len = 0;
	if (vips_image_write_to_buffer(self->img, suffix, &out, &outlen,
				       NULL)) {
		sp_vips_fail();
		return -1;
	}
	/* g_malloc'd memory has to go back through g_free, so it is copied
	   into a malloc'd buffer this file owns, released on this thread's
	   next encode. */
	free(sp_vips_out_buf);
	sp_vips_out_buf = malloc(outlen ? outlen : 1);
	if (!sp_vips_out_buf) {
		g_free(out);
		snprintf(sp_vips_err_buf, sizeof(sp_vips_err_buf),
			 "write_to_buffer: out of memory\n");
		return -1;
	}
	memcpy(sp_vips_out_buf, out, outlen);
	g_free(out);
	sp_vips_out_len = outlen;
	return (sp_int)outlen;
}

/* The last encode's bytes on this thread (:binstr: the length rides
   sp_ffi_bin_len, and the FFI copies exactly that many). */
const char *sp_vips_encoded(void)
{
	sp_ffi_bin_len = (int)sp_vips_out_len;
	return sp_vips_out_buf ? (const char *)sp_vips_out_buf : "";
}

/* 1 on success; 0 with the error recorded. The format comes from the
   name's extension, as in the gem. */
sp_int sp_VipsImage_write_to_file(sp_VipsImage *self, const char *path)
{
	if (vips_image_write_to_file(self->img, path, NULL)) {
		sp_vips_fail();
		return 0;
	}
	return 1;
}
