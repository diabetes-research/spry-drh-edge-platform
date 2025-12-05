#!/usr/bin/env -S deno run -A --import-map=import_map.json
// Use `deno run -A --watch` in the shebang if you're contributing / developing Spry itself.
 
import { CLI } from "https://raw.githubusercontent.com/programmablemd/spry/refs/tags/0.90.0/lib/sqlpage/cli.ts";
 
CLI.instance().run();