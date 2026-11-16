// The main program of the generated app (tools/make_app.py builds it).
//
// It sets up what tools/run.py sets up for a development run, from inside
// the app, then runs Media Center on Mono in this same process (so macOS
// sees one app with the bundle's name and icon):
//   Contents/Resources/mono/         Mono's runtime (lib/mono/4.5, gac, etc/mono)
//   Contents/Resources/windows/      stands for C:\Windows (ehome: Media Center and our programs)
//   Contents/Resources/registry/     the registry Media Center starts with (what a newer
//                                    app adds is added to a saved one)
//   Contents/Resources/mono.config.in  the library map, with @RES@ for this folder
// What Media Center saves goes to ~/Library/Application Support/<app name>
// (WMC_APP_DATA overrides it, for tests).
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Mono's embedding interface (libmonosgen-2.0). mono_main is not used: it
// works out Mono's folders from the program's own location and falls back
// to the folder Mono was built for, ignoring mono_set_dirs.
typedef struct _MonoDomain MonoDomain;
typedef struct _MonoAssembly MonoAssembly;
enum { MONO_DEBUG_FORMAT_MONO = 1 };
void mono_set_dirs(const char *assembly_dir, const char *config_dir);
void mono_debug_init(int format);
void mono_config_parse(const char *filename);
MonoDomain *mono_jit_init_version(const char *root_domain_name, const char *runtime_version);
void mono_domain_set_config(MonoDomain *domain, const char *base_dir, const char *config_file_name);
MonoAssembly *mono_domain_assembly_open(MonoDomain *domain, const char *name);
int mono_jit_exec(MonoDomain *domain, MonoAssembly *assembly, int argc, char *argv[]);
int mono_environment_exitcode_get(void);

static void die(const char *what, const char *detail) {
    fprintf(stderr, "launcher: %s%s%s\n", what, detail ? ": " : "", detail ? detail : "");
    exit(1);
}

static void join(char *out, const char *a, const char *b) {
    if (snprintf(out, PATH_MAX, "%s/%s", a, b) >= PATH_MAX) die("path too long", a);
}

static void make_dirs(const char *path) {
    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s", path);
    for (char *s = p + 1; *s; s++) {
        if (*s != '/') continue;
        *s = 0;
        mkdir(p, 0755);
        *s = '/';
    }
    if (mkdir(p, 0755) != 0 && errno != EEXIST) die("cannot make folder", path);
}

static char *read_all(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) n = 0;
    fclose(f);
    buf[n] = 0;
    *len = (size_t)n;
    return buf;
}

// The library map with this app's own folder put in for @RES@.
static void write_config(const char *template_path, const char *out_path, const char *res) {
    size_t len;
    char *text = read_all(template_path, &len);
    if (!text) die("missing", template_path);
    size_t cap = len * 2 + 4096, used = 0;
    char *out = malloc(cap);
    for (const char *p = text; *p;) {
        const char *hit = strstr(p, "@RES@");
        size_t n = hit ? (size_t)(hit - p) : strlen(p);
        size_t need = used + n + strlen(res) + 1;
        if (need > cap) out = realloc(out, cap = need * 2);
        memcpy(out + used, p, n);
        used += n;
        if (!hit) break;
        memcpy(out + used, res, strlen(res));
        used += strlen(res);
        p = hit + 5;
    }
    size_t old_len;
    char *old = read_all(out_path, &old_len);
    if (!old || old_len != used || memcmp(old, out, used) != 0) {
        FILE *f = fopen(out_path, "wb");
        if (!f || fwrite(out, 1, used, f) != used) die("cannot write", out_path);
        fclose(f);
    }
    free(old);
    free(out);
    free(text);
}

// Adds what the app's registry has and the saved one lacks (a file type a
// newer version can play, say), keeping everything already there: the saved
// copy holds what Media Center changed.
static void add_missing(const char *from, const char *to) {
    DIR *dir = opendir(from);
    if (!dir) return;
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char src[PATH_MAX], dst[PATH_MAX];
        join(src, from, e->d_name);
        join(dst, to, e->d_name);
        struct stat s, d;
        if (lstat(src, &s) != 0) continue;
        if (lstat(dst, &d) != 0) {
            copyfile(src, dst, NULL, COPYFILE_ALL | (S_ISDIR(s.st_mode) ? COPYFILE_RECURSIVE : 0));
        } else if (S_ISDIR(s.st_mode) && S_ISDIR(d.st_mode)) {
            add_missing(src, dst);
        }
    }
    closedir(dir);
}

