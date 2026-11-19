// A decoy of the user-side link check (tools/user-link-check.sh): a program
// the check puts first on the build's `PATH` under the name of a developer
// tool (`xcrun`, `cc`, `ld`, `git` and the rest). Run, it appends the name
// it was run under and its arguments, one line, to the decoy log, and exits
// 1. So a build that reaches for a developer tool by name fails, and the
// log says which.
//
// The log's path is compiled in: `-DDECOY_LOG="<path>"`. The check compiles
// it into the stage with the staged clang: a shell script would need
// `/bin/sh`, and the sandbox runs no program outside the stage. The Lean
// toolchain ships no C library headers for macOS, so the few functions it
// calls are declared here.
typedef struct __sFILE FILE;

FILE *fopen(const char *, const char *);
int fputs(const char *, FILE *);
int fclose(FILE *);
char *strrchr(const char *, int);

int main(int argc, char **argv) {
  FILE *log = fopen(DECOY_LOG, "a");
  if (log == 0) {
    return 2;
  }
  const char *slash = strrchr(argv[0], '/');
  fputs(slash != 0 ? slash + 1 : argv[0], log);
  for (int index = 1; index < argc; index += 1) {
    fputs(" ", log);
    fputs(argv[index], log);
  }
  fputs("\n", log);
  fclose(log);
  return 1;
}
