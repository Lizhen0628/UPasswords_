import { canonicalizeHost, hostnameOf, safeWebsiteUrl } from "./domain.js";
import type { SiteAssociation, SiteMatchMode } from "./types.js";

const MATCH_MODES = new Set<SiteMatchMode>([
    "domain", "host", "startsWith", "exactURL", "regex", "never", "wildcard",
]);
const PUBLIC_SUFFIXES = new Set([
    "ac.jp", "ac.nz", "ac.uk", "asn.au", "co.in", "co.jp", "co.kr", "co.nz", "co.uk",
    "com.ar", "com.au", "com.br", "com.cn", "com.hk", "com.mx", "com.my", "com.ph",
    "com.sg", "com.tr", "com.tw", "edu.au", "gov.au", "gov.uk", "net.au", "net.cn",
    "net.in", "net.nz", "net.uk", "org.au", "org.cn", "org.in", "org.nz", "org.uk",
    "appspot.com", "azurewebsites.net", "blogspot.com", "cloudfront.net", "firebaseapp.com",
    "github.io", "herokuapp.com", "netlify.app", "pages.dev", "vercel.app", "web.app",
    "wordpress.com", "workers.dev",
]);

/** Parse and validate one persisted site association. */
export function parseSiteAssociation(value: unknown): SiteAssociation | null {
    if (!value || typeof value !== "object") return null;
    const association = value as Record<string, unknown>;
    if (typeof association.url !== "string" || typeof association.mode !== "string"
        || !MATCH_MODES.has(association.mode as SiteMatchMode)) return null;
    const raw = association.url.trim();
    const mode = association.mode as SiteMatchMode;
    if (!raw || raw.length > 2048 || /[\u0000-\u001f\u007f]/.test(raw)) return null;
    if (mode === "regex") {
        if (!isSafeRegex(raw)) return null;
        try {
            new RegExp(raw);
        } catch {
            return null;
        }
        return { url: raw, mode };
    }
    if (raw.includes("\\")) return null;
    const wildcard = mode === "wildcard";
    if (wildcard !== raw.includes("*")) return null;
    const safe = safeWebsiteUrl(wildcard ? raw.replaceAll("*", "wildcard-token") : raw);
    if (!safe) return null;
    return { url: wildcard ? raw : safe, mode };
}

function isSafeRegex(pattern: string): boolean {
    if (pattern.length > 256 || /\\[1-9]|\(\?<[=!]/.test(pattern)) return false;
    let unboundedRepeats = 0;
    const groups: Array<{ quantified: boolean; alternation: boolean }> = [];
    for (let index = 0; index < pattern.length; index++) {
        const character = pattern[index];
        if (character === "\\") {
            index++;
            continue;
        }
        if (character === "[") {
            const end = pattern.indexOf("]", index + 1);
            if (end < 0) return false;
            index = end;
            continue;
        }
        if (character === "(") {
            groups.push({ quantified: false, alternation: false });
            continue;
        }
        if (character === "|") {
            const group = groups.at(-1);
            if (group) group.alternation = true;
            continue;
        }
        if (character === ")") {
            const group = groups.pop();
            if (!group) return false;
            const next = pattern[index + 1] ?? "";
            const repeatsGroup = next !== "" && "*+?{".includes(next);
            if (repeatsGroup && (group.quantified || group.alternation)) return false;
            if (repeatsGroup && groups.length) groups[groups.length - 1].quantified = true;
            continue;
        }
        const isGroupPrefix = character === "?" && pattern[index - 1] === "(";
        const isCount = character === "{" && /^\{\d+(?:,\d*)?\}/.test(pattern.slice(index));
        if (!isGroupPrefix && ("*+?".includes(character) || isCount)) {
            if (character === "*" || character === "+"
                || (isCount && /^\{\d+,\}/.test(pattern.slice(index)))) {
                unboundedRepeats++;
                if (unboundedRepeats > 1) return false;
            }
            const group = groups.at(-1);
            if (group) group.quantified = true;
        }
    }
    return groups.length === 0;
}

/** Parse a wildcard URL into an anchored, escaped, case-insensitive expression. */
function wildcardExpression(pattern: string): RegExp | null {
    if (pattern.length > 2048 || /[\u0000-\u001f\\]/.test(pattern)) return null;
    const escaped = pattern.split("*").map(part => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*");
    try {
        return new RegExp(`^${escaped}$`, "i");
    } catch {
        return null;
    }
}

function baseDomain(hostname: string): string {
    const host = canonicalizeHost(hostname);
    if (!host) return "";
    if (host === "localhost" || /^\d+(?:\.\d+){3}$/.test(host) || host.includes(":")) return host;
    const labels = host.split(".");
    if (labels.length < 2) return "";
    const suffix = labels.slice(-2).join(".");
    const suffixLength = PUBLIC_SUFFIXES.has(suffix) ? 2 : 1;
    return labels.length > suffixLength ? labels.slice(-(suffixLength + 1)).join(".") : "";
}

function normalizedHost(url: URL): string {
    return `${url.hostname.toLowerCase()}:${url.port}`;
}

/** Match a top-level HTTP(S) page against one association without broad suffix guessing. */
export function siteAssociationMatches(pageURL: string, association: SiteAssociation): boolean {
    const parsed = parseSiteAssociation(association);
    if (!parsed) return false;
    let page: URL;
    try {
        page = new URL(pageURL);
    } catch {
        return false;
    }
    if (page.protocol !== "http:" && page.protocol !== "https:") return false;
    if (parsed.mode === "never") return false;
    if (parsed.mode === "exactURL") return page.href === new URL(parsed.url).href;
    if (parsed.mode === "startsWith") return page.href.startsWith(new URL(parsed.url).href);
    if (parsed.mode === "host") return normalizedHost(page) === normalizedHost(new URL(parsed.url));
    if (parsed.mode === "regex") {
        if (page.href.length > 2048) return false;
        try {
            return new RegExp(parsed.url).test(page.href);
        } catch {
            return false;
        }
    }
    if (parsed.mode === "wildcard") return wildcardExpression(parsed.url)?.test(page.href) ?? false;
    const domain = baseDomain(hostnameOf(parsed.url));
    return Boolean(domain && baseDomain(page.hostname) === domain);
}

/** Match any explicit website association, or the legacy single website value as a domain. */
export function itemMatchesPage(pageURL: string, item: { host: string; sites?: SiteAssociation[] }): boolean {
    const sites = item.sites?.length ? item.sites : item.host ? [{ url: item.host, mode: "domain" as const }] : [];
    return sites.some(site => siteAssociationMatches(pageURL, site));
}

/** Match a page hostname and the stored URL for callers that only retain an origin host. */
export function siteMatchesHost(pageHost: string, item: { host: string; sites?: SiteAssociation[] }): boolean {
    return itemMatchesPage(`https://${pageHost}/`, item);
}

export function isSiteMatchMode(value: unknown): value is SiteMatchMode {
    return typeof value === "string" && MATCH_MODES.has(value as SiteMatchMode);
}
