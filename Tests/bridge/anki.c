// Add to Anki through the bridge, as the Windows app does it, against scripts/fake-ankiconnect.py
// on 127.0.0.1:8765: opens 感冒 in 他得了感冒，吃不了饭。 and the phrase 明朝实行海禁，闭关锁国。,
// clicks each card's Anki button once the model has answered, and prints the Anki events. The
// requests the stand-in gets are the Mac's, which windows/UiCheck/anki-mac.json keeps for the
// Windows UI check (AnkiCheck.cs). Usage: anki RESOURCES MODEL
//   clang Tests/bridge/anki.c -L.build/release -lLongyanBridge -Wl,-rpath,$PWD/.build/release \
//     -Wl,-rpath,$PWD/Vendor/llama.xcframework/macos-arm64 -o .build/bridge-check/anki
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ly_start(const char *resources, const char *model, void (*cb)(const char *));
int64_t ly_lookup(const char *passage, int32_t start, int32_t end);
void ly_anki_start(void (*cb)(const char *), const char *deck);
void ly_anki_open(int64_t id);
void ly_anki_click(int64_t id);

static int64_t word, phrase;
static char *lastWord, *lastPhrase;

static void later(double s, void (*f)(void *)) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), NULL, f);
}
static void done(void *c) { printf("WORD %s\nPHRASE %s\n", lastWord, lastPhrase); exit(0); }
static void clickPhrase(void *c) { ly_anki_click(phrase); later(25, done); }
static void clickWord(void *c) { ly_anki_click(word); later(3, clickPhrase); }
static void openButtons(void *c) { ly_anki_open(word); ly_anki_open(phrase); later(25, clickWord); }
static void lookups(void *c) {
    word = ly_lookup("他得了感冒，吃不了饭。", 3, 5);
    phrase = ly_lookup("明朝实行海禁，闭关锁国。", 0, 12);
    later(0.05, openButtons);
}
static void ankiEvent(const char *json) { printf("ANKI %s\n", json); }
static void event(const char *json) {
    if (strstr(json, "\"event\":\"ready\"")) { ly_anki_start(ankiEvent, ""); later(1, lookups); return; }
    if (strstr(json, "\"event\":\"failed\"")) { fprintf(stderr, "%s\n", json); exit(1); }
    if (!strstr(json, "\"event\":\"card\"")) return;
    int64_t id = strtoll(strstr(json, "\"id\":") + 5, NULL, 10);
    char **last = id == word ? &lastWord : id == phrase ? &lastPhrase : NULL;
    if (last) { free(*last); *last = strdup(json); }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: anki RESOURCES MODEL\n"); return 2; }
    ly_start(argv[1], argv[2], event);
    dispatch_main();
}
