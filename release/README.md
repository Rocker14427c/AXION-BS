# Release artifacts

The file to flash is the one matching the newest release:
**`Axion-SPSM-v3.0.10-RMX3430.zip`**

`tools/makezip.sh` writes it here, taking the version from `module/module.prop`,
so the file name, the zip's `module.prop` and the app's version stamp cannot
disagree.

| file | release |
|---|---|
| `Axion-SPSM-v3.0.10-RMX3430.zip` | [v3.0.10](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.10) — current |
| `Axion-SPSM-v3.0.9-RMX3430.zip` | [v3.0.9](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.9) |
| `Axion-SPSM-v3.0.8-RMX3430.zip` | [v3.0.8](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.8) |
| `Axion-SPSM-v3.0.7-RMX3430.zip` | [v3.0.7](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.7) |
| `Axion-SPSM-v3.0.6-RMX3430.zip` | [v3.0.6](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.6) |
| `Axion-SPSM-v3.0.5-RMX3430.zip` | [v3.0.5](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.5) |
| `Axion-SPSM-v3.0.4-RMX3430.zip` | [v3.0.4](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.4) |
| `Axion-SPSM-v3.0.3-RMX3430.zip` | [v3.0.3](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.3) |
| `Axion-SPSM-v3.0.2-RMX3430.zip` | [v3.0.2](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.2) |
| `Axion-SPSM-v3.0.1-RMX3430.zip` | [v3.0.1](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0.1) |
| `Axion-SPSM-v3.0-RMX3430.zip` | [v3.0](https://github.com/Rocker14427c/AXION-BS/releases/tag/v3.0) |

Zips are committed rather than only attached to the GitHub release because the
release-assets endpoint (`uploads.github.com`) is not reachable from every build
environment, and a release with no downloadable file is worse than a commit that
has one. Older versions stay available at their tags either way.

To attach one as a proper release asset from a machine that can reach GitHub's
upload host:

```sh
gh release upload v3.0.9 release/Axion-SPSM-v3.0.9-RMX3430.zip
```

Rebuild after any change to `module/` or `app/`:

```sh
./build.sh && ./tools/makezip.sh
```
