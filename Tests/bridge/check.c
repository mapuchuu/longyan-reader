// Drives the bridge as an app would, through its C interface, and prints each lookup's last
// card (or hint) as a JSON line: the Mac's output is scripts/bridge-check-expected.txt, which
// the Windows build's own run of the same lookups is compared with (scripts/bridge-check.sh,
// windows/BridgeCheck). Usage: check RESOURCES LOOKUPS [MODEL]
// A fourth column opens that row after the card goes quiet (-2: Show All; -100 - N: picks a
// word card's meaning N). CHECK_FIRST=1
// prints each lookup's first card instead: the card as it opens, before the model answers.
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ly_start(const char *resources, const char *model, void (*cb)(const char *));
int64_t ly_lookup(const char *passage, int32_t start, int32_t end);
void ly_toggle_row(int64_t id, int32_t token);
void ly_toggle_all(int64_t id, int32_t token);
void ly_pick(int64_t id, int32_t token, int32_t sense);

#define MAX 256
static char *passages[MAX];
static int starts[MAX], ends[MAX], expands[MAX], count, expanded;
static int64_t ids[MAX];
static char *last[MAX];
static int64_t events, seen;
static int first;

static int indexOf(const char *json) {
    const char *p = strstr(json, "\"id\":");
    if (!p) return -1;
    int64_t id = strtoll(p + 5, NULL, 10);
    for (int i = 0; i < count; i++) if (ids[i] == id) return i;
    return -1;
}

static void quiet(void *ctx) {
    // Done once two seconds pass with no event; then the rows to open (a fourth column), and
    // the same wait again.
    if (events != seen) { seen = events; dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, quiet); return; }
    if (!expanded) {
        expanded = 1;
        int any = 0;
        for (int i = 0; i < count; i++) if (expands[i] >= 0) { ly_toggle_row(ids[i], expands[i]); any = 1; }
            else if (expands[i] == -2) { ly_toggle_all(ids[i], -1); any = 1; }
            else if (expands[i] <= -100) { ly_pick(ids[i], -1, -100 - expands[i]); any = 1; }
        if (any) { dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, quiet); return; }
    }
    for (int i = 0; i < count; i++) printf("%s\n", last[i] ? last[i] : "{\"missing\":true}");
    exit(0);
}

static void lookups(void *ctx) {
    for (int i = 0; i < count; i++) ids[i] = ly_lookup(passages[i], starts[i], ends[i]);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, quiet);
}

static void callback(const char *json) {
    events++;
    if (strstr(json, "\"event\":\"ready\"")) { fprintf(stderr, "%s\n", json); dispatch_async_f(dispatch_get_main_queue(), NULL, lookups); return; }
    if (strstr(json, "\"event\":\"failed\"")) { fprintf(stderr, "%s\n", json); exit(1); }
    int i = indexOf(json);
    if (i < 0) return;
    if (first && last[i]) return;
    free(last[i]);
    last[i] = strdup(json);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: check RESOURCES LOOKUPS [MODEL]\n"); return 2; }
    FILE *f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    static char line[8192];
    while (count < MAX && fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *a = strchr(line, '\t'); if (!a) continue; *a++ = 0;
        char *b = strchr(a, '\t'); if (!b) continue; *b++ = 0;
        char *c = strchr(b, '\t'); if (c) *c++ = 0;
        passages[count] = strdup(line); starts[count] = atoi(a); ends[count] = atoi(b);
        expands[count] = c ? atoi(c) : -1; count++;
    }
    fclose(f);
    first = getenv("CHECK_FIRST") != NULL;
    ly_start(argv[1], argc > 3 ? argv[3] : NULL, callback);
    dispatch_main();
}
