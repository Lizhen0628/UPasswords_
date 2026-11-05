import { itemMatchesPage } from "../core/site-matching.js";
import { projectVaultFragment } from "../core/cached-items.js";
import { autofillConflictBlocks, buildAutofillConflictGateEntry, parseAutofillConflictGate } from "../core/autofill-conflict-policy.js";
import { sha256BytesHex } from "../core/crypto.js";
import { base64ToBytes, listVaultConflicts } from "../api/relay.js";
import type { ExtensionItem } from "../core/types.js";

/** Background-only inspection never extends the unlock timeout or accepts page context. */
interface HintSession {
    handle(request: any): Promise<any>;
    inspect(): Promise<{
        unlocked: boolean;
        items?: ExtensionItem[];
        generation?: string;
        expiresAt?: number;
        snapshotVersion?: number;
    }>;
}

type SiteHint = { type: "site-hint"; count: number; unlocked: boolean; profileAvailable: boolean };
const lockedHint = (): SiteHint => ({ type: "site-hint", count: 0, unlocked: false, profileAvailable: false });
type SiteCandidate = { id: string; title: string; username: string };
const MAX_SITE_CANDIDATES = 8;
const AUTOFILL_CONFLICT_GATE_KEY = "extension.autofillConflictGate";
const AUTOFILL_CONFLICT_GATE_MAX_AGE_MS = 5 * 60 * 1000;
const personalInfoTokens = new Set([
    "given-name", "family-name", "email", "tel", "street-address",
    "address-line1", "address-line2", "address-level1", "address-level2",
    "postal-code", "country-name",
]);

function webURL(value: unknown): URL | null {
    if (typeof value !== "string") return null;
    try {
        const url = new URL(value);
        return url.protocol === "https:" || url.protocol === "http:" ? url : null;
    } catch {
        return null;
    }
}

