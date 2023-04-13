<p>
    <a href="https://rubocop.org#gh-light-mode-only"  target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/rubocop-light.svg?raw=true" alt="SVG RuboCop Logo, Copyright (c) 2014 Dimiter Petrov, CC BY-NC 4.0, see docs/images/logo/README.txt">
    </a>
    <a href="https://rubocop.org#gh-dark-mode-only"  target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/rubocop-dark.svg?raw=true" alt="SVG RuboCop Logo, Copyright (c) 2014 Dimiter Petrov, CC BY-NC 4.0, see docs/images/logo/README.txt">
    </a>
    <a href="https://www.ruby-lang.org/" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/ruby-logo.svg?raw=true" alt="Yukihiro Matsumoto, Ruby Visual Identity Team, CC BY-SA 2.5, see docs/images/logo/README.txt">
    </a>
    <a href="https://semver.org/#gh-light-mode-only" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/semver-light.svg?raw=true" alt="SemVer.org Logo by @maxhaz, see docs/images/logo/README.txt">
    </a>
    <a href="https://semver.org/#gh-dark-mode-only" target="_blank" rel="noopener">
      <img height="120px" src="https://github.com/rubocop-lts/meta/raw/main/docs/images/logo/semver-dark.svg?raw=true" alt="SemVer.org Logo by @maxhaz, see docs/images/logo/README.txt">
    </a>
</p>

# RuboCop-LTS Meta Project

This is the "meta" project for RuboCop-LTS.
It is so meta, in fact, that it is managed by the project "meta".

What is a "meta" project, you ask?
You may have seen something similar in the repos for
bundler, rails, bridgetown, or roda, but this one is done differently.

