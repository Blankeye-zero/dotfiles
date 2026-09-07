/**
 * secret-guard — redaction-only add-on. Fills gaps left by the other two layers:
 *
 *  - pi-permission-system owns PATH DENIAL (read/write/edit/bash path gate):
 *      .env / .env.* / local.env / local.oci.env / .env.test,
 *      *.tfstate / *.tfstate.* / *.tfvars, .venv/**, node_modules/**.
 *
 *  - pi-sentry owns: vendor-pattern redaction, key=value secret fields,
 *      connection strings, PEM/JWT/bearer, sensitive-path blocking (strict),
 *      secret-dump command blocking, secret-value blocking, session-history
 *      scrubbing, /sentry modes + pi-sentry.json config.
 *
 *  - secret-guard adds only the REDACTION patterns neither covers:
 *      - 40-char AWS secret access keys (mixed case+digit, base64/url alphabet)
 *      - ASN.1 DER blocks (bare MII... base64, no PEM wrapper)
 *      - generic high-entropy tokens (>=64 chars, mixed case+digit)
 *      - vendor tokens pi-sentry lacks: tvly- (Tavily), BSA (Brave),
 *        fc- (Firecrawl), sk_test_ (bare Stripe test key)
 *
 * No path/command blocking here — that's pi-permission-system's job.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface Match {
  start: number;
  end: number;
  replacement: string;
}

// ============================================================================
// Marker bookkeeping — never re-redact a span already inside [REDACTED:...]
// ============================================================================
const MARKER_RE = /\[REDACTED[^\]]*\]/g;

function markerRanges(text: string): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  MARKER_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = MARKER_RE.exec(text)) !== null)
    out.push([m.index, m.index + m[0].length]);
  return out;
}

function inside(
  markers: Array<[number, number]>,
  s: number,
  e: number,
): boolean {
  for (const [a, b] of markers) if (s < b && e > a) return true;
  return false;
}

function push(
  matches: Match[],
  s: number,
  e: number,
  replacement: string,
  markers: Array<[number, number]>,
): void {
  if (e <= s || inside(markers, s, e)) return;
  matches.push({ start: s, end: e, replacement });
}

function buildMarker(value: string, type: string): string {
  const t = value.replace(/^[\s"']+|["']+$/g, "");
  const prefix = t.slice(0, 4);
  const stars = "*".repeat(Math.min(20, Math.max(8, t.length - 4)));
  return `${prefix}${stars}[REDACTED:${type}]`;
}

// ---- Vendor tokens pi-sentry does not cover ----
const UNIQUE_VENDORS: Array<{ name: string; re: RegExp }> = [
  { name: "Tavily API Key", re: /\btvly-[A-Za-z0-9_-]{20,}\b/g },
  { name: "Brave API Key", re: /\bBSA[A-Z0-9]{20,}\b/g },
  { name: "Firecrawl API Key", re: /\bfc-[a-f0-9]{32}\b/g },
  { name: "Stripe Test Key", re: /\bsk_test_[A-Za-z0-9]{16,}\b/g },
];

const AWS_SECRET_RE = /\b[A-Za-z0-9/+=]{40}\b/g;
const ASN1_RE = /\bMII[A-Za-z0-9+/]{24,}={0,2}\b/g;
// ponytail: generic entropy floor at >=64 chars, mixed case+digit, sha-prefix
// excluded (npm integrity). Raise the floor if this false-positives on prose.
const ENTROPY_RE = /\b([A-Za-z0-9+/=]{64,})\b/g;

export function redact(text: string): string {
  if (!text) return text;
  const markers = markerRanges(text);
  const matches: Match[] = [];

  for (const { name, re } of UNIQUE_VENDORS) {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      push(
        matches,
        m.index,
        m.index + m[0].length,
        buildMarker(m[0], name),
        markers,
      );
    }
  }

  AWS_SECRET_RE.lastIndex = 0;
  let a: RegExpExecArray | null;
  while ((a = AWS_SECRET_RE.exec(text)) !== null) {
    const v = a[0];
    if (/[a-z]/.test(v) && /[A-Z]/.test(v) && /[0-9]/.test(v)) {
      push(
        matches,
        a.index,
        a.index + v.length,
        buildMarker(v, "AWS Secret Key"),
        markers,
      );
    }
  }

  ASN1_RE.lastIndex = 0;
  let s: RegExpExecArray | null;
  while ((s = ASN1_RE.exec(text)) !== null) {
    push(
      matches,
      s.index,
      s.index + s[0].length,
      "[REDACTED:ASN.1 SEQUENCE]",
      markers,
    );
  }

  ENTROPY_RE.lastIndex = 0;
  let e: RegExpExecArray | null;
  while ((e = ENTROPY_RE.exec(text)) !== null) {
    const v = e[1];
    if (!/[a-z]/.test(v) || !/[A-Z]/.test(v) || !/[0-9]/.test(v)) continue;
    if (
      /sha(?:1|256|384|512)-$/i.test(
        text.slice(Math.max(0, e.index - 12), e.index),
      )
    )
      continue;
    push(
      matches,
      e.index,
      e.index + v.length,
      buildMarker(v, "High Entropy Token"),
      markers,
    );
  }

  if (matches.length === 0) return text;
  matches.sort((x, y) => x.start - y.start);
  const kept: Match[] = [];
  let lastEnd = -1;
  for (const m of matches)
    if (m.start >= lastEnd) {
      kept.push(m);
      lastEnd = m.end;
    }
  let out = "";
  let cursor = 0;
  for (const m of kept) {
    out += text.slice(cursor, m.start) + m.replacement;
    cursor = m.end;
  }
  return out + text.slice(cursor);
}

// ============================================================================
// Extension entry — redaction only (no path blocking; see pi-permission-system)
// ============================================================================
export default function (pi: ExtensionAPI): void {
  pi.on("tool_result", async (event) => {
    const name = (event as { toolName: string }).toolName;
    if (name === "write" || name === "edit" || name === "multi_edit")
      return undefined;
    const content = (event as { content?: unknown }).content;
    if (!Array.isArray(content)) return undefined;

    let changed = false;
    const next = content.map((item) => {
      if (
        item &&
        typeof item === "object" &&
        (item as { type?: string }).type === "text"
      ) {
        const t = (item as { text?: unknown }).text;
        if (typeof t === "string") {
          const r = redact(t);
          if (r !== t) {
            changed = true;
            return { ...(item as object), text: r };
          }
        }
      }
      if (typeof item === "string") {
        const r = redact(item);
        if (r !== item) {
          changed = true;
          return r;
        }
      }
      return item;
    });

    return changed ? { content: next } : undefined;
  });

  pi.on("input", async (event) => {
    const text = (event as { text?: string }).text;
    if (typeof text === "string" && text) {
      const r = redact(text);
      if (r !== text) return { action: "transform", text: r };
    }
    return { action: "continue" };
  });
}
