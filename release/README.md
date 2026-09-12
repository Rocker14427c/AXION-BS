# Release artifacts

`Axion-SPSM-v<version>-RMX3430.zip` is the flashable module, written here by
`tools/makezip.sh` (which takes its version from `module/module.prop`, so the
file name and the zip contents cannot disagree).

It is committed rather than only attached to the GitHub release because the
release-assets endpoint (`uploads.github.com`) is not reachable from every build
environment, and a release with no downloadable file is worse than a commit with
one. Download it from here, or from the release page, which links to this path
at the tag.

To attach it to the release as a proper asset from a machine that can reach
GitHub's upload host:

```sh
gh release upload v3.0 release/Axion-SPSM-v3.0-RMX3430.zip
```

Rebuild after any change to `module/` or `app/`: `./build.sh && ./tools/makezip.sh`.