It has many sub-projects, which consist of all the parts of the RuboCop-LTS ecosystem.
This makes developing them much easier as a one-human-band.
Unlike other meta patterns, this does not use git sub-modules,
yet it also does not use a single git-tracked file tree.
Instead another project, actually called [`meta`](https://github.com/mateodelnorte/meta), and built with NodeJS,
manages the subprojects completely, and almost transparently.

New to meta? [It's the absolute stuffing](https://patrickleet.medium.com/mono-repo-or-multi-repo-why-choose-one-when-you-can-have-both-e9c77bd0c668).
It has nothing whatsoever to do with the johnny-come-lately company, which ripped off the name.

## 🛞 DVCS

This project does not trust any one version control system,
so it abides the principles of ["Distributed Version Control Systems"][💎d-in-dvcs]

Find this project on:

| Any            | Of               | These          | DVCS           |
|----------------|------------------|----------------|----------------|
| [🐙hub][🐙hub] | [🧊berg][🧊berg] | [🛖hut][🛖hut] | [🧪lab][🧪lab] |

[comment]: <> ( DVCS LINKS )

[💎d-in-dvcs]: https://railsbling.com/posts/dvcs/put_the_d_in_dvcs/

[🧊berg]: https://codeberg.org/rubocop-lts/meta
[🐙hub]: https://gitlab.com/rubocop-lts/meta
[🛖hut]: https://sr.ht/~galtzo/rubocop-lts-meta
[🧪lab]: https://gitlab.com/rubocop-lts/meta

## 🎁 Local Development Install

```shell
meta git clone git@github.com:rubocop-lts/meta.git
meta exec "git fetch"
meta exec "git checkout main"
```

See how the last two commands are prefixed with `meta exec` followed by a quoted command?
That's pretty much all you need to know.
The first command is special, in that it prepares each project to be checked out.

### 🧸 Add New Sub Project

New versions of Ruby come out yearly, which means a new RuboCop-LTS ecosystem gem.

Example - when Ruby 8.5 is released in the year 2053, we would do the following
(after creating the project at `https://github.com/rubocop-lts/rubocop-ruby8_5`, of course):

```shell
meta project add userService git@github.com:rubocop-lts/rubocop-ruby8_5.git
```

## 🌈Contributors

[![Contributors][🌈contrib-rocks-img]][🐙hub-contrib]

Contributor tiles (GitHub only) made with [contributors-img][🌈contrib-rocks].

Learn more about, or become one of, our 🎖️contributors on:

| Any                                 | Of                                    | These                               | DVCS                                |
|-------------------------------------|---------------------------------------|-------------------------------------|-------------------------------------|
| [🐙hub contributors][🐙hub-contrib] | [🧊berg contributors][🧊berg-contrib] | [🛖hut contributors][🛖hut-contrib] | [🧪lab contributors][🧪lab-contrib] |

[comment]: <> ( DVCS CONTRIB LINKS )

[🌈contrib-rocks]: https://contrib.rocks
[🌈contrib-rocks-img]: https://contrib.rocks/image?repo=rubocop-lts/meta
[🌈contributing]: CONTRIBUTING.md

[🧊berg-contrib]: https://codeberg.org/rubocop-lts/meta/activity
[🐙hub-contrib]: https://github.com/rubocop-lts/meta/graphs/contributors
[🛖hut-contrib]: https://git.sr.ht/~galtzo/rubocop-lts-meta/log/
[🧪lab-contrib]: https://gitlab.com/rubocop-lts/meta/-/graphs/main?ref_type=heads

## 📄 License [![License: MIT][📄license-img]][📄license-ref]

The gem is available as open source under the terms of the [MIT License][📄license].
See [LICENSE.txt][📄license] for the official [Copyright Notice][📄copyright-notice-explainer].

[comment]: <> ( LEGAL LINKS )

[📄copyright-notice-explainer]: https://opensource.stackexchange.com/questions/5778/why-do-licenses-such-as-the-mit-license-specify-a-single-year
[📄license]: LICENSE.txt
[📄license-ref]: https://opensource.org/licenses/MIT
[📄license-img]: https://img.shields.io/badge/License-MIT-green.svg

<details>
  <summary>Project Logos (meta)</summary>

See [docs/images/logo/README.txt][📷project-logos]

</details>

<details>
  <summary>Organization Logo (rubocop-lts)</summary>

Author: [Yusuf Evli][📷org-logo-author]
Source: [Unsplash][📷org-logo-source]
License: [Unsplash License][📷org-logo-license]

[comment]: <> ( LOGO LINKS )

[📷project-logos]: https://github.com/rubocop-lts/meta/blob/main/docs/images/logo/README.txt
[📷org-logo-author]: https://unsplash.com/@yusufevli
[📷org-logo-source]: https://unsplash.com/photos/yaSLNLtKRIU
[📷org-logo-license]: https://unsplash.com/license

</details>

### © Copyright

* Copyright © 2023 [Peter H. Boling][peterboling] of [Rails Bling][railsbling]

[peterboling]: http://www.peterboling.com
[railsbling]: http://www.railsbling.com

## 🪇 Code of Conduct

Everyone interacting in the Rubocop::Ruby27 project's codebases, issue trackers,
chat rooms and mailing lists is expected to follow the [code of conduct][🪇conduct].

[🪇conduct]: CODE_OF_CONDUCT.md

## 📌 Versioning

Libraries enumerated within this RuboCop-LTS meta project aim to adhere to [Semantic Versioning 2.0.0][📌semver].
Violations of this scheme should be reported as bugs.
Specifically, if a minor or patch version is released that breaks backward compatibility, a new version should be
immediately released that restores compatibility.
Breaking changes to the public API will only be introduced with new major versions.

To get a better understanding of how SemVer is intended to work over a project's lifetime,
read this article from the creator of SemVer:

- ["Major Version Numbers are Not Sacred"][📌major-versions-not-sacred]

As a result of this policy, you can (and should) specify a dependency on these libraries using
the [Pessimistic Version Constraint][📌pvc] with two digits of precision.

For example:

```ruby
spec.add_dependency "rubocop-lts", "~> X.y"
```

[comment]: <> ( VERSIONING LINKS )

[📌pvc]: http://guides.rubygems.org/patterns/#pessimistic-version-constraint
[📌semver]: http://semver.org/
[📌major-versions-not-sacred]: https://tom.preston-werner.com/2022/05/23/major-version-numbers-are-not-sacred.html

[comment]: <> ( KEYED LINKS )

[🔑cc-cov]: https://codeclimate.com/github/rubocop-lts/meta/test_coverage
[🔑cc-covi]: "https://api.codeclimate.com/v1/badges/<key>/test_coverage"
[🔑depfu]: "https://depfu.com/github/pboling/rspec-stubbed_env?project_id=<key>"
[🔑depfui]: "https://badges.depfu.com/badges/<key>/count.svg"

