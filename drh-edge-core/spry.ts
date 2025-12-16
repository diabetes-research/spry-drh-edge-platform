#!/usr/bin/env -S deno run -A --import-map=import_map.json
// Use `deno run -A --watch` in the shebang if you're contributing / developing Spry itself.

import { CLI } from "https://raw.githubusercontent.com/programmablemd/spry/refs/tags/v0.107.3/bin/spry.ts";

await CLI({ defaultFiles: ["Spryfile.md"] }).parse(Deno.args);