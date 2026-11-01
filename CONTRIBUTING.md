# Contributing to 暗灯 (MagOff)

Issues and PRs welcome. Keep changes focused.

## Dev setup

```bash
./scripts/build.sh
open dist/暗灯.app
```

Helper install needs admin once (writes MagSafe SMC key `ACLC`).

## Scope

In scope: MagSafe LED modes, flash-on-reply/notification, packaging, docs.

Out of scope unless discussed: keyboard backlight, battery charge limits, App Store distribution (private APIs / privileged helper).

## Safety

Do not commit secrets, personal paths, or machine serials. Test MagSafe LED only — never write unrelated SMC keys in PRs.
