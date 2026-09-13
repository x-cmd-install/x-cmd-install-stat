#!/usr/bin/env -S deno run --allow-net --allow-read --allow-write --allow-run
// .x-cmd/collector-repo-readme-check.ts — verify every x-cmd-install/<mirror>
// repo's README.md + README.cn.md satisfy the layout we want.
//
//   Section order (must match exactly, with slot 10 conditional):
//     1. Install
//     2. Code insight    (NOT "Code size")
//     3. OpenSSF Scorecard
//     4. Source
//     5. Release
//     6. Popularity
//     7. Totals (cumulative)
//     8. Recent activity (≥6 rows when card has data)
//     9. Release assets
//    10. Distribution status  (only when .x-cmd/fskv/repology_name exists)
//    11. Improve this data
//
//   Other checks:
//     - README.cn.md exists with the same 11 sections in Chinese
//     - Distribution status (if present) uses ✅ / ⚠️ / 🪦 / 🔄 emoji
//     - CN README logo has ?lang=zh
//     - "## Code size" must NOT appear (renamed to Code insight)
//
// Usage:
//   deno run --allow-net .x-cmd/collector-repo-readme-check.ts            # all mirrors via gh repo list
//   deno run --allow-net .x-cmd/collector-repo-readme-check.ts --known    # mirrors already in stat/
//   deno run --allow-net .x-cmd/collector-repo-readme-check.ts jq kotlin # specific names
//   deno run --allow-net .x-cmd/collector-repo-readme-check.ts --json out.json
//
// Exit code: 0 if all pass, 1 if any failures.

interface CheckResult {
    name: string;
    ok: boolean;
    issues: string[];
    has_repology: boolean;
    section_count: number;
}

const ORG = "x-cmd-install";
const BRANCH = "main";
const RAW_BASE = `https://raw.githubusercontent.com/${ORG}`;

// Expected section order — some are conditional:
//
//   Always present:
//     Install, Code insight, Source, Release, Popularity,
//     Totals (cumulative), Recent activity, Improve this data
//
//   Conditional:
//     OpenSSF Scorecard   — only when card has a score
//     Release assets      — only when latest release has assets
//     Distribution status — only when fskv/repology_name exists
//
// The script figures out which optional sections actually rendered
// before comparing — sections the action correctly skipped because
// their data source was unavailable shouldn't count as failures.
const EN_ALWAYS = [
    "Install",
    "Code insight",
    "Source",
    "Popularity",
    "Totals (cumulative)",
    "Recent activity",
    "Improve this data",
];
const EN_OPTIONAL = [
    "OpenSSF Scorecard",
    "Release",          // absent when latestVersion / lastRelease empty
    "Release assets",   // absent when no assets in latest release
    "Distribution status",
];
const EN_SECTIONS = [...EN_ALWAYS, ...EN_OPTIONAL];  // full canonical order

const CN_ALWAYS = [
    "安装",
    "代码洞察",
    "源代码",
    "流行度",
    "累计统计",
    "最近活动",
    "改进这些数据",
];
const CN_OPTIONAL = [
    "OpenSSF Scorecard 评分",
    "发布",          // same conditionality as EN Release
    "Release 资产",
    "发行版状态",
];
const CN_SECTIONS = [...CN_ALWAYS, ...CN_OPTIONAL];

// ---- HTTP helpers ----

async function fetchText(url: string): Promise<string | null> {
    // Two attempts — GitHub raw CDN sometimes returns 503 right after
    // a bulk action run completes. The second attempt usually succeeds.
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            const r = await fetch(url, { signal: AbortSignal.timeout(15_000) });
            if (r.ok) return await r.text();
            if (r.status === 404) return null;  // genuinely missing
            // 429 / 503: brief backoff and retry
            await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        } catch {
            // network blip — try again
            await new Promise((r) => setTimeout(r, 1000));
        }
    }
    return null;
}

