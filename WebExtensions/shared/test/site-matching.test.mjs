import assert from "node:assert/strict";
import { test } from "node:test";
import { itemMatchesPage, parseSiteAssociation, siteAssociationMatches } from "../dist/index.js";

test("domain matching includes subdomains but not lookalike suffixes", () => {
    const association = { url: "https://example.com/login", mode: "domain" };
    assert.equal(siteAssociationMatches("https://login.example.com/anything", association), true);
    assert.equal(siteAssociationMatches("https://example.com.evil.test/", association), false);
    assert.equal(siteAssociationMatches("file://example.com/", association), false);
});

test("wildcard matching matches explicit URL patterns only", () => {
    const association = { url: "https://*.example.com/*", mode: "wildcard" };
    assert.equal(siteAssociationMatches("https://login.example.com/sign-in", association), true);
    assert.equal(siteAssociationMatches("http://login.example.com/sign-in", association), false);
    assert.equal(siteAssociationMatches("https://example.com/sign-in", association), false);
    assert.equal(siteAssociationMatches("https://login.example.com.evil.test/sign-in", association), false);
});

test("exact URL matching normalizes equivalent HTTP URLs and includes path", () => {
    const association = { url: "https://example.com/login", mode: "exactURL" };
    assert.equal(siteAssociationMatches("https://EXAMPLE.com/login", association), true);
    assert.equal(siteAssociationMatches("https://example.com/other", association), false);
    assert.equal(siteAssociationMatches("https://example.com/login?next=1", association), false);
});

test("base-domain matching is scoped to the registrable domain", () => {
    const association = { url: "https://accounts.example.co.uk/login", mode: "domain" };
    assert.equal(siteAssociationMatches("https://example.co.uk/other", association), true);
    assert.equal(siteAssociationMatches("https://login.example.co.uk/", association), true);
    assert.equal(siteAssociationMatches("https://example.com/", association), false);
    assert.equal(siteAssociationMatches("https://attacker.co.uk/", association), false);
});

test("host matching compares exact hostname and port but ignores scheme", () => {
    const association = { url: "https://login.example.com:8443/path", mode: "host" };
    assert.equal(siteAssociationMatches("http://login.example.com:8443/", association), true);
    assert.equal(siteAssociationMatches("https://login.example.com/", association), false);
    assert.equal(siteAssociationMatches("https://www.login.example.com:8443/", association), false);
});

test("starts-with matching uses the normalized saved URL prefix", () => {
    const association = { url: "example.com/login/", mode: "startsWith" };
    assert.equal(siteAssociationMatches("https://example.com/login/two?next=1", association), true);
    assert.equal(siteAssociationMatches("https://example.com/logins/", association), false);
    assert.equal(siteAssociationMatches("https://example.com/other", association), false);
});

test("regular-expression matching is bounded, and never rules never match", () => {
    const regex = { url: "^https://(?:www\\.)?example\\.com/(?:login|signin)", mode: "regex" };
    assert.equal(siteAssociationMatches("https://www.example.com/login?next=1", regex), true);
    assert.equal(siteAssociationMatches("https://example.com/register", regex), false);
    assert.equal(siteAssociationMatches("https://example.com/", {
        url: "https://example.com", mode: "never",
    }), false);
    assert.equal(parseSiteAssociation({ url: "(a+)+$", mode: "regex" }), null);
    assert.equal(parseSiteAssociation({ url: "^https://.*example\\.com/.*$", mode: "regex" }), null);
    assert.equal(parseSiteAssociation({ url: "[", mode: "regex" }), null);
});

test("legacy wildcard associations remain available alongside explicit modes", () => {
    const association = { url: "https://*.example.com/*", mode: "wildcard" };
    assert.equal(siteAssociationMatches("https://login.example.com/sign-in", association), true);
    assert.equal(siteAssociationMatches("https://example.com/sign-in", association), false);
});

test("legacy single website uses domain mode and invalid associations fail closed", () => {
    assert.equal(itemMatchesPage("https://a.example.com/login", { host: "example.com" }), true);
    assert.equal(itemMatchesPage("https://example.org/", { host: "example.com", sites: [] }), false);
    assert.equal(parseSiteAssociation({ url: "javascript:alert(1)", mode: "domain" }), null);
    assert.equal(parseSiteAssociation({ url: "https://example.com/*", mode: "exactURL" }), null);
});
