#include "kit_stb.h"
#include <stdlib.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "stb/stb_image.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb/stb_truetype.h"

unsigned char* kit_png_decode(const unsigned char* bytes, int len, int* w, int* h) {
    int comp = 0;
    return stbi_load_from_memory(bytes, len, w, h, &comp, 4);
}

void kit_stb_free(void* p) {
    free(p);
}

void* kit_font_init(const unsigned char* ttf, int len) {
    stbtt_fontinfo* info = malloc(sizeof(stbtt_fontinfo));
    if (!info) return NULL;
    if (!stbtt_InitFont(info, ttf, stbtt_GetFontOffsetForIndex(ttf, 0))) {
        free(info);
        return NULL;
    }
    return info;
}

float kit_font_scale_for_px(void* font, float px) {
    return stbtt_ScaleForMappingEmToPixels((stbtt_fontinfo*)font, px);
}

void kit_font_vmetrics(void* font, int* ascent, int* descent, int* lineGap) {
    stbtt_GetFontVMetrics((stbtt_fontinfo*)font, ascent, descent, lineGap);
}

void kit_font_hmetrics(void* font, int codepoint, int* advance, int* lsb) {
    stbtt_GetCodepointHMetrics((stbtt_fontinfo*)font, codepoint, advance, lsb);
}

int kit_font_kern(void* font, int cp1, int cp2) {
    return stbtt_GetCodepointKernAdvance((stbtt_fontinfo*)font, cp1, cp2);
}

unsigned char* kit_font_glyph_bitmap(void* font, float scale, int codepoint,
                                     int* w, int* h, int* xoff, int* yoff) {
    return stbtt_GetCodepointBitmap((stbtt_fontinfo*)font, scale, scale, codepoint, w, h, xoff, yoff);
}

int kit_font_glyph_index(void* font, int codepoint) {
    return stbtt_FindGlyphIndex((stbtt_fontinfo*)font, codepoint);
}

/* CBDT/CBLC color emoji: each glyph in the strike is a PNG. cmap lookup     */
/* rides stb_truetype; the strike index walks CBLC to find the PNG slice in  */
/* CBDT. Covers indexFormat 1/2/3 and imageFormat 17/18/19 (Noto uses 1+17). */

typedef struct {
    const unsigned char* cmap;
    int cmapFormat;
    const unsigned char* cblc;
    const unsigned char* cbdt;
    const unsigned char* strike;
    int ppem;
} KitEmoji;