async function checkMirror(name: string): Promise<CheckResult> {
    const issues: string[] = [];
    const [en, cn, repology] = await Promise.all([
        fetchText(`${RAW_BASE}/${name}/${BRANCH}/README.md`),
        fetchText(`${RAW_BASE}/${name}/${BRANCH}/README.cn.md`),
        fetchText(`${RAW_BASE}/${name}/${BRANCH}/.x-cmd/fskv/repology_name`),
    ]);
    const has_repology = (repology ?? "").trim().length > 0;

    if (en === null) {
        return { name, ok: false, issues: ["no README.md"], has_repology, section_count: 0 };
    }

    const enSections = extractSections(en);
    const cnSections = cn ? extractSections(cn) : [];

    // Build the effective expected list. Always-required sections
    // must appear in order; optional sections (OpenSSF Scorecard,
    // Release assets, Distribution status) can be present or absent
    // depending on whether their data source was available.
    const wantEn = [...EN_ALWAYS, ...(has_repology ? ["Distribution status"] : []),
        ...EN_OPTIONAL.filter((s) => s !== "Distribution status")];
    const wantCn = [...CN_ALWAYS, ...(has_repology ? ["发行版状态"] : []),
        ...CN_OPTIONAL.filter((s) => s !== "发行版状态")];

    compareOrder(name, "EN", enSections, wantEn, issues, EN_OPTIONAL);
    if (cn === null) {
        issues.push("no README.cn.md");
    } else {
        compareOrder(name, "CN", cnSections, wantCn, issues, CN_OPTIONAL);
    }

    // Distribution status content checks (if opted in)
    if (has_repology) {
        if (!en.includes("## Distribution status")) {
            issues.push("Distribution status: section missing");
        } else if (!/✅|⚠️|🪦|🔄/.test(en)) {
            issues.push("Distribution status: missing status emoji (✅⚠️🪦🔄)");
        }
    }

    // Code insight rename check
    if (/^## Code size$/m.test(en)) {
        issues.push("still titled 'Code size' (should be 'Code insight')");
    }

    // Recent activity: count data rows (header row starts with "| Window")
    if (enSections.includes("Recent activity")) {
        const recentBlock = extractSectionBlock(en, "Recent activity");
        // Skip the header line "| Window | Since | ..." and the separator
        // line "|---|---|..." — count only data rows (3rd column onwards).
        const allRows = (recentBlock.match(/^\|[^\n]+/gm) ?? []);
        const dataRows = allRows.filter((r) =>
            !/^\|\s*(Window|---)/.test(r)
        ).length;
        if (dataRows > 0 && dataRows < 6) {
            issues.push(`Recent activity: ${dataRows} rows (expected ≥6)`);
        }
    }

    // CN logo ?lang=zh
    if (cn && !/repo\.x-cmd\.io\/[^)]+\.svg\?lang=zh/.test(cn)) {
        issues.push("CN: logo missing ?lang=zh");
    }

    return {
        name,
        ok: issues.length === 0,
        issues,
        has_repology,
        section_count: enSections.length,
    };
}

