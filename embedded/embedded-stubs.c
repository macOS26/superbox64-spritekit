// Match SwiftShims/RuntimeShims.h exactly: returns the end pointer, writes the
// parsed value through the out-param (NOT a plain strtod that returns the value).
extern double strtod(const char *, char **);
extern float  strtof(const char *, char **);
const char *_swift_stdlib_strtod_clocale(const char *nptr, double *outResult) {
    char *end = 0; *outResult = strtod(nptr, &end); return end;
}
const char *_swift_stdlib_strtof_clocale(const char *nptr, float *outResult) {
    char *end = 0; *outResult = strtof(nptr, &end); return end;
}
const char *_swift_stdlib_strtold_clocale(const char *nptr, void *outResult) {
    char *end = 0; *(double *)outResult = strtod(nptr, &end); return end;
}
// Minimal Embedded runtime stub: protocol-conformance lookup. Returning null
// makes class-bound-protocol `as?` casts yield nil (proof-of-boot; the title
// screen doesn't depend on them). A real build would resolve these statically.
void *swift_conformsToProtocol(const void *type, const void *proto) { return 0; }
// WASI reactor init the runtime calls before boot(): run C/C++ global ctors
// (Box2D/libc++). Embedded bare-metal Swift doesn't synthesize _initialize.
extern void __wasm_call_ctors(void);
void _initialize(void) { __wasm_call_ctors(); }
