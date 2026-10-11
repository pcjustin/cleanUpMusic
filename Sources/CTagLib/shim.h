#include <tag_c.h>

/* BOOL is int on macOS but imports as Swift's Bool on Windows (windows.h); these return int on both. */

static inline int cum_set_picture(TagLib_File *f, const char *data, unsigned int size, const char *mime) {
  TAGLIB_COMPLEX_PROPERTY_PICTURE(pic, data, size, "", mime, "Front Cover");
  return taglib_complex_property_set(f, "PICTURE", pic) ? 1 : 0;
}

static inline int cum_file_is_valid(const TagLib_File *f) { return taglib_file_is_valid(f) ? 1 : 0; }

static inline int cum_file_save(TagLib_File *f) { return taglib_file_save(f) ? 1 : 0; }
