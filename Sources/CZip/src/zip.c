#include "Zip.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define MZ_MALLOC malloc
#define MZ_FREE free
#define MZ_MEMCPY memcpy
#define MZ_MEMSET memset

typedef struct {
    z_stream stream;
    const void* zip_data;
    size_t zip_size;
    size_t read_pos;
} ZipArchiveImpl;

typedef struct {
    const void* data;
    size_t size;
    size_t pos;
} ZipFileImpl;

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

    return zip_open_mem(data, size);
}

ZipArchive* zip_open_mem(const void* data, size_t size) {
    if (!data || size < 22) return NULL;

    ZipArchiveImpl* impl = malloc(sizeof(ZipArchiveImpl));
    if (!impl) return NULL;

    impl->zip_data = data;
    impl->zip_size = size;
    impl->read_pos = 0;
    memset(&impl->stream, 0, sizeof(z_stream));

    return (ZipArchive*)impl;
}

void zip_close(ZipArchive* archive) {
    if (!archive) return;
    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    if (impl->stream.state) inflateEnd(&impl->stream);
    free((void*)impl->zip_data);
    free(impl);
}

ZipFile* zip_fopen(ZipArchive* archive, const char* name) {
    if (!archive || !name) return NULL;

    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    size_t name_len = strlen(name);

    const uint8_t* data = (const uint8_t*)impl->zip_data;
    size_t pos = 0;

    while (pos + 30 < impl->zip_size) {
        if (*(uint32_t*)(data + pos) != 0x04034b50) {
            pos++;
            continue;
        }

        uint16_t fname_len = *(uint16_t*)(data + pos + 26);
        uint16_t extra_len = *(uint16_t*)(data + pos + 28);
        uint32_t compressed_size = *(uint32_t*)(data + pos + 18);
        uint32_t uncompressed_size = *(uint32_t*)(data + pos + 22);
        uint8_t compression = *(uint8_t*)(data + pos + 8);

        const char* entry_name = (const char*)(data + pos + 30);

        if (fname_len == name_len && memcmp(entry_name, name, name_len) == 0) {
            ZipFileImpl* file = malloc(sizeof(ZipFileImpl));
            if (!file) return NULL;

            const uint8_t* compressed_data = data + pos + 30 + fname_len + extra_len;

            if (compression == 0) {
                file->data = compressed_data;
                file->size = uncompressed_size;
            } else if (compression == 8) {
                uint8_t* decompressed = malloc(uncompressed_size);
                if (!decompressed) {
                    free(file);
                    return NULL;
                }

                z_stream stream;
                memset(&stream, 0, sizeof(stream));
                stream.next_in = (uint8_t*)compressed_data;
                stream.avail_in = compressed_size;
                stream.next_out = decompressed;
                stream.avail_out = uncompressed_size;

                if (inflateInit2(&stream, -MAX_WBITS) != Z_OK ||
                    inflate(&stream, Z_FINISH) != Z_STREAM_END ||
                    inflateEnd(&stream) != Z_OK) {
                    free(decompressed);
                    free(file);
                    return NULL;
                }

                file->data = decompressed;
                file->size = uncompressed_size;
            } else {
                free(file);
                return NULL;
            }

            file->pos = 0;
            return (ZipFile*)file;
        }

        pos += 30 + fname_len + extra_len + compressed_size;
    }

    return NULL;
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
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    size_t pos = 0;
    int index = 0;

    while (pos + 30 < impl->zip_size) {
        if (*(uint32_t*)(data + pos) != 0x04034b50) {
            pos++;
            continue;
        }

        uint16_t fname_len = *(uint16_t*)(data + pos + 26);
        uint16_t extra_len = *(uint16_t*)(data + pos + 28);
        uint32_t compressed_size = *(uint32_t*)(data + pos + 18);

        const char* entry_name = (const char*)(data + pos + 30);

        if (strcmp(entry_name, name) == 0) {
            return index;
        }

        index++;
        pos += 30 + fname_len + extra_len + compressed_size;
    }

    return -1;
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
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    size_t pos = 0;
    uint32_t count = 0;

    while (pos + 30 < impl->zip_size) {
        if (*(uint32_t*)(data + pos) != 0x04034b50) {
            pos++;
            continue;
        }

        uint16_t fname_len = *(uint16_t*)(data + pos + 26);
        uint16_t extra_len = *(uint16_t*)(data + pos + 28);
        uint32_t compressed_size = *(uint32_t*)(data + pos + 18);

        count++;
        pos += 30 + fname_len + extra_len + compressed_size;
    }

    return count;
}

int zip_get_file_info(ZipArchive* archive, uint32_t index, char* name_buf, size_t name_buf_size, size_t* size_out) {
    if (!archive || !name_buf || !size_out) return -1;

    ZipArchiveImpl* impl = (ZipArchiveImpl*)archive;
    const uint8_t* data = (const uint8_t*)impl->zip_data;
    size_t pos = 0;
    uint32_t current = 0;

    while (pos + 30 < impl->zip_size) {
        if (*(uint32_t*)(data + pos) != 0x04034b50) {
            pos++;
            continue;
        }

        if (current == index) {
            uint16_t fname_len = *(uint16_t*)(data + pos + 26);
            uint16_t extra_len = *(uint16_t*)(data + pos + 28);
            uint32_t uncompressed_size = *(uint32_t*)(data + pos + 22);

            const char* entry_name = (const char*)(data + pos + 30);

            size_t len = fname_len;
            if (len >= name_buf_size) len = name_buf_size - 1;

            strncpy(name_buf, entry_name, len);
            name_buf[len] = '\0';
            *size_out = uncompressed_size;

            return 0;
        }

        uint16_t fname_len = *(uint16_t*)(data + pos + 26);
        uint16_t extra_len = *(uint16_t*)(data + pos + 28);
        uint32_t compressed_size = *(uint32_t*)(data + pos + 18);

        current++;
        pos += 30 + fname_len + extra_len + compressed_size;
    }

    return -1;
}
