#!/usr/bin/env node
/*
  bundle.js — gabungin semua modul .lua tiap app jadi 1 file `bundle.lua`.
  Tujuan: loader cukup 1 HttpGet (bukan ~33). Bikin load kilat + coexist sama Cobalt.

  Output: GAGSeller/<app>/bundle.lua  =  return { ["relpath"] = <source>, ... }
  init.lua tiap app fetch bundle ini sekali, terus loadModule/loadRaw ambil dari tabel.

  Pakai: node tools/bundle.js
  Jalanin dari root repo (folder yg ada GAGSeller/). Instan (~ms).
*/
const fs = require("fs");
const path = require("path");

const ROOT = process.cwd();
const APPS = ["kebongedang/garden", "kebongedang/trade"];
// file yg di-skip (bukan modul): loader & bundle itu sendiri
const SKIP = new Set(["init.lua", "bundle.lua", "bundle.obfuscated.lua"]);

function walk(dir, base, out) {
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) {
      walk(full, base, out);
    } else if (name.endsWith(".lua")) {
      const rel = path.relative(base, full).split(path.sep).join("/");
      if (SKIP.has(rel)) continue;
      out.push({ rel, src: fs.readFileSync(full, "utf8") });
    }
  }
}

// pilih level long-string ([=..=[ ]=..=]) yg ga muncul di source manapun
function pickDelim(files) {
  for (let n = 1; n <= 30; n++) {
    const close = "]" + "=".repeat(n) + "]";
    if (!files.some((f) => f.src.includes(close))) return n;
  }
  throw new Error("Ga nemu delimiter aman buat long-string.");
}

let totalFiles = 0;
for (const app of APPS) {
  const appDir = path.join(ROOT, app);
  if (!fs.existsSync(appDir)) {
    console.log(`(skip) ${app} — folder ga ada`);
    continue;
  }
  const files = [];
  walk(appDir, appDir, files);
  files.sort((a, b) => a.rel.localeCompare(b.rel));

  const n = pickDelim(files);
  const open = "[" + "=".repeat(n) + "[";
  const close = "]" + "=".repeat(n) + "]";

  let lua = "-- AUTO-GENERATED oleh tools/bundle.js — JANGAN edit manual.\n";
  lua += "-- Edit modul-nya langsung, terus run `node tools/bundle.js`.\n";
  lua += `-- ${files.length} modul, di-generate ${new Date().toISOString()}\n`;
  lua += "return {\n";
  for (const f of files) {
    // newline setelah open biar aman kalau source diawali '[' atau semacamnya
    lua += `\t[${JSON.stringify(f.rel)}] = ${open}\n${f.src}${close},\n`;
  }
  lua += "}\n";

  const outPath = path.join(appDir, "bundle.lua");
  fs.writeFileSync(outPath, lua, "utf8");
  totalFiles += files.length;
  console.log(`✓ ${app}/bundle.lua — ${files.length} modul (delim [${"=".repeat(n)}[)`);
}

console.log(`Beres. Total ${totalFiles} modul di-bundle.`);
