#include <tag_c.h>

static inline BOOL cum_set_picture(TagLib_File *f, const char *data, unsigned int size, const char *mime) {
  TAGLIB_COMPLEX_PROPERTY_PICTURE(pic, data, size, "", mime, "Front Cover");
  return taglib_complex_property_set(f, "PICTURE", pic);
}