// Brings a saved registry up to date with this copy of the app, once per
// copy: the stamp names the app's registry folder (it changes when the app
// is replaced).
static void update_registry(const char *fresh, const char *registry, const char *data) {
    struct stat st;
    if (stat(fresh, &st) != 0) return;
    char stamp[128], stamp_path[PATH_MAX];
    snprintf(stamp, sizeof(stamp), "%llu %llu %ld.%09ld\n", (unsigned long long)st.st_dev, (unsigned long long)st.st_ino,
             (long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec);
    join(stamp_path, data, "registry-stamp");
    size_t len;
    char *old = read_all(stamp_path, &len);
    bool same = old && !strcmp(old, stamp);
    free(old);
    if (same) return;
    add_missing(fresh, registry);
    FILE *f = fopen(stamp_path, "wb");
    if (f) {
        fputs(stamp, f);
        fclose(f);
    }
}

int main(int argc, char *argv[]) {
    char exe[PATH_MAX], real[PATH_MAX], res[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0 || !realpath(exe, real)) die("cannot find myself", NULL);
    char *slash = strrchr(real, '/');                 // .../Contents/MacOS/<name>
    if (!slash) die("odd path", real);
    *slash = 0;
    const char *name = slash + 1;
    char res_path[PATH_MAX];
    snprintf(res_path, sizeof(res_path), "%s/../Resources", real);
    if (!realpath(res_path, res)) die("no Resources folder", real);

    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : "/tmp";
    }
    char data[PATH_MAX], drive[PATH_MAX], user_home[PATH_MAX], registry[PATH_MAX], config[PATH_MAX];
    if (getenv("WMC_APP_DATA")) {
        snprintf(data, sizeof(data), "%s", getenv("WMC_APP_DATA"));
    } else {
        snprintf(data, sizeof(data), "%s/Library/Application Support/%s", home, name);
    }
    join(drive, data, "drive_c");                   // stands for C:\ (registry, settings)
    join(user_home, drive, "home");
    join(registry, drive, "registry");
    make_dirs(user_home);
    struct stat st;
    char fresh[PATH_MAX];
    join(fresh, res, "registry");
    if (stat(registry, &st) != 0) {
        if (copyfile(fresh, registry, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE) != 0)
            die("cannot set up the registry", registry);
    }
    update_registry(fresh, registry, data);
    char template_path[PATH_MAX];
    join(template_path, res, "mono.config.in");
    join(config, data, "mono.config");
    write_config(template_path, config, res);

    char windir[PATH_MAX], ehome[PATH_MAX], program[PATH_MAX], fonts[PATH_MAX];
    join(windir, res, "windows");
    join(ehome, windir, "ehome");
    join(program, ehome, "WmcHost.exe");
    join(fonts, res, "libgdiplus/etc/fonts/fonts.conf");

    setenv("WMC_MEDIA_HOME", home, 0);              // the real Music, Pictures, Movies
    setenv("HOME", user_home, 1);                   // Mono's user registry and Media Center's own files
    setenv("WMC_WINDIR", windir, 1);
    setenv("WMC_DRIVE_C", drive, 1);
    setenv("MONO_REGISTRY_PATH", registry, 1);
    setenv("MONO_IOMAP", "all", 1);                 // "\" as a path separator, as on Windows
    setenv("FONTCONFIG_FILE", fonts, 0);
    if (chdir(ehome) != 0) die("no Media Center folder", ehome);

    char libdir[PATH_MAX], etcdir[PATH_MAX];
    join(libdir, res, "mono/lib");
    join(etcdir, res, "mono/etc");
    mono_set_dirs(libdir, etcdir);
    mono_debug_init(MONO_DEBUG_FORMAT_MONO);       // file and line numbers in reported exceptions
    mono_config_parse(config);
    MonoDomain *domain = mono_jit_init_version("WmcHost", "v4.0.30319");
    if (!domain) die("Mono did not start", libdir);
    mono_domain_set_config(domain, ehome, "WmcHost.exe.config");
    MonoAssembly *assembly = mono_domain_assembly_open(domain, program);
    if (!assembly) die("cannot load", program);
    // Media Center's own options pass through (/nostartupanimation, say);
    // not the process serial number older macOS adds when Finder opens an app.
    char **exec_args = calloc((size_t)argc + 1, sizeof(char *));
    int n = 0;
    exec_args[n++] = program;
    for (int i = 1; i < argc; i++)
        if (strncmp(argv[i], "-psn_", 5) != 0) exec_args[n++] = argv[i];
    mono_jit_exec(domain, assembly, n, exec_args);
    return mono_environment_exitcode_get();
}
