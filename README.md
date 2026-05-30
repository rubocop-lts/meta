<p>
    <a href="https://rubocop.org#gh-light-mode-only"  target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/rubocop-light.svg?raw=true" alt="RuboCop logo">
    </a>
    <a href="https://rubocop.org#gh-dark-mode-only"  target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/rubocop-dark.svg?raw=true" alt="RuboCop logo">
    </a>
    <a href="https://www.ruby-lang.org/" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/ruby-logo.svg?raw=true" alt="Ruby logo">
    </a>
    <a href="https://semver.org/#gh-light-mode-only" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/semver-light.svg?raw=true" alt="SemVer logo">
    </a>
    <a href="https://semver.org/#gh-dark-mode-only" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/semver-dark.svg?raw=true" alt="SemVer logo">
    </a>
</p>

# RuboCop-LTS Meta

Release coordination project for the RuboCop-LTS ecosystem.

This repo contains shared project documents, image assets, and release
automation scripts that inspect and operate on sibling checkouts in one local
workspace.

Expected workspace layout:

```text
workspace/
  meta/
  rubocop-lts/
  rubocop-lts-rspec/
  standard-rubocop-lts/
  rubocop-ruby1_8/
  rubocop-ruby1_9/
  rubocop-ruby2_0/
  rubocop-ruby2_1/
  rubocop-ruby2_2/
  rubocop-ruby2_3/
  rubocop-ruby2_4/
  rubocop-ruby2_5/
  rubocop-ruby2_6/
  rubocop-ruby2_7/
  rubocop-ruby3_0/
  rubocop-ruby3_1/
  rubocop-ruby3_2/
```

For a different checkout location, set `WORKSPACE_DIR` to the directory
containing those repositories.

```shell
WORKSPACE_DIR=/path/to/workspace meta/scripts/release_gate.sh
```

## Scripts

Script entrypoints live in `scripts/`.

### `release_gate.sh`

Use case: answer "is the local ecosystem checkout in a releasable state?"

`release_gate.sh` is the broad preflight script. It checks repository hygiene,
branch expectations, dependency wiring, and optional validation tasks across the
RuboCop-LTS family. It supports release preparation, workspace handoff, and
workspace verification.

Checks:

- every expected sibling checkout exists and is a git repository
- each repository is on `main`
- each repository has no uncommitted changes
- each repository is synced with its upstream tracking branch
- each repository has a readable `lib/**/version.rb`
- each repository gemspec validates through RubyGems
- Gemfiles do not contain active Git dependencies
- the `rubocop-lts` branch matrix points each branch at the expected wrapper gem
- every `rubocop-lts` branch has the expected shared dependencies
- every `rubocop-lts` branch in the matrix is synced with its upstream tracking branch

Basic preflight:

```shell
meta/scripts/release_gate.sh
```

Useful options:

```shell
meta/scripts/release_gate.sh --audit-bumps
meta/scripts/release_gate.sh --run-validation
meta/scripts/release_gate.sh --require-tags
meta/scripts/release_gate.sh --quiet
```

`--audit-bumps` adds the version bump policy audit from `release_bump_plan.rb`
and stores its output under
`tmp/release_bump_plan.log`.

`--run-validation` runs the validation suite, including specs for
`rubocop-lts-rspec`, `standard-rubocop-lts`, and `rubocop-lts`, plus
`rubocop_gradual:check` across the wrapper gems. Logs are written under
`tmp/release_gate/`.

`--require-tags` adds strict `vVERSION` tag checks. This mode is for publication
verification, not release preparation. Missing release tags are expected in a
workspace containing release commits that have not been tagged.

### `release_bump_plan.rb`

Use case: answer "which gems need release work, and are their version numbers
large enough for the commits attached to their release markers?"

`release_bump_plan.rb` is the version policy script. It reads git tags as
release markers, compares tagged release state to repository state, and reports
whether each gem's version number satisfies the policy implied by the changes.
It also emits JSON consumed by `release_publish.rb`.

Tags matter here because they identify release snapshots. The script uses them
to read tagged gemspecs, count commits on top of a release marker, and compare
the version in `lib/**/version.rb` to the version represented by `vVERSION`.

The script compares:

- version constants
- `v*` release tags
- gemspec dependency bounds
- `required_ruby_version`
- the `rubocop-lts` branch matrix

It reports three sections:

- release policy audit, comparing version-tag pairs
- repo bump audit, comparing a repository version tag to `HEAD`
- `rubocop-lts` branch dependency and bump audit

Human-readable audit:

```shell
meta/scripts/release_bump_plan.rb
```

Machine-readable output:

```shell
meta/scripts/release_bump_plan.rb --json > tmp/release_bump_plan.json
```

Strict tag mode:

```shell
meta/scripts/release_bump_plan.rb --require-tags
REQUIRE_TAGS=true meta/scripts/release_bump_plan.rb
```

Exit status `0` means no policy failures. Exit status `1` means policy
failures. In non-strict mode, missing or mismatched tags can be warnings instead
of failures.

### `release_push_git.sh`

Use case: answer "which local release commits need to be pushed, and push them
as one workspace operation."

