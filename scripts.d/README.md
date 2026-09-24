# Forge custom scripts

Target-specific custom scripts live in this project-root directory under:

```text
scripts.d/<VMID>/
```

Forge executes the files for one VMID after that LXC's normal OS/application update when `RUN_CUSTOM_SCRIPTS=true`.

These scripts are target-specific extensions; they are not part of Forge's internal `lib/lxc/update/` implementation.
