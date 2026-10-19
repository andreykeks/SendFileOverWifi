import { cp, mkdir } from "node:fs/promises";

await mkdir(new URL("../src/data/", import.meta.url), { recursive: true });
await cp(new URL("../../localization/ui.json", import.meta.url), new URL("../src/data/ui.json", import.meta.url));
await cp(new URL("../../logo.png", import.meta.url), new URL("../public/logo.png", import.meta.url));
