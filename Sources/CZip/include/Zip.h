#ifndef ZIP_H
#define ZIP_H

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZipArchive ZipArchive;
typedef struct ZipFile ZipFile;

ZipArchive* zip_open(const char* path);
ZipArchive* zip_open_mem(const void* data, size_t size);
void zip_close(ZipArchive* archive);

ZipFile* zip_fopen(ZipArchive* archive, const char* name);
void zip_fclose(ZipFile* file);
size_t zip_fread(void* buf, size_t size, ZipFile* file);
int zip_feof(ZipFile* file);

int zip_locate_file(ZipArchive* archive, const char* name);
int zip_get_current_file_info_name(ZipArchive* archive, char* name_buf, size_t name_buf_size);
size_t zip_get_current_file_info_size(ZipArchive* archive);

uint32_t zip_get_num_files(ZipArchive* archive);
int zip_get_file_info(ZipArchive* archive, uint32_t index, char* name_buf, size_t name_buf_size, size_t* size_out);

#ifdef __cplusplus
}
#endif

#endif // ZIP_H
