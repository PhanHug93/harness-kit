# Node/Web Overlay

Apply when detector reports `node_js`, `react`, `nextjs`, `vue`, or `svelte`.

- Confirm whether `package.json` is production code or local tooling before applying frontend rules.
- Prefer package-manager scripts actually present in `package.json`.
- Do not assume `npm test`, `npm run lint`, or `npm run build` exists without checking scripts.
- Use `./scripts/rtk git ...` for all git inspection and mutation commands.
