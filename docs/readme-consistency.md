# README reviews outside RepoMan

The model-backed README consistency detector and its copied acceptance contract have been removed. RepoMan retains missing README, broken local reference and published description checks. Use the `optimize-readme` skill for separately requested editorial reviews. RepoMan no longer makes inference calls or reads saved provider credentials. Existing provider preferences, Keychain entries and model caches are left untouched and unused.

See [the shared CLI](issues.md#shared-cli) for deterministic checks that skills can consume.