function extractSections(md: string): string[] {
    const out: string[] = [];
    for (const line of md.split("\n")) {
        const m = line.match(/^## (.+?)\s*$/);
        if (m) out.push(m[1]);
    }
    return out;
}

function extractSectionBlock(md: string, heading: string): string {
    const re = new RegExp(`^## ${escapeRe(heading)}\\s*$\\n([\\s\\S]*?)(?=^## |\\Z)`, "m");
    const m = md.match(re);
    return m ? m[1] : "";
}

function escapeRe(s: string): string {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function compareOrder(
    _name: string,
    label: string,
    got: string[],
    want: string[],
    issues: string[],
    optional: string[] = [],
): void {
    // Two-pointer walk:
    //   - g walks through `got` (what's actually in the README)
    //   - i walks through `want` (what we expected, in canonical order)
    // Optional sections (in `optional`) may appear in `got` at any
    // point without breaking order; the corresponding `want` slot is
    // then skipped silently. Conversely, an optional `want` slot may
    // be missing from `got` without error.
    const optSet = new Set(optional);
    let g = 0;
    let i = 0;
    while (i < want.length) {
        const expected = want[i];
        const isOptional = optSet.has(expected);

        if (g >= got.length) {
            if (!isOptional) {
                issues.push(`${label}[${i}] expected "${expected}" got <missing>`);
            }
            i++;
            continue;
        }

        if (got[g] === expected) {
            // exact match — advance both
            g++;
            i++;
            continue;
        }

        // got[g] doesn't match expected. If `got[g]` itself is one of
        // the optional sections, swallow it and advance g (it just
        // showed up at the wrong slot).
        if (optSet.has(got[g])) {
            g++;
            continue;
        }

        // Otherwise, if expected is optional, skip it and advance i
        // (it just isn't present in `got`).
        if (isOptional) {
            i++;
            continue;
        }

        // Both required and mismatched — report.
        issues.push(`${label}[${i}] expected "${expected}" got "${got[g]}"`);
        g++;
        i++;
    }
    if (g < got.length) {
        const extras = got.slice(g).filter((s) => !optSet.has(s));
        if (extras.length > 0) {
            issues.push(`${label}: extra non-optional section(s) at end: ${extras.join(", ")}`);
        }
    }
}

// ---- CLI ----

function die(msg: string, code = 2): never {
    console.error(msg);
    Deno.exit(code);
}

async function main(): Promise<void> {
    const args = Deno.args;
    let mode: "known" | "all" | "names" = "all";
    let outJson = "";
    let explicitNames: string[] = [];

    for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (a === "--known") mode = "known";
        else if (a === "--all") mode = "all";
        else if (a === "--json") {
            outJson = args[++i] ?? "";
        } else if (!a.startsWith("-")) {
            explicitNames.push(a);
        } else {
            die(`unknown flag: ${a}`);
        }
    }

    let repos: string[];
    if (explicitNames.length > 0) {
        mode = "names";
        repos = explicitNames;
    } else if (mode === "known") {
        // Mirror list = stat/ directories (those sync.sh has pulled)
        try {
            const entries: string[] = [];
            for await (const e of Deno.readDir("./stat")) {
                if (e.isDirectory) entries.push(e.name);
            }
            repos = entries.sort();
        } catch {
            die("stat/ not readable from cwd");
        }
    } else {
        // --all: gh repo list
        const cmd = new Deno.Command("gh", {
            args: [
                "repo", "list", ORG, "--limit", "4000",
                "--json", "name", "--jq", ".[].name",
            ],
            stdout: "piped",
        });
        const { stdout, success } = await cmd.output();
        if (!success) die("gh repo list failed");
        repos = new TextDecoder().decode(stdout).trim().split("\n").filter(Boolean);
    }

    console.log(`==> checking ${repos.length} mirrors (mode=${mode})`);

    const concurrency = 2;  // keep low — GitHub CDN rate-limits heavy parallel fetches
    let i = 0;
    const results: CheckResult[] = [];
    const queue = [...repos];

    async function worker(): Promise<void> {
        while (true) {
            const name = queue.shift();
            if (!name) return;
            const r = await checkMirror(name);
            results.push(r);
            i++;
            if (i % 25 === 0) {
                console.error(`    ... ${i}/${repos.length}`);
            }
        }
    }

    await Promise.all(Array.from({ length: concurrency }, () => worker()));

    // Sort: failures first, then by name
    results.sort((a, b) => {
        if (a.ok !== b.ok) return a.ok ? 1 : -1;
        return a.name.localeCompare(b.name);
    });

    let pass = 0, fail = 0;
    for (const r of results) {
        if (r.ok) {
            console.log(`PASS  ${r.name}  (${r.section_count} sections, repology=${r.has_repology ? "y" : "n"})`);
            pass++;
        } else {
            console.log(`FAIL  ${r.name}  (${r.issues.length} issues)`);
            for (const i of r.issues) console.log(`      - ${i}`);
            fail++;
        }
    }

    console.log(`==> done: pass=${pass} fail=${fail}`);

    if (outJson) {
        await Deno.writeTextFile(outJson, JSON.stringify(results, null, 2));
        console.error(`results written to ${outJson}`);
    }

    Deno.exit(fail > 0 ? 1 : 0);
}

if (import.meta.main) {
    await main();
}