static uint16_t kit_rd16(const unsigned char* p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t kit_rd32(const unsigned char* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static const unsigned char* kit_find_table(const unsigned char* ttf, const char tag[4]) {
    uint16_t numTables = kit_rd16(ttf + 4);
    for (uint16_t i = 0; i < numTables; i++) {
        const unsigned char* rec = ttf + 12 + 16 * i;
        if (rec[0] == tag[0] && rec[1] == tag[1] && rec[2] == tag[2] && rec[3] == tag[3]) {
            return ttf + kit_rd32(rec + 8);
        }
    }
    return 0;
}

/* bitmap-only fonts have no glyf table, so stb_truetype refuses them;       */
/* a format 12 (or 4) cmap walk is all the glyph lookup an emoji font needs */
static const unsigned char* kit_pick_cmap(const unsigned char* ttf, int* format) {
    const unsigned char* cmap = kit_find_table(ttf, "cmap");
    if (!cmap) return 0;
    uint16_t numTables = kit_rd16(cmap + 2);
    const unsigned char* best = 0;
    int bestFormat = 0;
    for (uint16_t i = 0; i < numTables; i++) {
        const unsigned char* rec = cmap + 4 + 8 * i;
        const unsigned char* sub = cmap + kit_rd32(rec + 4);
        uint16_t fmt = kit_rd16(sub);
        if (fmt == 12 && bestFormat != 12) { best = sub; bestFormat = 12; }
        if (fmt == 4 && bestFormat == 0) { best = sub; bestFormat = 4; }
    }
    *format = bestFormat;
    return best;
}

static int kit_cmap_lookup(const KitEmoji* e, uint32_t cp) {
    if (!e->cmap) return 0;
    if (e->cmapFormat == 12) {
        uint32_t nGroups = kit_rd32(e->cmap + 12);
        const unsigned char* groups = e->cmap + 16;
        uint32_t lo = 0, hi = nGroups;
        while (lo < hi) {
            uint32_t mid = (lo + hi) / 2;
            const unsigned char* g = groups + 12 * mid;
            uint32_t start = kit_rd32(g);
            uint32_t end = kit_rd32(g + 4);
            if (cp < start) { hi = mid; }
            else if (cp > end) { lo = mid + 1; }
            else { return (int)(kit_rd32(g + 8) + (cp - start)); }
        }
        return 0;
    }
    if (e->cmapFormat == 4 && cp <= 0xFFFF) {
        uint16_t segCountX2 = kit_rd16(e->cmap + 6);
        const unsigned char* endCodes = e->cmap + 14;
        const unsigned char* startCodes = endCodes + segCountX2 + 2;
        const unsigned char* idDeltas = startCodes + segCountX2;
        const unsigned char* idRangeOffsets = idDeltas + segCountX2;
        for (uint16_t i = 0; i < segCountX2; i += 2) {
            if (cp > kit_rd16(endCodes + i)) continue;
            uint16_t start = kit_rd16(startCodes + i);
            if (cp < start) return 0;
            uint16_t rangeOff = kit_rd16(idRangeOffsets + i);
            if (rangeOff == 0) return (int)((cp + kit_rd16(idDeltas + i)) & 0xFFFF);
            const unsigned char* p = idRangeOffsets + i + rangeOff + 2 * (cp - start);
            uint16_t g = kit_rd16(p);
            if (g == 0) return 0;
            return (int)((g + kit_rd16(idDeltas + i)) & 0xFFFF);
        }
    }
    return 0;
}

void* kit_emoji_init(const unsigned char* ttf, int len) {
    KitEmoji* e = malloc(sizeof(KitEmoji));
    if (!e) return 0;
    e->cmap = kit_pick_cmap(ttf, &e->cmapFormat);
    if (!e->cmap) {
        free(e);
        return 0;
    }
    e->cblc = kit_find_table(ttf, "CBLC");
    e->cbdt = kit_find_table(ttf, "CBDT");
    if (!e->cblc || !e->cbdt) {
        free(e);
        return 0;
    }
    uint32_t numSizes = kit_rd32(e->cblc + 4);
    e->strike = 0;
    e->ppem = 0;
    for (uint32_t i = 0; i < numSizes; i++) {
        const unsigned char* s = e->cblc + 8 + 48 * i;
        int ppem = s[44];
        if (ppem > e->ppem) {
            e->ppem = ppem;
            e->strike = s;
        }
    }
    if (!e->strike) {
        free(e);
        return 0;
    }
    return e;
}

const unsigned char* kit_emoji_glyph_png(void* handle, int codepoint, uint32_t* pngLen,
                                         int* ppem, int* bearingX, int* bearingY, int* advance) {
    KitEmoji* e = (KitEmoji*)handle;
    if (!e) return 0;
    int glyph = kit_cmap_lookup(e, (uint32_t)codepoint);
    if (glyph == 0) return 0;

    const unsigned char* s = e->strike;
    uint32_t arrayOff = kit_rd32(s);
    uint32_t numSub = kit_rd32(s + 8);
    const unsigned char* array = e->cblc + arrayOff;

    for (uint32_t i = 0; i < numSub; i++) {
        const unsigned char* rec = array + 8 * i;
        uint16_t first = kit_rd16(rec);
        uint16_t last = kit_rd16(rec + 2);
        if (glyph < first || glyph > last) continue;

        const unsigned char* sub = array + kit_rd32(rec + 4);
        uint16_t indexFormat = kit_rd16(sub);
        uint16_t imageFormat = kit_rd16(sub + 2);
        uint32_t imageDataOffset = kit_rd32(sub + 4);
        uint32_t off = 0;
        uint32_t size = 0;

        if (indexFormat == 1) {
            const unsigned char* offsets = sub + 8;
            uint32_t o1 = kit_rd32(offsets + 4 * (glyph - first));
            uint32_t o2 = kit_rd32(offsets + 4 * (glyph - first + 1));
            off = o1;
            size = o2 - o1;
        } else if (indexFormat == 2) {
            uint32_t imageSize = kit_rd32(sub + 8);
            off = imageSize * (glyph - first);
            size = imageSize;
        } else if (indexFormat == 3) {
            const unsigned char* offsets = sub + 8;
            uint16_t o1 = kit_rd16(offsets + 2 * (glyph - first));
            uint16_t o2 = kit_rd16(offsets + 2 * (glyph - first + 1));
            off = o1;
            size = o2 - o1;
        } else {
            return 0;
        }
        if (size == 0) return 0;

        const unsigned char* data = e->cbdt + imageDataOffset + off;
        *ppem = e->ppem;
        if (imageFormat == 17) {
            *bearingX = (signed char)data[2];
            *bearingY = (signed char)data[3];
            *advance = data[4];
            *pngLen = kit_rd32(data + 5);
            return data + 9;
        } else if (imageFormat == 18) {
            *bearingX = (signed char)data[2];
            *bearingY = (signed char)data[3];
            *advance = data[4];
            *pngLen = kit_rd32(data + 8);
            return data + 12;
        } else if (imageFormat == 19) {
            *bearingX = 0;
            *bearingY = e->ppem;
            *advance = e->ppem;
            *pngLen = kit_rd32(data);
            return data + 4;
        }
        return 0;
    }
    return 0;
}
