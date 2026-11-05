import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const root = new URL("../../", import.meta.url);
const variants = ["chrome", "safari", "edge", "firefox"];
const source = readFileSync(new URL("chrome/src/content.js", root), "utf8");

function fixture({ password = true, autocomplete = "current-password", registration = false, topFrame = true, protocol = "https:", language = "en", confirmHTTP = true } = {}) {
    const callbacks = new Map();
    const messages = [];
    const listeners = [];
    const timers = new Map();
    const intervals = [];
    const allElements = [];
    const observers = [];
    let timerID = 0;
    let hint = { type: "site-hint", count: 2, unlocked: true, profileAvailable: false };
    let candidates = [{ id: "github-item", title: "GitHub", username: "octocat" }];
    let selection = {
        type: "site-fill-candidate",
        expectedOrigin: `${protocol}//example.com`,
        username: "SECRET-user",
        password: "SECRET-password",
    };
    let popup = { type: "vault-opened", ok: false };
    class Element {
        constructor(tag) {
            this.tagName = tag;
            this.type = "";
            this.autocomplete = "";
            this.children = [];
            this.events = new Map();
            this.style = {};
            this.hidden = false;
            this.textContent = "";
            this.parentElement = null;
            this.visible = true;
            this.connected = false;
            allElements.push(this);
        }
        get isConnected() { return this.connected || Boolean(this.parentElement?.isConnected); }
        append(...children) {
            for (const child of children) {
                child.parentElement = this;
                this.children.push(child);
            }
        }
        remove() {
            if (this.parentElement) this.parentElement.children = this.parentElement.children.filter((child) => child !== this);
            this.parentElement = null;
            this.connected = false;
        }
        contains(node) { return this === node || this.children.some((child) => child.contains(node)); }
        closest() { return this.form ?? null; }
        addEventListener(type, listener) { this.events.set(type, listener); }
        dispatchEvent(event) { this.events.get(event.type)?.(event); return true; }
        focus() { this.focused = true; }
        setAttribute(name, value) { this[name] = value; }
        attachShadow(options) { this.shadowOptions = options; this.shadow = new Element("shadow"); return this.shadow; }
        getClientRects() { return this.visible && !this.hidden ? [{}] : []; }
        getBoundingClientRect() { return { left: 80, bottom: 120, width: this.visible ? 200 : 0, height: 25 }; }
        querySelector(selector) {
            if (selector === "button") return this.children.find((child) => child.tagName === "button") ?? null;
            return this.children.find((field) => field.type === "password" || field.autocomplete === "new-password") ?? null;
        }
        replaceChildren(...children) {
            for (const child of this.children) child.parentElement = null;
            this.children = [];
            this.append(...children);
        }
    }
    let nativeSets = 0;
    class Input extends Element {
        constructor(type, autocomplete) {
            super("input");
            this.type = type;
            this.autocomplete = autocomplete;
            this.currentValue = "";
            this.emitted = [];
        }
        get value() { return this.currentValue; }
        set value(value) { nativeSets++; this.currentValue = value; }
        dispatchEvent(event) { this.emitted.push(event.type); return super.dispatchEvent(event); }
    }
    const html = new Element("html");
    html.connected = true;
    html.lang = language;
    const form = new Element("form");
    html.append(form);
    const username = new Input("text", "username");
    username.form = form;
    form.append(username);
    const pass = new Input("password", autocomplete);
    pass.form = form;
    if (password) form.append(pass);
    const givenName = new Input("text", registration ? "given-name" : "");
    const email = new Input("email", registration ? "email" : "");
    givenName.form = form;
    email.form = form;
    if (registration) form.append(givenName, email);
    const document = {
        documentElement: html,
        createElement(tag) { return new Element(tag); },
        querySelectorAll(selector) {
            assert.ok(["input", "input, textarea"].includes(selector));
            return form.children.filter((field) => field.tagName === "input");
        },
        addEventListener(type, listener) { callbacks.set(`document:${type}`, listener); },
    };
    const location = { protocol, origin: `${protocol}//example.com`, href: `${protocol}//example.com/login` };
    const api = {
        runtime: {
            id: "extension-id",
            getURL(path) { return `moz-extension://id/${path}`; },
            onMessage: { addListener(listener) { listeners.push(listener); } },
            async sendMessage(message) {
                messages.push(message);
                if (message.type === "site-hint") return structuredClone(hint);
                if (message.type === "site-candidates") return { type: "site-candidates", candidates: structuredClone(candidates) };
                if (message.type === "select-site-item") return structuredClone(selection);
                if (message.type === "open-vault") return popup;
            },
        },
    };
    const context = {
        browser: api, document, location, navigator: { language }, HTMLInputElement: Input,
        HTMLTextAreaElement: Input,
        Event: class { constructor(type, options) { this.type = type; Object.assign(this, options); } },
        confirm() { return confirmHTTP; },
        console: { info() {}, warn() {} },
        MutationObserver: class {
            constructor(callback) { observers.push(callback); }
            observe() {}
        },
        setTimeout(callback, delay) { const id = ++timerID; timers.set(id, { callback, delay }); return id; },
        clearTimeout(id) { timers.delete(id); },
        setInterval(callback, delay) { intervals.push({ callback, delay }); },
        innerWidth: 1000, innerHeight: 800,
        getComputedStyle() { return { visibility: "visible", opacity: "1", display: "block" }; },
        addEventListener(type, listener) { callbacks.set(type, listener); },
    };
    context.window = context;
    context.top = topFrame ? context : {};
    vm.runInNewContext(source, context);
    const popupSender = { id: "extension-id", url: "moz-extension://id/src/popup.html" };
    const sendFill = (change = {}, sender = popupSender) => {
        let response;
        listeners[0]({ type: "fill", expectedOrigin: location.origin,
            candidate: { username: "SECRET-user", password: "SECRET-password" }, ...change }, sender, (value) => { response = value; });
        return response;
    };
    return {
        api, callbacks, messages, listeners, timers, intervals, observers, html, form, username, pass,
        givenName, email,
        location, popupSender, sendFill,
        get nativeSets() { return nativeSets; },
        get hintHost() { return html.children.find((element) => element !== form); },
        get button() { return allElements.findLast((element) => element.tagName === "button"); },
        get fallback() { return allElements.findLast((element) => element.tagName === "p"); },
        set hint(value) { hint = value; }, set candidates(value) { candidates = value; },
        set selection(value) { selection = value; }, set popup(value) { popup = value; },
        get candidateList() { return allElements.findLast((element) => element.tagName === "div" && element !== html); },
        async flush() {
            const pending = [...timers.values()];
            timers.clear();
            for (const { callback } of pending) callback();
            await settle();
        },
    };
}
const settle = async () => { await new Promise((resolve) => setImmediate(resolve)); };

