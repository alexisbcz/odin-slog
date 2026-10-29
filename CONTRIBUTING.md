# Contributing

Thanks for helping. This project follows the shared [alexisbcz Odin standards](https://github.com/alexisbcz/odin-standards/blob/main/STANDARDS.md). The short version is below.

## Before you open a pull request

Run the same checks as CI:

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
vale sync && vale *.md
```

All three must pass with zero errors.

## Code

- Use snake_case for procedures and variables, Ada_Case for types, and SCREAMING_SNAKE_CASE for constants.
- Give every allocating procedure an `allocator := context.allocator` parameter and a matching destroy or delete procedure.
- Return `(T, Error)` from fallible procedures. Don't panic in library code.
- Write a doc comment for every exported declaration.
- Add a test under `tests/` for every bug fix and every new procedure. Tests use a tracking allocator and must not leak.
- Keep output byte-compatible with Go's `log/slog` where the formats overlap.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Write an imperative subject of 72 characters or fewer, a blank line, then a body of `-` bullet points that explain what changed and why:

```text
fix: quote text values that contain an equals sign

- values such as a=b were written bare and broke key=value parsing
- quote them with the same escapes as Go's strconv.Quote
```

## Changelog

Add a line under `## [Unreleased]` in `CHANGELOG.md` for every change that users can see.
