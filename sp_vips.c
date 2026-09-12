/*
 * FFI glue for the ruby-vips spin package: a handful of entry points over
 * the system libvips, each one a whole operation (load -> thumbnail ->
 * encode) so no VipsImage handle ever crosses the FFI boundary. The Ruby
 * side is a value (bytes + dimensions + a pending thumbnail), and every
 * question it asks is answered here from the bytes in one call.
 *
 * HEADERLESS ON PURPOSE. `spin` compiles carried C with `-I <package>
 * -I <spinel>/lib` and nothing else, and <vips/vips.h> pulls in glib's
 * arch-specific include directories that only pkg-config knows. Every
 * libvips symbol used here is declared below instead: VipsImage is opaque,
 * the rest is int / size_t / const char * / varargs, so the declarations
 * are the ABI and need no header to agree with. The varargs calls have to
 * stay in C: an `ffi_func` prototype cannot spell `...`, and on arm64
 * (Apple) variadic and fixed arguments are passed differently.
 *
 * Return contract (sp_crypto's): a `:str` / `:binstr` result is valid
 * until the next call from the same thread, and the FFI copies it into a
 * GC string at the boundary. "" means failure; sp_vips_error() says why.
 */

#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spinel/runtime.h" /* sp_ffi_bin_len (SP_TLS), the :binstr length */

typedef struct _VipsImage VipsImage;

int vips_init(const char *argv0);
const char *vips_version_string(void);
const char *vips_error_buffer(void);
void vips_error_clear(void);
void vips_block_untrusted_set(int state);
void vips_operation_block_set(const char *name, int state);
const char *vips_foreign_find_load(const char *filename);
const char *vips_foreign_find_load_buffer(const void *data, size_t size);
VipsImage *vips_image_new_from_buffer(const void *buf, size_t len,
				      const char *option_string, ...);
int vips_thumbnail_buffer(void *buf, size_t len, VipsImage **out,
			  int width, ...);
int vips_image_write_to_buffer(VipsImage *in, const char *suffix,
			       void **buf, size_t *size, ...);
int vips_image_get_width(const VipsImage *image);
int vips_image_get_height(const VipsImage *image);
int vips_image_get_bands(const VipsImage *image);
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

/* One per-thread result buffer per shape of answer, so the bytes of one
   result survive an unrelated call (a caller holding a thumbnail's bytes
   while asking for the error text). */
static SP_TLS char sp_vips_dims_buf[64];
static SP_TLS char sp_vips_err_buf[1024];
static SP_TLS unsigned char *sp_vips_out_buf = NULL;

/* The libvips error buffer, then cleared: the buffer accumulates, and a
   stale message from an earlier operation would otherwise be reported as
   this one's. The copy is taken because vips_error_clear frees the
   original. */
const char *sp_vips_error(void)
{
	const char *e = vips_error_buffer();
	size_t n = e ? strlen(e) : 0;
	if (n >= sizeof(sp_vips_err_buf))
		n = sizeof(sp_vips_err_buf) - 1;
	memcpy(sp_vips_err_buf, e ? e : "", n);
	sp_vips_err_buf[n] = 0;
	vips_error_clear();
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

/* Loads the header only (libvips is lazy: no pixels are decoded) and
   answers "<width> <height> <bands> <alpha>", or "" if the bytes are not
   an image the (unblocked) loaders recognise. */
const char *sp_vips_dims(const char *buf, intptr_t len)
{
	VipsImage *img;
	if (!sp_vips_ready())
		return "";
	img = vips_image_new_from_buffer(buf, (size_t)len, "", NULL);
	if (!img)
		return "";
	snprintf(sp_vips_dims_buf, sizeof(sp_vips_dims_buf), "%d %d %d %d",
		 vips_image_get_width(img), vips_image_get_height(img),
		 vips_image_get_bands(img), vips_image_hasalpha(img) ? 1 : 0);
	g_object_unref(img);
	return sp_vips_dims_buf;
}

/* vips_thumbnail_buffer with the gem's keyword surface: width, an
   optional height (0 = unconstrained, libvips' own default of a very
   large number), and a VipsSize. Shrink-on-load, auto-rotation from
   EXIF and colour management are libvips' defaults and stay so. */
static VipsImage *sp_vips_thumbnail(const char *buf, intptr_t len,
				    intptr_t w, intptr_t h, intptr_t size)
{
	VipsImage *img = NULL;
	int rc;
	if (size < SP_VIPS_SIZE_BOTH || size > SP_VIPS_SIZE_FORCE)
		size = SP_VIPS_SIZE_BOTH;
	if (h > 0)
		rc = vips_thumbnail_buffer((void *)buf, (size_t)len, &img, (int)w,
					   "height", (int)h, "size", (int)size, NULL);
	else
		rc = vips_thumbnail_buffer((void *)buf, (size_t)len, &img, (int)w,
					   "size", (int)size, NULL);
	return rc ? NULL : img;
}

/* The dimensions a thumbnail WOULD have, without encoding it: the pipeline
   is built and only its header is read. */
const char *sp_vips_thumb_dims(const char *buf, intptr_t len, intptr_t w,
			       intptr_t h, intptr_t size)
{
	VipsImage *img;
	if (!sp_vips_ready())
		return "";
	img = sp_vips_thumbnail(buf, len, w, h, size);
	if (!img)
		return "";
	snprintf(sp_vips_dims_buf, sizeof(sp_vips_dims_buf), "%d %d %d %d",
		 vips_image_get_width(img), vips_image_get_height(img),
		 vips_image_get_bands(img), vips_image_hasalpha(img) ? 1 : 0);
	g_object_unref(img);
	return sp_vips_dims_buf;
}

/* Encodes an image to `suffix` (".png", ".webp[Q=80]" — libvips parses
   the options itself), thumbnailing first when w > 0. The whole
   load -> resize -> encode pipeline runs here in one call, which is what
   image_processing's resize_to_limit + format amounts to. The answer is
   binary (:binstr): the length rides sp_ffi_bin_len, the bytes live in
   this thread's buffer until the next call. */
const char *sp_vips_encode(const char *buf, intptr_t len, intptr_t w,
			   intptr_t h, intptr_t size, const char *suffix)
{
	VipsImage *img;
	void *out = NULL;
	size_t outlen = 0;
	sp_ffi_bin_len = 0;
	if (!sp_vips_ready())
		return "";
	if (w > 0)
		img = sp_vips_thumbnail(buf, len, w, h, size);
	else
		img = vips_image_new_from_buffer(buf, (size_t)len, "", NULL);
	if (!img)
		return "";
	if (vips_image_write_to_buffer(img, suffix, &out, &outlen, NULL)) {
		g_object_unref(img);
		return "";
	}
	g_object_unref(img);
	/* g_malloc'd memory has to go back through g_free, so it is copied
	   into a malloc'd buffer this file owns. The buffer is released on
	   this thread's next encode, not before: the FFI copies the bytes
	   out at the boundary, and (int) is what sp_ffi_bin_len is. */
	free(sp_vips_out_buf);
	sp_vips_out_buf = malloc(outlen ? outlen : 1);
	if (!sp_vips_out_buf) {
		g_free(out);
		return "";
	}
	memcpy(sp_vips_out_buf, out, outlen);
	g_free(out);
	sp_ffi_bin_len = (int)outlen;
	return (const char *)sp_vips_out_buf;
}