test("all browser content scripts remain byte-identical", () => {
    for (const browser of variants) assert.equal(readFileSync(new URL(`${browser}/src/content.js`, root), "utf8"), source);
});

test("login page displays only localized count in closed ShadowDOM and never auto-fills", async () => {
    const f = fixture();
    await settle();
    assert.ok(f.hintHost);
    assert.equal(f.hintHost.shadowOptions.mode, "closed");
    assert.equal(f.button.textContent, "UPasswords · 2 matching passwords");
    assert.equal(f.nativeSets, 0);
    assert.equal(f.username.value, "");
    assert.equal(f.pass.value, "");
    assert.ok(!f.callbacks.has("document:upasswords-fill"));
    const text = f.hintHost.shadow.children.map((element) => element.textContent).join(" ");
    assert.doesNotMatch(text, /SECRET|username|title/);
    const zh = fixture({ language: "zh-CN" });
    await settle();
    assert.equal(zh.button.textContent, "UPasswords · 2 个匹配密码");
});

test("frames, non-web URLs, signup and hidden inputs do not show a hint", async () => {
    for (const options of [{ topFrame: false }, { protocol: "file:" }, { autocomplete: "new-password" }]) {
        const f = fixture(options);
        await settle();
        assert.equal(f.hintHost, undefined);
        assert.ok(!f.messages.some((message) => message.type === "site-hint"));
    }
    const f = fixture();
    await settle();
    f.pass.visible = false;
    f.username.visible = false;
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
});

