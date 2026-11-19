// The reader of the user-side link check's sandbox probe
// (tools/user-link-check.sh, step 2):
//
//   probe read <file>    opens the file and reads its first byte
//   probe list <dir>     opens the directory
//
// It exits 0 when it could, and otherwise prints `<path>: <why>`, the
// system's own message for the error, and exits 1. The check runs it inside
// the sandbox, on files of the SDK, the real toolchain and the repository,
// and requires `Operation not permitted` of each.
//
// The check compiles it into the stage with the staged clang, since the
// sandbox runs no program outside the stage and a copy of a system program
// (`/bin/cat`) is killed when it starts. The Lean toolchain ships no C
// library headers for macOS, so the few functions it calls are declared
// here.
typedef struct __sFILE FILE;
typedef struct _dirdesc DIR;

int printf(const char *, ...);
FILE *fopen(const char *, const char *);
int fgetc(FILE *);
DIR *opendir(const char *);
char *strerror(int);
int strcmp(const char *, const char *);
// `errno`, as the system's `<errno.h>` defines it.
int *__error(void);

int main(int argc, char **argv) {
  if (argc != 3) {
    printf("usage: probe read <file> | probe list <dir>\n");
    return 2;
  }
  const char *path = argv[2];
  if (strcmp(argv[1], "read") == 0) {
    FILE *file = fopen(path, "r");
    if (file != 0 && fgetc(file) >= 0) {
      return 0;
    }
  } else if (strcmp(argv[1], "list") == 0) {
    if (opendir(path) != 0) {
      return 0;
    }
  } else {
    printf("usage: probe read <file> | probe list <dir>\n");
    return 2;
  }
  printf("%s: %s\n", path, strerror(*__error()));
  return 1;
}
