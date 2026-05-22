# NLP Engine for macOS

This repository packages the **NLP Engine** — the command-line runtime for the [NLP++](https://github.com/VisualText/nlp-engine) language — built for macOS. It bundles the `nlp.exe` executable, the ICU static libraries it links against, the default `rfb` analyzer data tree, and a small Python wrapper for invoking the engine from scripts.

The binaries here are produced from the [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) source repository and kept in sync automatically by a GitHub Actions workflow that downloads each new upstream release.

## Companion Repositories

The NLP Engine is distributed per platform. Pick the one that matches your OS:

| Platform | Repository |
|----------|------------|
| macOS    | [VisualText/nlp-engine-mac](https://github.com/VisualText/nlp-engine-mac) (this repo)|
| Windows  | [VisualText/nlp-engine-windows](https://github.com/VisualText/nlp-engine-windows) |
| Linux    | [VisualText/nlp-engine-linux](https://github.com/VisualText/nlp-engine-linux) |
| Source   | [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) |

For production use from Python, prefer the [NLPPlus Python package](https://github.com/VisualText/py-package-nlpengine) instead of the simple wrapper shipped here.

## What is NLP++?

NLP++ is a domain-specific programming language for building text analyzers. An *analyzer* is a directory of pass files (`*.nlp`), a sequencing file (`analyzer.seq`), and a knowledge base (`kb/user`). The engine runs the passes in order over input text and emits parse trees, annotations, and arbitrary text output.

Learn more:
- Language and tooling: [VisualText.org](https://visualtext.org)
- VSCode extension: [VisualText for VSCode](https://marketplace.visualstudio.com/items?itemName=dehilster.nlp)
- Source for the engine itself: [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine)

## Repository contents

| Path | Description |
|------|-------------|
| [nlp.exe](nlp.exe) | The macOS NLP Engine executable. Despite the `.exe` extension, this is a native macOS binary (the name is kept consistent across platforms). |
| [libicutum.a](libicutum.a) | ICU translation/transliteration static library that `nlp.exe` is linked against. |
| [libicuucm.a](libicuucm.a) | ICU common static library that `nlp.exe` is linked against. |
| [data/rfb/](data/rfb/) | The default "rfb" analyzer data tree (specs/grammar passes used by the engine at runtime). |
| [data/rfb/spec/](data/rfb/spec/) | NLP++ pass files (`*.nlp`) and `analyzer.seq` defining the default analyzer pipeline. |
| [compile-libs/](compile-libs/) | Headers (`include/Api/`, `include/cs/`) and engine static libraries (`lib/lib{prim,kbm,consh,words,lite}.a` + ICU) used to link a compiled analyzer/KB into a `.dylib`. Populated by the workflow from upstream's `nlpengine-compile-libs-macos.zip`. |
| [scripts/compile-analyzer.sh](scripts/compile-analyzer.sh) | Compile the analyzer's KB into `<analyzer>/bin/kb.dylib`. |
| [python/](python/) | A simple Python wrapper class for invoking `nlp.exe` from scripts. See [python/README.md](python/README.md). |
| [.github/workflows/nlp-engine-build.yml](.github/workflows/nlp-engine-build.yml) | The GitHub Actions workflow that pulls the latest engine release. |

## Installation

1. Download the latest release from the [Releases page](https://github.com/VisualText/nlp-engine-mac/releases), or clone this repository directly.
2. Place `nlp.exe` somewhere on your `PATH` (or remember its absolute path).
3. Make sure it is executable:
   ```bash
   chmod +x nlp.exe
   ```
4. On recent macOS versions, the first run may be blocked by Gatekeeper because the binary is unsigned. Clear the quarantine attribute with:
   ```bash
   xattr -d com.apple.quarantine nlp.exe
   ```
   Or right-click the binary in Finder → **Open** to whitelist it.

The `libicutum.a` and `libicuucm.a` files are provided for users who want to **statically link** the NLP Engine into their own C/C++ projects. They are not needed at runtime — `nlp.exe` already contains the ICU code it needs.

## Quick start

Run the engine on a text file using the bundled `rfb` analyzer:

```bash
./nlp.exe -ANA /path/to/analyzer -WORK /path/to/engine-dir /path/to/input.txt
```

Arguments:
- `-ANA <dir>` — the analyzer directory (must contain `spec/`, `input/`, and `kb/user/` subdirectories).
- `-WORK <dir>` — the engine working directory (where this repo's `data/` lives).
- `<input>` — path to the text file to analyze. Output and log files are written next to the input as `<input>_log/`.
- `-DEV` — optional flag that emits richer developer logs (parse trees per pass, etc.).

For full details on writing analyzers, see the [NLP++ documentation](https://visualtext.org).

## Using from Python

The [python/](python/) folder contains `NLPEngine`, a thin subprocess wrapper for non-production scripting use:

```python
from python.nlpengine import NLPEngine

engine = NLPEngine(engineDir="/path/to/nlp-engine-mac",
                   analyzersDir="/path/to/my/analyzers")
engine.analyzeInput("my-analyzer", "sample.txt", dev=True)
```

For **production** use, prefer the native Python bindings in the [py-package-nlpengine](https://github.com/VisualText/py-package-nlpengine) repository, which avoids the subprocess round-trip.

## Compiling an analyzer's KB to a native dylib

By default `nlp.exe` runs analyzers fully interpreted. With the new `EMBEDED_KB`-enabled engine, the **knowledge base** can be compiled to a native shared library that the engine `dlopen`s at `-COMPILED` time and calls into via a single exported `kb_setup` symbol. (Analyzer pass code itself is still interpreted — upstream removed `ana_gen` in 1999, so there is no compiled-rules path; the engine falls back to interpreted execution for the rules.)

| Script | What it does | Output |
|--------|--------------|--------|
| [scripts/compile-analyzer.sh](scripts/compile-analyzer.sh) | Runs `nlp.exe -COMPILE` (emits `Cc_code.cpp` plus the `Sym*.cpp` / `Con*.cpp` / `Ptr*.cpp` / `St*.cpp` tables under `<analyzer>/kb/`), generates a one-line `kb_setup()` shim, and links everything into a single SHARED library against `compile-libs/`. Only `kb_setup` is exported (`-fvisibility=hidden` everywhere else). | `<analyzer>/bin/kb.dylib` |

Prerequisites: `cmake` ≥ 3.16 and a recent Xcode Command Line Tools install (`xcode-select --install`).

Usage:

```bash
# Compile the bundled rfb analyzer's KB:
./scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt

# Run with the compiled KB (rules stay interpreted, KB is dlopen'd):
./nlp.exe -COMPILED -ANA data/rfb -WORK . data/rfb/input/text.txt
```

What you should see in the `-COMPILED` output for a successful round-trip:

```
[CG: Trying to load compiled KB.]
[Loading compiled kb: data/rfb/bin/kb.dylib]
[Loaded compiled kb library]
[Loading compiled analyzer ...]
[Error: Couldn't load compiled analyzer.]      # expected — no run.dylib exists
[No compiled analyzer; falling back to interpreted.]
... normal parse output ...
```

> **Architecture:** The bundled `nlp.exe` is built for Apple Silicon (`arm64`) only — the compile script sets `CMAKE_OSX_ARCHITECTURES=arm64` to match. Intel Macs are not supported by upstream's macOS build.

The compile-libs come from upstream's `nlpengine-compile-libs-macos.zip` — the release workflow drops them into `compile-libs/{include,lib}/` alongside the runtime binary.

## How updates work

This repository does not build the engine from source — it mirrors binaries from [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine). The workflow at [.github/workflows/nlp-engine-build.yml](.github/workflows/nlp-engine-build.yml) does the following:

1. Triggers on `workflow_dispatch` (manual) or `repository_dispatch` of type `nlp-engine-release` (fired by the upstream repo when it cuts a release).
2. Fetches the latest release metadata from `VisualText/nlp-engine` via the GitHub API.
3. Skips the run if a matching tag already exists locally (unless manually dispatched).
4. Downloads release assets: `nlpengine.zip` (the analyzer data tree), `libicutum.a`, `libicuucm.a`, `nlpm.exe`, and `nlpengine-compile-libs-macos.zip` (headers + engine static libraries for the compile scripts; optional — skipped if absent on a given release).
5. Renames `nlpm.exe` → `nlp.exe`, unzips `nlpengine.zip` into `data/`, extracts `nlpengine-compile-libs-macos.zip` to `compile-libs/`, and removes any previous binaries to avoid stale diffs.
6. Commits the new files, tags the commit with the upstream release tag, and creates a matching GitHub release here.

This keeps the macOS distribution in lock-step with engine versions on Linux and Windows.

## Sister repositories

The same engine is published per-platform:

- [nlp-engine-linux](https://github.com/VisualText/nlp-engine-linux) — Linux build
- [nlp-engine-windows](https://github.com/VisualText/nlp-engine-windows) — Windows build
- [nlp-engine-mac](https://github.com/VisualText/nlp-engine-mac) — **this repository** (macOS build)

## Versioning

Releases of this repository carry the same tag as the upstream `VisualText/nlp-engine` release they were produced from (e.g. `v3.1.9`). The most recent release tag corresponds to the binaries currently checked into `main`.

## License

The NLP Engine and its source are maintained by [VisualText](https://github.com/VisualText). See the source repository [VisualText/nlp-engine](https://github.com/VisualText/nlp-engine) for license terms; redistribution of the binaries in this repository is subject to those same terms.
