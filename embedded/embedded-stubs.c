extern double strtod(const char *, char **);
extern float  strtof(const char *, char **);
double _swift_stdlib_strtod_clocale(const char *nptr, char **endptr)  { return strtod(nptr, endptr); }
float  _swift_stdlib_strtof_clocale(const char *nptr, char **endptr)  { return strtof(nptr, endptr); }
double _swift_stdlib_strtold_clocale(const char *nptr, char **endptr) { return strtod(nptr, endptr); }
// Minimal Embedded runtime stub: protocol-conformance lookup. Returning null
// makes class-bound-protocol `as?` casts yield nil (proof-of-boot; the title
// screen doesn't depend on them). A real build would resolve these statically.
void *swift_conformsToProtocol(const void *type, const void *proto) { return 0; }
// WASI reactor init the runtime calls before boot(): run C/C++ global ctors
// (Box2D/libc++). Embedded bare-metal Swift doesn't synthesize _initialize.
extern void __wasm_call_ctors(void);
void _initialize(void) { __wasm_call_ctors(); }
