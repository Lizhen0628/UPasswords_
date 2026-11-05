// 职责：观察当前顶层 HTTP(S) 页面的登录表单并展示用户主动请求的站点候选。
// 页面脚本永不读取凭据；用户点选后仅扩展隔离环境接收单条凭据并写入当前表单。
// Page-world scripts never receive credentials; selection and filling stay in the isolated extension context.
(function () {
    "use strict";
    const api = globalThis.browser ?? globalThis.chrome;
    if (!api?.runtime || window.top !== window || !/^https?:$/.test(location.protocol)) return;

    const POLL_MS = 30_000;
    const DEBOUNCE_MS = 180;
    const HINT_GAP = 6;
    const VIEWPORT_MARGIN = 8;
    const HINT_WIDTH = 280;
    const HINT_HEIGHT = 80;
    const ownedHosts = new WeakSet();
    const wiredUsernameFields = new WeakSet();
    const popupURL = api.runtime.getURL("src/popup.html");
    const chinese = /^zh/i.test(document.documentElement.lang || navigator.language || "en");
    let host = null;
    let button = null;
    let fallback = null;
    let renderedState = "";
    let position = "";
    let anchor = null;
    let sequence = 0;
    let debounce = null;
    let pageHref = location.href;
    let focusedUsername = null;
    let dismissedUsername = null;
    let candidateSequence = 0;
    let candidateList = null;

    function isVisible(field) {
        if (field.type === "hidden" || field.disabled || field.readOnly || field.getClientRects().length === 0) return false;
        const rect = field.getBoundingClientRect();
        if (rect.width <= 1 || rect.height <= 1) return false;
        for (let element = field; element; element = element.parentElement) {
            const style = window.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden"
                || style.visibility === "collapse" || Number(style.opacity) === 0) return false;
        }
        return true;
    }

    function loginFields() {
        const inputs = Array.from(document.querySelectorAll("input")).filter(isVisible);
        if (registrationFields()) return null;
        const passwords = inputs.filter((field) => field.type.toLowerCase() === "password");
        const password = passwords.find((field) => field.autocomplete === "current-password")
            || (passwords.length === 1 && passwords[0].autocomplete !== "new-password" ? passwords[0] : null);
        if (password) {
            const scope = password.form || password.closest('[role="form"]') || password.parentElement;
            const nearby = inputs.filter((field) => scope?.contains(field));
            const username = nearby.find((field) => field.autocomplete === "username")
                || nearby.find((field) => /^(email|text|tel)$/.test(field.type)
                    && field.autocomplete !== "off");
            return { password, username, anchor: password };
        }
        // Username-first sign-in may keep a current-password field hidden between steps.
        const username = inputs.find((field) => field.autocomplete === "username" && field.form);
        const scope = username?.form || username?.closest('[role="form"]') || username?.parentElement;
        const scopedInputs = Array.from(document.querySelectorAll("input")).filter((field) => scope?.contains(field));
        const hasNewPassword = scopedInputs.some((field) => autocompleteToken(field) === "new-password");
        const hasUnclassifiedHiddenPassword = scopedInputs.some((field) => {
            return (field.type ?? "").toLowerCase() === "password" && !isVisible(field)
                && autocompleteToken(field) !== "current-password";
        });
        const hasVisiblePassword = inputs.some((field) => scope?.contains(field)
            && (field.type ?? "").toLowerCase() === "password");
        if (hasNewPassword || hasUnclassifiedHiddenPassword || hasVisiblePassword) return null;
        return username ? { username, password: null, anchor: username } : null;
    }

    const profileTokens = new Set([
        "given-name", "family-name", "email", "tel", "street-address",
        "address-line1", "address-line2", "address-level1", "address-level2",
        "postal-code", "country-name",
    ]);

    function autocompleteToken(field) {
        const tokens = (field.autocomplete ?? "").trim().toLowerCase().split(/\s+/);
        return tokens[tokens.length - 1];
    }

    function registrationFields() {
        const fields = Array.from(document.querySelectorAll("input, textarea")).filter(isVisible);
        const contactFields = fields.filter((field) => profileTokens.has(autocompleteToken(field)));
        for (const anchor of contactFields) {
            const scope = anchor.form || anchor.closest('[role="form"]') || anchor.parentElement;
            const nearby = fields.filter((field) => scope?.contains(field));
            const contacts = contactFields.filter((field) => scope?.contains(field));
            const newPassword = nearby.some((field) => (field.type ?? "").toLowerCase() === "password"
                && autocompleteToken(field) === "new-password");
            if (contacts.length >= 2 || (newPassword && contacts.length > 0)) {
                return { fields: contacts, anchor };
            }
        }
        return null;
    }

    function removeHint() {
        if (host) host.remove();
        host = null;
        button = null;
        fallback = null;
        candidateList = null;
        anchor = null;
        renderedState = "";
        position = "";
    }

    function reposition() {
        if (!host || !anchor) return;
        const rect = anchor.getBoundingClientRect();
        const height = host.getBoundingClientRect().height || HINT_HEIGHT;
        const left = Math.max(VIEWPORT_MARGIN, Math.min(rect.left, window.innerWidth - HINT_WIDTH - VIEWPORT_MARGIN));
        const top = Math.max(VIEWPORT_MARGIN, Math.min(rect.bottom + HINT_GAP, window.innerHeight - height - VIEWPORT_MARGIN));
        const next = `${left}:${top}`;
        if (position === next) return;
        position = next;
        host.style.left = `${left}px`;
        host.style.top = `${top}px`;
    }

    function showHint(count, field, profileAvailable = false) {
        anchor = field;
        if (host && !host.isConnected) removeHint();
        anchor = field;
        if (!host) {
            host = document.createElement("div");
            ownedHosts.add(host);
            host.style.cssText = "all:initial;position:fixed;z-index:2147483647;max-width:280px;";
            const shadow = host.attachShadow({ mode: "closed" });
            const style = document.createElement("style");
            style.textContent = ":host{font:12px/1.4 system-ui,sans-serif;color-scheme:light dark}button{font:inherit;font-weight:600;color:#2f6cc0;background:#fff;border:1px solid #cfdff2;border-radius:8px;padding:7px 12px;cursor:pointer;max-width:280px;text-align:start;box-shadow:0 4px 14px rgb(31 68 120/.14)}button:focus-visible{outline:2px solid #3f7fd4;outline-offset:2px}#candidateList[hidden]{display:none!important}#candidateList button{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}#candidateList button:disabled{opacity:.6;cursor:wait}p{font:inherit;color:#2f6cc0;background:#fff;border:1px solid #cfdff2;border-radius:8px;padding:7px 11px;margin:4px 0 0;max-width:260px;box-shadow:0 4px 14px rgb(31 68 120/.12)}@media(prefers-color-scheme:dark){button,p{color:#8fbcee;background:#2b2c28;border-color:#465870}button{box-shadow:0 4px 14px rgb(0 0 0/.4)}}";
            button = document.createElement("button");
            button.type = "button";
            fallback = document.createElement("p");
            fallback.hidden = true;
            candidateList = document.createElement("div");
            candidateList.id = "candidateList";
            candidateList.setAttribute("role", "listbox");
            candidateList.setAttribute("aria-label", chinese ? "匹配账号" : "Matching accounts");
            candidateList.hidden = true;
            candidateList.style.cssText = "all:initial;display:flex;flex-direction:column;gap:2px;margin-top:4px;max-width:280px;";
            button.addEventListener("click", async (event) => {
                if (!event.isTrusted) return;
                const currentHost = host;
                try {
                    const response = await api.runtime.sendMessage({ type: "open-vault" });
                    if (currentHost !== host) return;
                    if (response?.type === "vault-opened" && response.ok) return;
                } catch {
                    console.warn("[upw] site hint popup unavailable");
                }
                if (currentHost !== host || !fallback) return;
                fallback.textContent = chinese ? "请点击浏览器工具栏中的 UPasswords 图标。" : "Click the UPasswords icon in your browser toolbar.";
                fallback.hidden = false;
            });
            button.addEventListener("keydown", (event) => {
                if (event.key === "ArrowDown" && candidateList && !candidateList.hidden) {
                    event.preventDefault();
                    candidateList.querySelector("button")?.focus();
                }
            });
            shadow.append(style, button, candidateList, fallback);
            document.documentElement.append(host);
        }
        const state = `${count}:${profileAvailable}`;
        if (renderedState !== state) {
            const credentials = count > 0
                ? (chinese ? `${count} 个匹配密码` : `${count} matching password${count === 1 ? "" : "s"}`)
                : "";
            const profile = profileAvailable ? (chinese ? "个人资料可填充" : "Personal info available") : "";
            const details = [credentials, profile].filter(Boolean).join(" · ");
            button.textContent = `UPasswords · ${details}`;
            fallback.hidden = true;
            renderedState = state;
            console.info("[upw] site hint updated");
        }
        reposition();
    }

    function hideCandidates() {
        candidateSequence++;
        focusedUsername = null;
        if (!candidateList) return;
        candidateList.replaceChildren();
        candidateList.hidden = true;
        position = "";
        reposition();
    }

    async function loadCandidates(field) {
        const request = ++candidateSequence;
        focusedUsername = field;
        try {
            const response = await api.runtime.sendMessage({ type: "site-candidates" });
            const current = loginFields();
            if (request !== candidateSequence || focusedUsername !== field
                || (current?.username !== field && current?.password !== field)
                || response?.type !== "site-candidates" || !Array.isArray(response.candidates)
                || !host || !candidateList) return;
            candidateList.replaceChildren();
            const candidates = response.candidates.filter((candidate) => candidate
                && typeof candidate.id === "string" && typeof candidate.title === "string"
                && typeof candidate.username === "string").slice(0, 8);
            for (const candidate of candidates) {
                const option = document.createElement("button");
                option.type = "button";
                option.setAttribute("role", "option");
                option.textContent = candidate.username
                    ? `${candidate.title} · ${candidate.username}` : candidate.title;
                option.addEventListener("keydown", (event) => {
                    const options = Array.from(candidateList.children);
                    const index = options.indexOf(option);
                    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                        event.preventDefault();
                        options[index + (event.key === "ArrowDown" ? 1 : -1)]?.focus();
                    } else if (event.key === "Escape") {
                        event.preventDefault();
                        dismissedUsername = field;
                        hideCandidates();
                        field.focus();
                    }
                });
                option.addEventListener("pointerdown", (event) => event.preventDefault());
                option.addEventListener("click", async (event) => {
                    if (!event.isTrusted) return;
                    if (location.protocol === "http:" && !window.confirm(chinese
                        ? "此页面使用不安全的 HTTP 连接。仍要填充密码吗？"
                        : "This page uses an insecure HTTP connection. Fill the password anyway?")) return;
                    option.disabled = true;
                    try {
                        const result = await api.runtime.sendMessage({
                            type: "select-site-item",
                            itemID: candidate.id,
                        });
                        const current = loginFields();
                        if (result?.type === "site-fill-candidate" && result.expectedOrigin === location.origin
                            && current && (current.username === focusedUsername || current.password === focusedUsername)) {
                            const usernameFilled = setField(current.username, result.username);
                            const passwordFilled = setField(current.password, result.password);
                            if (usernameFilled || passwordFilled) {
                                console.info("[upw] selected account filled");
                                removeHint();
                                return;
                            }
                        }
                        if (result?.type === "site-fill-rejected") {
                            fallback.textContent = result.reason === "conflict"
                                ? (chinese ? "此账号有待处理的同步冲突，请先在 UPasswords 中处理。" : "This account has unresolved sync conflicts. Resolve them in UPasswords first.")
                                : result.reason === "conflicts_unavailable"
                                    ? (chinese ? "无法确认账号同步状态，请打开 UPasswords 并联网刷新。" : "Account sync status could not be checked. Open UPasswords and refresh while online.")
                                    : (chinese ? "无法填充此账号，请打开 UPasswords 查看状态。" : "This account could not be filled. Open UPasswords to check its status.");
                            fallback.hidden = false;
                            option.disabled = false;
                            return;
                        }
                    } catch {
                        console.warn("[upw] site candidate selection unavailable");
                    }
                    option.disabled = false;
                    if (fallback) {
                        fallback.textContent = chinese
                            ? "无法打开填充会话。请点击工具栏中的 UPasswords 图标后重试。"
                            : "Could not start the fill session. Click the UPasswords toolbar icon and retry.";
                        fallback.hidden = false;
                    }
                });
                candidateList.append(option);
            }
            candidateList.hidden = candidates.length === 0;
            anchor = field;
            position = "";
            reposition();
        } catch {
            if (request === candidateSequence) hideCandidates();
        }
    }

    async function refresh() {
        const request = ++sequence;
        const href = location.href;
        if (pageHref !== href) {
            pageHref = href;
            removeHint();
            reportLocation();
        }
        const fields = loginFields();
        const registration = registrationFields();
        if (!fields && !registration) {
            removeHint();
            return;
        }
        try {
            const response = await api.runtime.sendMessage({ type: "site-hint", registration: Boolean(registration) });
            if (request !== sequence || href !== location.href) return;
            const current = loginFields();
            const currentRegistration = registrationFields();
            if ((!current && !currentRegistration) || response?.type !== "site-hint" || !response.unlocked
                || !Number.isSafeInteger(response.count)
                || (response.count <= 0 && !(currentRegistration && response.profileAvailable))) {
                removeHint();
                return;
            }
            const activeAnchor = focusedUsername && current?.username === focusedUsername
                ? focusedUsername : currentRegistration?.anchor ?? current?.anchor;
            showHint(response.count, activeAnchor, Boolean(response.profileAvailable));
        } catch {
            if (request === sequence) removeHint();
        }
    }

    function schedule() {
        clearTimeout(debounce);
        debounce = setTimeout(() => { void refresh(); }, DEBOUNCE_MS);
    }

    function reportLocation() {
        try {
            Promise.resolve(api.runtime.sendMessage({ type: "location", href: location.href })).catch(() => undefined);
        } catch { /* Extension reload invalidates this content context. */ }
    }

    function setField(field, value, onlyEmpty = false) {
        if (!field || typeof value !== "string" || !value || !isVisible(field)
            || (onlyEmpty && field.value)) return false;
        const prototype = field.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (!setter) return false;
        setter.call(field, value);
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
    }

    api.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (message?.type === "registration-check") {
            sendResponse(Boolean(registrationFields()));
            return false;
        }
        if (message?.type !== "fill") return false;
        const trusted = sender?.id === api.runtime.id && sender.url === popupURL && sender.tab == null
            && message.expectedOrigin === location.origin;
        if (!trusted || !message.candidate) {
            sendResponse({ type: "filled", ok: false });
            return false;
        }
        const profile = message.candidate.item?.recordType === "userProfile";
        let ok = false;
        if (profile && message.candidate.item.autofillEnabled !== false) {
            const registration = registrationFields();
            if (registration && Array.isArray(message.candidate.item.fields)) {
                const values = new Map(message.candidate.item.fields
                    .filter((field) => profileTokens.has(field.autofill) && typeof field.value === "string")
                    .map((field) => [field.autofill, field.value]));
                if (!values.has("street-address")) {
                    const address = [values.get("address-line1"), values.get("address-line2")]
                        .filter(Boolean).join("\n");
                    if (address) values.set("street-address", address);
                }
                for (const field of registration.fields) {
                    const token = autocompleteToken(field);
                    const value = values.get(token)
                        || (token === "address-line1" ? values.get("street-address")?.split(/\r?\n/)[0] : "");
                    if (setField(field, value, true)) ok = true;
                }
            }
        } else if (!profile) {
            const fields = loginFields();
            const usernameFilled = setField(fields?.username, message.candidate.username);
            const passwordFilled = setField(fields?.password, message.candidate.password);
            ok = usernameFilled || passwordFilled;
        }
        console.info(`[upw] popup fill dispatched, ok=${ok}`);
        sendResponse({ type: "filled", ok });
        return false;
    });

    const observer = new MutationObserver((records) => {
        // The closed shadow root is not observed. Ignore insertion/removal/position of our host too.
        const external = records.some((record) => !ownedHosts.has(record.target)
            && !(record.type === "childList" && [...record.addedNodes, ...record.removedNodes].every((node) => ownedHosts.has(node))));
        if (external) schedule();
    });
    observer.observe(document.documentElement, {
        childList: true, subtree: true, attributes: true,
        attributeFilter: ["type", "autocomplete", "hidden", "style", "class", "disabled", "readonly"],
    });
    document.addEventListener("focusin", (event) => {
        const target = event.target;
        if (host && (target === host || host.contains(target))) return;
        const fields = loginFields();
        if (fields?.username === target || fields?.password === target) {
            focusedUsername = target;
            if (!wiredUsernameFields.has(target)) {
                wiredUsernameFields.add(target);
                target.addEventListener("keydown", (keyEvent) => {
                    if (keyEvent.key !== "ArrowDown" || !candidateList) return;
                    keyEvent.preventDefault();
                    if (candidateList.hidden) {
                        dismissedUsername = null;
                        void loadCandidates(target);
                        return;
                    }
                    candidateList.querySelector("button")?.focus();
                });
            }
            if (dismissedUsername === target) return;
            dismissedUsername = null;
            void refresh().then(() => loadCandidates(target));
        } else if (focusedUsername) {
            hideCandidates();
        }
    });
    document.addEventListener("focusout", (event) => {
        if (event.target === dismissedUsername && event.relatedTarget !== host) dismissedUsername = null;
    });
    window.addEventListener("popstate", schedule);
    window.addEventListener("hashchange", schedule);
    window.addEventListener("pageshow", schedule);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    setInterval(() => { void refresh(); }, POLL_MS);
    reportLocation();
    void refresh();
})();
