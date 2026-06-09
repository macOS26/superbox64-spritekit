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
// NOTE: no swift_conformsToProtocol stub on purpose. Embedded has no runtime
// conformance lookup, so a stub would make `as? Protocol` casts compile and
// silently return nil at runtime (a hidden gameplay bug). Without it, any new
// protocol cast fails loudly at link time; use a concrete class downcast or
// base-class dispatch instead.
// WASI reactor init the runtime calls before boot(): run wasi-libc's global
// ctors (init_array). Embedded bare-metal Swift doesn't synthesize _initialize.
extern void __wasm_call_ctors(void);
void _initialize(void) { __wasm_call_ctors(); }
