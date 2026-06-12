#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

unsigned char* kit_png_decode(const unsigned char* bytes, int len, int* w, int* h);
void kit_stb_free(void* p);

void* kit_font_init(const unsigned char* ttf, int len);
float kit_font_scale_for_px(void* font, float px);
void kit_font_vmetrics(void* font, int* ascent, int* descent, int* lineGap);
void kit_font_hmetrics(void* font, int codepoint, int* advance, int* lsb);
int  kit_font_kern(void* font, int cp1, int cp2);
int  kit_font_glyph_index(void* font, int codepoint);
unsigned char* kit_font_glyph_bitmap(void* font, float scale, int codepoint,
                                     int* w, int* h, int* xoff, int* yoff);

void* kit_emoji_init(const unsigned char* ttf, int len);
const unsigned char* kit_emoji_glyph_png(void* handle, int codepoint, uint32_t* pngLen,
                                         int* ppem, int* bearingX, int* bearingY, int* advance);

#ifdef __cplusplus
}
#endif
