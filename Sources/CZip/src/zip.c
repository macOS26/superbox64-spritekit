#include "Zip.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
    const void* zip_data;
    size_t zip_size;
    size_t cd_offset;
    uint32_t cd_count;
} ZipArchiveImpl;

typedef struct {
    const void* data;
    size_t size;
    size_t pos;
} ZipFileImpl;

static uint16_t read_u16(const uint8_t* p) {
    uint16_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static uint32_t read_u32(const uint8_t* p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static int find_central_directory(ZipArchiveImpl* impl) {
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    if (impl->zip_size < 22) return -1;

    size_t max_back = 22 + 65535;
    if (max_back > impl->zip_size) max_back = impl->zip_size;

    for (size_t back = 22; back <= max_back; back++) {
        size_t pos = impl->zip_size - back;
        if (read_u32(data + pos) != 0x06054b50) continue;
        impl->cd_count = read_u16(data + pos + 10);
        impl->cd_offset = read_u32(data + pos + 16);
        if (impl->cd_offset >= impl->zip_size) return -1;
        return 0;
    }
    return -1;
}

static const uint8_t* central_entry_next(const ZipArchiveImpl* impl, const uint8_t* entry) {
    return entry + 46 + read_u16(entry + 28) + read_u16(entry + 30) + read_u16(entry + 32);
}

static const uint8_t* central_entry_at(const ZipArchiveImpl* impl, uint32_t index) {
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    const uint8_t* end = data + impl->zip_size;
    const uint8_t* entry = data + impl->cd_offset;

    for (uint32_t i = 0; i < impl->cd_count; i++) {
        if (entry + 46 > end) return NULL;
        if (read_u32(entry) != 0x02014b50) return NULL;
        if (i == index) return entry;
        entry = central_entry_next(impl, entry);
    }
    return NULL;
}

static const uint8_t* central_entry_by_name(const ZipArchiveImpl* impl, const char* name, int* index_out) {
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    const uint8_t* end = data + impl->zip_size;
    const uint8_t* entry = data + impl->cd_offset;
    size_t name_len = strlen(name);

    for (uint32_t i = 0; i < impl->cd_count; i++) {
        if (entry + 46 > end) return NULL;
        if (read_u32(entry) != 0x02014b50) return NULL;
        uint16_t fname_len = read_u16(entry + 28);
        if (fname_len == name_len && memcmp(entry + 46, name, name_len) == 0) {
            if (index_out) *index_out = (int)i;
            return entry;
        }
        entry = central_entry_next(impl, entry);
    }
    return NULL;
}

ZipArchive* zip_open(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);

    void* data = malloc(size);
    if (!data) {
        fclose(f);
        return NULL;
    }

    if (fread(data, 1, size, f) != size) {
        free(data);
        fclose(f);
        return NULL;
    }
    fclose(f);

    ZipArchive* archive = zip_open_mem(data, size);
    if (!archive) free(data);
    return archive;
}

ZipArchive* zip_open_mem(const void* data, size_t size) {
    if (!data || size < 22) return NULL;

    ZipArchiveImpl* impl = malloc(sizeof(ZipArchiveImpl));
    if (!impl) return NULL;

    impl->zip_data = data;
    impl->zip_size = size;

    if (find_central_directory(impl) != 0) {
        free(impl);
        return NULL;
    }

    return (ZipArchive*)impl;
}

void zip_close(ZipArchive* archive) {
    if (!archive) return;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    free((void*)impl->zip_data);
    free(impl);
}

ZipFile* zip_fopen(ZipArchive* archive, const char* name) {
    if (!archive || !name) return NULL;

    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    const uint8_t* entry = central_entry_by_name(impl, name, NULL);
    if (!entry) return NULL;

    const uint8_t* data = (const uint8_t*)impl->zip_data;
    uint16_t method = read_u16(entry + 10);
    uint32_t compressed_size = read_u32(entry + 20);
    uint32_t uncompressed_size = read_u32(entry + 24);
    size_t local_offset = read_u32(entry + 42);

    if (local_offset + 30 > impl->zip_size) return NULL;
    if (read_u32(data + local_offset) != 0x04034b50) return NULL;

    uint16_t local_fname_len = read_u16(data + local_offset + 26);
    uint16_t local_extra_len = read_u16(data + local_offset + 28);
    size_t data_start = local_offset + 30 + local_fname_len + local_extra_len;
    if (data_start + compressed_size > impl->zip_size) return NULL;

    const uint8_t* compressed_data = data + data_start;

    ZipFileImpl* file = malloc(sizeof(ZipFileImpl));
    if (!file) return NULL;

    uint8_t* out = malloc(uncompressed_size ? uncompressed_size : 1);
    if (!out) {
        free(file);
        return NULL;
    }

    if (method == 0) {
        memcpy(out, compressed_data, uncompressed_size);
    } else if (method == 8) {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        stream.next_in = (uint8_t*)compressed_data;
        stream.avail_in = compressed_size;
        stream.next_out = out;
        stream.avail_out = uncompressed_size;

        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            free(out);
            free(file);
            return NULL;
        }
        int rc = inflate(&stream, Z_FINISH);
        inflateEnd(&stream);
        if (rc != Z_STREAM_END) {
            free(out);
            free(file);
            return NULL;
        }
    } else {
        free(out);
        free(file);
        return NULL;
    }

    file->data = out;
    file->size = uncompressed_size;
    file->pos = 0;
    return (ZipFile*)file;
}

void zip_fclose(ZipFile* file) {
    if (!file) return;
    ZipFileImpl* impl = (ZipFileImpl*)file;
    free((void*)impl->data);
    free(impl);
}

size_t zip_fread(void* buf, size_t size, ZipFile* file) {
    if (!file) return 0;
    ZipFileImpl* impl = (ZipFileImpl*)file;

    if (impl->pos >= impl->size) return 0;

    size_t remaining = impl->size - impl->pos;
    size_t to_read = size < remaining ? size : remaining;

    memcpy(buf, (const char*)impl->data + impl->pos, to_read);
    impl->pos += to_read;

    return to_read;
}

int zip_feof(ZipFile* file) {
    if (!file) return 1;
    ZipFileImpl* impl = (ZipFileImpl*)file;
    return impl->pos >= impl->size;
}

size_t zip_fget_size(ZipFile* file) {
    if (!file) return 0;
    ZipFileImpl* impl = (ZipFileImpl*)file;
    return impl->size;
}

int zip_locate_file(ZipArchive* archive, const char* name) {
    if (!archive || !name) return -1;

    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    int index = -1;
    if (!central_entry_by_name(impl, name, &index)) return -1;
    return index;
}

int zip_get_current_file_info_name(ZipArchive* archive, char* name_buf, size_t name_buf_size) {
    return -1;
}

size_t zip_get_current_file_info_size(ZipArchive* archive) {
    return 0;
}

uint32_t zip_get_num_files(ZipArchive* archive) {
    if (!archive) return 0;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    return impl->cd_count;
}

int zip_get_file_info(ZipArchive* archive, uint32_t index, char* name_buf, size_t name_buf_size, size_t* size_out) {
    if (!archive || !name_buf || !size_out) return -1;

    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    const uint8_t* entry = central_entry_at(impl, index);
    if (!entry) return -1;

    uint16_t fname_len = read_u16(entry + 28);
    size_t len = fname_len;
    if (len >= name_buf_size) len = name_buf_size - 1;

    memcpy(name_buf, entry + 46, len);
    name_buf[len] = '\0';
    *size_out = read_u32(entry + 24);

    return 0;
}