/** Installs origin-checked site hints and user-selected fill handling. */
export function installSiteHints(api: any, session: HintSession): void {
    const badgeVersions = new Map<number, number>();

    async function countFor(url: URL, includeProfile = false): Promise<SiteHint> {
        const snapshot = await session.inspect();
        if (!snapshot.unlocked) return lockedHint();
        const items = snapshot.items ?? [];
        const count = items.filter((item) => item.autofillEnabled !== false && itemMatchesPage(url.href, item)
            && item.fields.some((field) => field.type === "password" && Boolean(field.value))).length;
        const profileAvailable = includeProfile && items.some((item) => {
            return item.recordType === "userProfile" && item.autofillEnabled !== false
                && item.fields.some((field) => personalInfoTokens.has(field.autofill) && Boolean(field.value));
        });
        return { type: "site-hint", count, unlocked: true, profileAvailable };
    }

    async function authorizedPage(sender: any): Promise<URL | null> {
        if (sender?.id !== api.runtime.id || typeof sender.tab?.id !== "number"
            || sender.frameId !== 0) return null;
        const page = webURL(sender.url);
        if (!page) return null;
        const tab = await api.tabs.get(sender.tab.id);
        const current = webURL(tab?.url);
        return current?.origin === page.origin ? page : null;
    }

    async function readSessionContext(): Promise<{
        token: string;
        userId: string;
        vaultId: string;
    } | null> {
        const bag = await api.storage.local.get(["relay.session", "relay.vault"]);
        const account = bag["relay.session"];
        const vault = bag["relay.vault"];
        if (typeof account?.token !== "string" || !account.token || typeof account.userId !== "string"
            || !account.userId || typeof vault?.id !== "string" || !vault.id) return null;
        return { token: account.token, userId: account.userId, vaultId: vault.id };
    }

    function candidatesFor(url: URL, items: ExtensionItem[]): SiteCandidate[] {
        return items.filter((item) => item.autofillEnabled !== false && itemMatchesPage(url.href, item))
            .flatMap((item) => {
                const password = item.fields.some((field) => field.type === "password" && Boolean(field.value));
                if (!password || !item.id || !item.title) return [];
                const username = item.fields.find((field) => field.type === "login" || field.type === "email");
                return [{ id: item.id, title: item.title, username: username?.value ?? "" }];
            })
            .sort((left, right) => left.title.localeCompare(right.title))
            .slice(0, MAX_SITE_CANDIDATES);
    }

    async function conflictBlocksFill(
        item: ExtensionItem,
        snapshot: { generation?: string },
        context: { token: string; userId: string; vaultId: string },
    ): Promise<boolean | null> {
        const bag = await api.storage.local.get([AUTOFILL_CONFLICT_GATE_KEY]);
        const storedGate = parseAutofillConflictGate(bag[AUTOFILL_CONFLICT_GATE_KEY]);
        const sameScope = storedGate?.userId === context.userId && storedGate.vaultId === context.vaultId;
        const recentGate = sameScope && Date.now() - storedGate.checkedAt <= AUTOFILL_CONFLICT_GATE_MAX_AGE_MS;
        if (recentGate) {
            return autofillConflictBlocks(storedGate, item.id, [
                ...(item.fields.some((field) => (field.type === "login" || field.type === "email") && field.value)
                    ? ["username" as const] : []),
                ...(item.fields.some((field) => field.type === "password" && field.value)
                    ? ["current-password" as const] : []),
            ]);
        }

        try {
            const conflicts = await listVaultConflicts(context.token, context.vaultId);
            const conflict = conflicts.find((candidate) => candidate.itemUuid.toLowerCase() === item.id.toLowerCase());
            if (!conflict) return false;
            let hasUnreadableCandidate = false;
            let hasDeleteCandidate = conflict.currentDeletedSeq > 0;
            const candidateItems: Array<ExtensionItem | null> = [];
            for (const candidate of conflict.candidates) {
                if (candidate.op === "delete") {
                    hasDeleteCandidate = true;
                    continue;
                }
                if (!candidate.bodyB64 || !candidate.sha256 || !snapshot.generation) {
                    hasUnreadableCandidate = true;
                    continue;
                }
                try {
                    const body = base64ToBytes(candidate.bodyB64);
                    if (await sha256BytesHex(body) !== candidate.sha256) throw new Error("candidate_digest_mismatch");
                    const response = await session.handle({
                        type: "vault-session",
                        action: "decrypt",
                        context,
                        generation: snapshot.generation,
                        rows: [{
                            uuid: conflict.itemUuid,
                            bodyB64: candidate.bodyB64,
                            revision: Math.max(1, candidate.revision),
                            kind: candidate.kind,
                            modifiedMs: candidate.modifiedMs,
                        }],
                    });
                    const fragment = response.fragments?.[0];
                    const projected = response.unlocked && fragment ? projectVaultFragment(fragment) : null;
                    if (!projected) throw new Error("candidate_decrypt_failed");
                    candidateItems.push(projected);
                } catch {
                    hasUnreadableCandidate = true;
                    candidateItems.push(null);
                }
            }
            const entry = buildAutofillConflictGateEntry({
                itemID: conflict.itemUuid,
                currentItem: item,
                candidateItems,
                hasUnreadableCandidate,
                hasDeleteCandidate,
                currentDeleted: conflict.currentDeletedSeq > 0,
            });
            const gate = {
                version: 1 as const,
                userId: context.userId,
                vaultId: context.vaultId,
                checkedAt: Date.now(),
                entries: [entry],
            };
            return autofillConflictBlocks(parseAutofillConflictGate(gate), item.id, [
                ...(item.fields.some((field) => (field.type === "login" || field.type === "email") && field.value)
                    ? ["username" as const] : []),
                ...(item.fields.some((field) => field.type === "password" && field.value)
                    ? ["current-password" as const] : []),
            ]);
        } catch {
            if (sameScope && storedGate) {
                return autofillConflictBlocks(storedGate, item.id, [
                    ...(item.fields.some((field) => (field.type === "login" || field.type === "email") && field.value)
                        ? ["username" as const] : []),
                    ...(item.fields.some((field) => field.type === "password" && field.value)
                        ? ["current-password" as const] : []),
                ]);
            }
            return null;
        }
    }

    async function selectItem(sender: any, itemID: unknown): Promise<Record<string, unknown>> {
        const page = await authorizedPage(sender);
        if (!page || typeof itemID !== "string" || !itemID) {
            return { type: "site-fill-rejected", reason: "page_unavailable" };
        }
        const snapshot = await session.inspect();
        const item = snapshot.items?.find((candidate) => candidate.id === itemID);
        if (!snapshot.unlocked || !snapshot.generation || !item
            || !itemMatchesPage(page.href, item) || item.autofillEnabled === false) {
            return { type: "site-fill-rejected", reason: "item_unavailable" };
        }
        const context = await readSessionContext();
        if (!context) return { type: "site-fill-rejected", reason: "session_unavailable" };
        const conflict = await conflictBlocksFill(item, snapshot, context);
        if (conflict === null) return { type: "site-fill-rejected", reason: "conflicts_unavailable" };
        if (conflict) return { type: "site-fill-rejected", reason: "conflict" };
        const latest = await session.inspect();
        const latestItem = latest.items?.find((candidate) => candidate.id === itemID);
        if (!latest.unlocked || latest.generation !== snapshot.generation
            || latest.snapshotVersion !== snapshot.snapshotVersion || !latestItem
            || latestItem.autofillEnabled === false || !itemMatchesPage(page.href, latestItem)
            || !latestItem.fields.some((field) => field.type === "password" && Boolean(field.value))) {
            return { type: "site-fill-rejected", reason: "item_changed" };
        }
        const touched = await session.handle({
            type: "vault-session",
            action: "touch",
            context,
            generation: snapshot.generation,
        });
        if (!touched.unlocked || touched.generation !== snapshot.generation) {
            return { type: "site-fill-rejected", reason: "locked" };
        }
        const [activeTab] = await api.tabs.query({ active: true, currentWindow: true });
        const activePage = webURL(activeTab?.url);
        if (activeTab?.id !== sender.tab.id || activePage?.origin !== page.origin
            || !itemMatchesPage(activePage.href, latestItem)) {
            return { type: "site-fill-rejected", reason: "page_changed" };
        }
        return {
            type: "site-fill-candidate",
            expectedOrigin: page.origin,
            username: latestItem.fields.find((field) => field.type === "login" || field.type === "email")?.value ?? "",
            password: latestItem.fields.find((field) => field.type === "password")?.value ?? "",
        };
    }

    async function refreshBadge(tabId: number): Promise<void> {
        if (!api.action?.setBadgeText) return;
        const version = (badgeVersions.get(tabId) ?? 0) + 1;
        badgeVersions.set(tabId, version);
        try {
            const tab = await api.tabs.get(tabId);
            if (!tab?.active) return;
            const url = webURL(tab.url);
            const hint = url ? await countFor(url) : lockedHint();
            if (badgeVersions.get(tabId) !== version) return;
            // Recheck navigation after asynchronous session inspection.
            const current = await api.tabs.get(tabId);
            if (!current?.active || current.url !== tab.url) {
                if (badgeVersions.get(tabId) === version) await refreshBadge(tabId);
                return;
            }
            if (badgeVersions.get(tabId) !== version) return;
            await api.action.setBadgeText({ tabId, text: hint.unlocked && hint.count > 0 ? String(hint.count) : "" });
            if (hint.count > 0 && api.action.setBadgeBackgroundColor) {
                try { await api.action.setBadgeBackgroundColor({ tabId, color: "#356B62" }); }
                catch { console.warn("[upw] site badge color unavailable"); }
            }
        } catch {
            // Missing tab permissions and closed tabs fail closed, never reuse an old count.
            if (badgeVersions.get(tabId) === version) {
                try { await api.action.setBadgeText({ tabId, text: "" }); }
                catch { console.warn("[upw] site badge unavailable"); }
            }
        }
    }

    function refreshActive(): void {
        void Promise.resolve(api.tabs.query({ active: true })).then((tabs: any[]) => {
            for (const tab of tabs) {
                if (typeof tab.id === "number") void refreshBadge(tab.id);
            }
        }, () => console.warn("[upw] site hint tabs unavailable"));
    }

    api.runtime.onMessage.addListener((message: any, sender: any, sendResponse: (value: unknown) => void) => {
        if (message?.type === "select-site-item") {
            void selectItem(sender, message.itemID).then(sendResponse, () => {
                console.warn("[upw] site candidate selection unavailable");
                sendResponse({ type: "site-fill-rejected", reason: "fill_unavailable" });
            });
            return true;
        }
        if (message?.type !== "site-hint" && message?.type !== "site-candidates"
            && message?.type !== "open-vault") return false;
        const denied = () => message.type === "site-hint" ? lockedHint()
            : message.type === "site-candidates" ? { type: "site-candidates", candidates: [] }
                : { type: "vault-opened", ok: false };
        void (async () => {
            const page = await authorizedPage(sender);
            if (!page) return denied();
            if (message.type === "site-hint") {
                const hint = await countFor(page, message.registration === true);
                // Do not return stale counts after a cross-origin navigation during inspection.
                if (!await authorizedPage(sender)) return lockedHint();
                void refreshBadge(sender.tab.id);
                return hint;
            }
            if (message.type === "site-candidates") {
                const snapshot = await session.inspect();
                if (!snapshot.unlocked) return denied();
                const candidates = candidatesFor(page, snapshot.items ?? []);
                if (!await authorizedPage(sender)) return denied();
                return { type: "site-candidates", candidates };
            }
            if (!api.action?.openPopup) return denied();
            await api.action.openPopup();
            console.info("[upw] site hint opened vault");
            return { type: "vault-opened", ok: true };
        })().then(sendResponse, () => {
            console.warn("[upw] site hint request unavailable");
            sendResponse(denied());
        });
        return true;
    });

    api.tabs.onActivated?.addListener(({ tabId }: { tabId: number }) => { void refreshBadge(tabId); });
    api.tabs.onUpdated?.addListener((tabId: number) => { void refreshBadge(tabId); });
    api.tabs.onRemoved?.addListener((tabId: number) => { badgeVersions.delete(tabId); });
    api.storage.onChanged?.addListener((_changes: unknown, area: string) => {
        if (area === "session" || area === "local") refreshActive();
    });
    refreshActive();
    console.info("[upw] count-only site hints installed");
}
