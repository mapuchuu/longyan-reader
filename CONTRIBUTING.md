# Contributing

Thanks for helping. Issues and pull requests are both welcome.

## Reporting a wrong meaning

This is the most useful report. Choose **Report a Problem** in the app's menu, or open a [wrong meaning issue](https://github.com/mapuchuu/longyan-reader/issues/new?template=wrong-meaning.yml). Paste the whole sentence and the word you looked up: most wrong meanings can only be fixed with the sentence.

## Building

You need the Xcode Command Line Tools with the macOS 26 SDK. Full Xcode isn't required.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

[DEVELOPMENT.md](DEVELOPMENT.md) explains how a lookup works, the model, the dictionary and the tests.

## Before you open a pull request

- Run `.build/release/LongyanReader --check-data`. It checks that every note, example and cue still matches a dictionary sense.
- If you changed how meanings are picked, run `scripts/evals.sh`. It fails on fewer right answers, more wrong notes, or anything more than 15% slower.
- Keep the change to one thing, and say in the pull request how you checked it.

## Writing notes

Notes are one or two short, plain sentences under a meaning. Read [notes/style.md](notes/style.md) first, and add them in batches with `scripts/notes-batch.sh` (see the Notes section of DEVELOPMENT.md).

## License

Code you contribute is under the MIT license. Notes, examples and other files derived from CC-CEDICT are under CC BY-SA 4.0, like the dictionary.