`release_push_git.sh` pushes git commits across the release workspace. It checks
the `rubocop-lts` branch matrix plus the `main` branch of each companion repo.
It refuses to push dirty repositories, repositories without upstream tracking,
and branches that are behind their upstream. The script is a dry run unless
`--execute` is given.

Preview pushes:

```shell
meta/scripts/release_push_git.sh
```

Run pushes:

```shell
meta/scripts/release_push_git.sh --execute
```

### `release_publish.rb`

Use case: answer "which build or push commands are selected, and run that
release queue in dependency order."

`release_publish.rb` is the build and publish driver. It uses the bump-plan data
to construct a release queue, sorts wrapper gems ahead of aggregate gems, checks
that selected repositories are clean, and runs build or release commands. It can
also create missing `vVERSION` tags and push git state.

The release queue publishes `standard-rubocop-lts` and `rubocop-lts-rspec`
ahead of wrapper gems so install and update commands can resolve released
companion versions for dependent gems.

For each selected target, the prepare step runs:

```shell
mise use ruby@4.0.5
mise trust mise.toml
bundle update
bundle update --bundler
```

Use `--no-prepare` to skip those commands.

Without `--execute`, the script prints the release queue and command preview,
without running build, release, checkout, tag, or push commands.

Preview the release queue:

```shell
meta/scripts/release_publish.rb
```

Build release candidates locally:

```shell
meta/scripts/release_publish.rb --execute --no-push
```

Publish gems to RubyGems:

```shell
meta/scripts/release_publish.rb --execute --push
```

Create missing `vVERSION` tags:

```shell
meta/scripts/release_publish.rb --execute --push --tag
```

Push released branches and tags:

```shell
meta/scripts/release_publish.rb --execute --push --tag --push-git
```

`rubocop-lts@main` stays out of the branch release queue unless requested:

```shell
meta/scripts/release_publish.rb --include-main
```

Useful selection options:

```shell
meta/scripts/release_publish.rb --only rubocop-ruby3_2
meta/scripts/release_publish.rb --only rubocop-lts@r3_2-even-v24
meta/scripts/release_publish.rb --only rubocop-lts
meta/scripts/release_publish.rb --start-at standard-rubocop-lts
```

Useful execution options:

```shell
meta/scripts/release_publish.rb --json tmp/release_bump_plan.json
meta/scripts/release_publish.rb --no-prepare
meta/scripts/release_publish.rb --no-bundle-install
meta/scripts/release_publish.rb --skip-tests
meta/scripts/release_publish.rb --require-tags
```

With `--execute --push`, the script prompts for the gem signing key passphrase
and passes it to release commands that request it. RubyGems MFA requests trigger
an interactive OTP prompt.

`--tag` creates missing `vVERSION` release tags as part of the publish driver.
The gate script does not require those tags unless `--require-tags` is used.

## Command Groups

Typical preparation:

```shell
meta/scripts/release_gate.sh --audit-bumps
meta/scripts/release_bump_plan.rb --json > tmp/release_bump_plan.json
meta/scripts/release_publish.rb --json tmp/release_bump_plan.json
```

Publication verification:

```shell
meta/scripts/release_gate.sh --audit-bumps --require-tags
```

Git push:

```shell
meta/scripts/release_push_git.sh
meta/scripts/release_push_git.sh --execute
```

Build or publish:

```shell
meta/scripts/release_publish.rb --json tmp/release_bump_plan.json --execute --no-push
meta/scripts/release_publish.rb --json tmp/release_bump_plan.json --execute --push --tag
```

Strict verification and git push:

```shell
meta/scripts/release_gate.sh --audit-bumps --require-tags
meta/scripts/release_publish.rb --json tmp/release_bump_plan.json --execute --push --tag --push-git
```

Use `--only` or `--start-at` for a subset of the release queue.

## Environment

The scripts use these environment variables:

| Variable | Used by | Fallback | Purpose |
|----------|---------|---------|---------|
| `WORKSPACE_DIR` | all scripts | parent directory of `meta` | Directory containing the ecosystem checkouts |
| `TMPDIR` | `release_gate.sh`, `release_publish.rb` | `$WORKSPACE_DIR/tmp` | Location for generated logs and bump-plan JSON |
| `REQUIRE_TAGS` | `release_bump_plan.rb` | `false` | Enables strict tag checks with value `true` |

## DVCS

Find this project on:

| Any            | Of               | These          | DVCS           |
|----------------|------------------|----------------|----------------|
| [hub][hub]     | [berg][berg]     | [hut][hut]     | [lab][lab]     |

[berg]: https://codeberg.org/rubocop-lts/meta
[hub]: https://github.com/rubocop-lts/meta
[hut]: https://sr.ht/~galtzo/rubocop-lts-meta
[lab]: https://gitlab.com/rubocop-lts/meta

## Contributing

Bug reports and pull requests are welcome. Everyone interacting in this
project's codebases, issue trackers, chat rooms, and mailing lists is expected
to follow the [code of conduct][conduct].

[conduct]: CODE_OF_CONDUCT.md

## License

This project is available as open source under the terms of the
[MIT License][license].

[license]: LICENSE.txt

<details>
  <summary>Project Logos</summary>

See [docs/images/logo/README.txt][project-logos].

</details>

[project-logos]: docs/images/logo/README.txt