test("username-first login with a hidden password shows account choices only after focus", async () => {
    const f = fixture();
    f.pass.visible = false;
    await settle();
    assert.ok(f.hintHost, "a hidden current-password field must not suppress the GitHub-style login hint");
    assert.equal(f.candidateList.hidden, true);

    f.callbacks.get("document:focusin")({ target: f.username });
    await settle();

    assert.equal(f.candidateList.hidden, false);
    assert.equal(f.candidateList.children.length, 1);
    assert.equal(f.candidateList.children[0].textContent, "GitHub · octocat");
    assert.equal(f.nativeSets, 0);
    assert.ok(f.messages.some((message) => message.type === "site-candidates"));
    let prevented = false;
    f.username.events.get("keydown")({ key: "ArrowDown", preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    assert.equal(f.candidateList.children[0].focused, true);
});

test("signup and unclassified hidden-password forms never show account suggestions", async () => {
    for (const setup of [
        field => { field.pass.autocomplete = "new-password"; },
        field => { field.pass.autocomplete = ""; field.pass.visible = false; },
    ]) {
        const f = fixture();
        setup(f);
        await settle();
        f.callbacks.get("document:focusin")({ target: f.username });
        await settle();

        assert.equal(f.hintHost, undefined);
        assert.ok(!f.messages.some(message => message.type === "site-candidates"));
    }

    const optedOut = fixture();
    optedOut.username.autocomplete = "off";
    await settle();
    optedOut.callbacks.get("document:focusin")({ target: optedOut.username });
    await settle();
    assert.equal(optedOut.candidateList?.hidden, true);
    assert.ok(!optedOut.messages.some(message => message.type === "site-candidates"));
});

test("visible current-password fields also expose matching account choices", async () => {
    const f = fixture();
    await settle();
    f.callbacks.get("document:focusin")({ target: f.pass });
    await settle();

    assert.equal(f.candidateList.hidden, false);
    assert.equal(f.candidateList.children[0].textContent, "GitHub · octocat");
});

test("selecting an account writes only the chosen credentials into the visible login form", async () => {
    const f = fixture();
    f.pass.visible = false;
    await settle();
    f.callbacks.get("document:focusin")({ target: f.username });
    await settle();

    await f.candidateList.children[0].events.get("click")({ isTrusted: true });

    assert.ok(f.messages.some((message) => message.type === "select-site-item" && message.itemID === "github-item"));
    assert.equal(f.hintHost, undefined);
    assert.equal(f.username.value, "SECRET-user");
    assert.equal(f.nativeSets, 1);
});

test("conflict gate rejection explains why the chosen account was not filled", async () => {
    const f = fixture();
    f.pass.visible = false;
    f.selection = { type: "site-fill-rejected", reason: "conflict" };
    await settle();
    f.callbacks.get("document:focusin")({ target: f.username });
    await settle();

    await f.candidateList.children[0].events.get("click")({ isTrusted: true });

    assert.equal(f.hintHost !== undefined, true);
    assert.equal(f.fallback.hidden, false);
    assert.match(f.fallback.textContent, /sync conflicts/i);
    assert.equal(f.nativeSets, 0);
});

test("HTTP fill asks first and does not request credentials when the user cancels", async () => {
    const f = fixture({ protocol: "http:", confirmHTTP: false });
    f.pass.visible = false;
    await settle();
    f.callbacks.get("document:focusin")({ target: f.username });
    await settle();

    await f.candidateList.children[0].events.get("click")({ isTrusted: true });

    assert.equal(f.messages.some((message) => message.type === "select-site-item"), false);
    assert.equal(f.nativeSets, 0);
    assert.equal(f.username.value, "");
});

test("registration form gets a count-only profile hint and fills matching blank fields after a trusted popup action", async () => {
    const f = fixture({ registration: true, password: false });
    f.hint = { type: "site-hint", count: 0, unlocked: true, profileAvailable: true };
    f.intervals[0].callback();
    await settle();
    assert.ok(f.hintHost);
    assert.equal(f.button.textContent, "UPasswords · Personal info available");
    assert.ok(f.messages.some((message) => message.type === "site-hint" && message.registration === true));
    f.email.value = "already-entered@example.com";
    const response = f.sendFill({ candidate: { item: {
        recordType: "userProfile",
        fields: [
            { autofill: "given-name", value: "Taylor" },
            { autofill: "email", value: "profile@example.com" },
        ],
    } } });
    assert.equal(response.ok, true);
    assert.equal(f.givenName.value, "Taylor");
    assert.equal(f.email.value, "already-entered@example.com");
    assert.equal(f.nativeSets, 2);
    const text = f.hintHost.shadow.children.map((element) => element.textContent).join(" ");
    assert.doesNotMatch(text, /Taylor|profile@example/);
});

test("disabled personal information cannot be filled by a popup message", async () => {
    const f = fixture({ registration: true, password: false });
    await settle();
    const response = f.sendFill({ candidate: { username: "profile@example.com", item: {
        recordType: "userProfile",
        autofillEnabled: false,
        fields: [{ autofill: "given-name", value: "Taylor" }],
    } } });
    assert.equal(response.ok, false);
    assert.equal(f.givenName.value, "");
    assert.equal(f.nativeSets, 0);
});

test("registration fields stay within one form and address lines fill a street-address field", async () => {
    const f = fixture({ registration: true, password: false });
    f.givenName.autocomplete = "section-contact shipping street-address";
    await settle();
    const candidate = { item: { recordType: "userProfile", fields: [
        { autofill: "address-line1", value: "1 Main Street" },
        { autofill: "address-line2", value: "Unit 2" },
    ] } };
    assert.equal(f.sendFill({ candidate }).ok, true);
    assert.equal(f.givenName.value, "1 Main Street\nUnit 2");
    f.givenName.currentValue = "";
    f.email.form = { contains(field) { return field === f.email; } };
    f.form.contains = field => field !== f.email;
    assert.equal(f.sendFill({ candidate }).ok, false);
    assert.equal(f.givenName.value, "");
});

test("trusted popup sender and exact origin required; native input setter and events fill visible fields", async () => {
    const f = fixture();
    await settle();
    for (const sender of [
        { ...f.popupSender, id: "other-extension" },
        { ...f.popupSender, url: `${f.popupSender.url}?forged` },
        { ...f.popupSender, url: "https://example.com/login", tab: { id: 1 } },
        { ...f.popupSender, tab: { id: 1 } },
    ]) assert.equal(f.sendFill({}, sender).ok, false);
    assert.equal(f.sendFill({ expectedOrigin: "https://other.example" }).ok, false);
    assert.equal(f.sendFill({ expectedOrigin: undefined }).ok, false);
    assert.equal(f.nativeSets, 0);
    // A framework's own value property must not intercept the native setter.
    Object.defineProperty(f.pass, "value", { get() { return this.currentValue; }, set() { throw new Error("framework setter"); } });
    assert.equal(f.sendFill().ok, true);
    assert.equal(f.nativeSets, 2);
    assert.equal(f.pass.value, "SECRET-password");
    assert.deepEqual(f.pass.emitted, ["input", "change"]);
    f.pass.visible = false;
    f.username.visible = false;
    assert.equal(f.sendFill().ok, false);
    assert.equal(f.nativeSets, 2);
});

test("hint opens only on trusted clicks and falls back to localized toolbar instruction", async () => {
    const f = fixture();
    await settle();
    await f.button.events.get("click")({ isTrusted: false });
    assert.ok(!f.messages.some((message) => message.type === "open-vault"));
    await f.button.events.get("click")({ isTrusted: true });
    assert.equal(f.messages.filter((message) => message.type === "open-vault").length, 1);
    assert.equal(f.fallback.hidden, false);
    assert.match(f.fallback.textContent, /browser toolbar/);
    const zh = fixture({ language: "zh-Hans" });
    await settle();
    await zh.button.events.get("click")({ isTrusted: true });
    assert.match(zh.fallback.textContent, /工具栏/);
});

test("polling removes hints on lock and zero count without touch or secret requests", async () => {
    const f = fixture();
    await settle();
    assert.equal(f.intervals[0].delay, 30_000);
    f.hint = { type: "site-hint", count: 0, unlocked: false };
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
    f.hint = { type: "site-hint", count: 0, unlocked: true };
    f.intervals[0].callback();
    await settle();
    assert.equal(f.hintHost, undefined);
    assert.ok(f.messages.every((message) => ["location", "site-hint"].includes(message.type)));
});

test("dynamic forms debounce refresh; own host mutations do not loop; SPA route is re-reported", async () => {
    const f = fixture();
    await settle();
    const host = f.hintHost;
    f.observers[0]([{ type: "childList", target: f.html, addedNodes: [host], removedNodes: [] }]);
    f.observers[0]([{ type: "attributes", target: host }]);
    assert.equal(f.timers.size, 0);
    f.form.children = [];
    f.observers[0]([{ type: "childList", target: f.form, addedNodes: [], removedNodes: [f.pass] }]);
    assert.equal(f.timers.size, 1);
    await f.flush();
    assert.equal(f.hintHost, undefined);
    f.observers[0]([{ type: "childList", target: f.html, addedNodes: [], removedNodes: [host] }]);
    assert.equal(f.timers.size, 0);
    f.form.append(f.username, f.pass);
    f.observers[0]([{ type: "childList", target: f.form, addedNodes: [f.pass], removedNodes: [] }]);
    await f.flush();
    assert.ok(f.hintHost);
    f.location.href = "https://example.com/another-login";
    f.callbacks.get("popstate")();
    await f.flush();
    assert.equal(f.messages.filter((message) => message.type === "location").at(-1).href, f.location.href);
    assert.equal(f.nativeSets, 0);
});
