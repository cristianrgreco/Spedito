# StoryPointless workspace notes

## Validate changes

Run the full suite with the project-local module caches:

```sh
env \
  SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache" \
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
  swift test -Xswiftc -warnings-as-errors
```

## Relaunch the development app

Use `./scripts/relaunch.sh`. It builds, kills any existing debug
`StoryPointless` process, and `exec`s the new binary in the foreground. When
called from an agent command, keep the returned command session alive.

This is deliberately a simple development-only reset. Do not use it while
preserving an active agent turn matters; normal user-initiated app quit still
uses the asynchronous shutdown handler.
