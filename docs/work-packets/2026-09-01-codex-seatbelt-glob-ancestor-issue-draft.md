# Draft upstream issue for openai/codex (do not file without Cristian's go-ahead)

**Title:** macOS Seatbelt: a `**/`-prefixed deny glob makes every directory
undeletable (`file-write-unlink` denied for all directories)

**Body:**

Since #39623 ("Prevent protected-path rename bypasses in macOS Seatbelt",
first shipped around 0.145), `build_seatbelt_unreadable_glob_policy` in
`codex-rs/sandboxing/src/seatbelt.rs` emits, for every unreadable glob, a
directory-unlink deny for each **ancestor** of the glob pattern:

```rust
for ancestor in Path::new(&pattern).ancestors().skip(1) {
    // …
    policy_components.push(format!(
        r#"(deny file-write-unlink (require-all (vnode-type DIRECTORY) (regex #"{regex}")))"#
    ));
}
```

For a workspace-relative pattern such as `**/.env`, the ancestor chain is
`["**", ""]`, and `seatbelt_regex_for_glob("**", Exact)` compiles `**` to
`.*`, producing:

```
(deny file-write-unlink (require-all (vnode-type DIRECTORY) (regex #"^.*$")))
```

i.e. the sandboxed process can create files and directories but can never
remove any directory. `rm -rf` of a directory the same sandbox just created
fails with `Operation not permitted` on every directory while the files
inside unlink fine. Ordinary build patterns break: `mktemp -d` +
`rm -rf "$dir"` cleanup traps, xcodebuild replacing `.xcresult` staging
directories, rebuild-into-`.demo` flows.

**Repro (codex-cli 0.149.0-alpha.4.1, macOS 26.3.1):**

1. Define a permission profile whose filesystem map contains a writable
   workspace root plus `"**/.env" = "deny"`.
2. `command/exec` (or any sandboxed exec) in that profile:
   `sh -c 'mkdir -p a/b && touch a/b/f && rm -rf a'`
3. `rm` deletes `a/b/f`, then fails `rm: a/b: Operation not permitted`,
   `rm: a: Operation not permitted`. The kernel logs
   `Sandbox: rm(<pid>) deny(1) file-write-unlink <path>` for each directory.

Versions 0.144.x (before the ancestor rule) behave correctly. The code is
unchanged on `main` as of 2026-09-01.

**Suggested fix:** stop emitting ancestor protections at or after the first
glob component — only the static prefix of the pattern identifies concrete
directories whose rename/deletion could move protected files out of the
glob's scope. A bare `**`/`*` ancestor should never become a deny regex.
