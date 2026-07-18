import {afterEach, beforeEach, describe, expect, test, vi} from "vitest";
import {Morpheus} from "../src/morpheus.js";

const page = (name, options = {}) => `
  <div id="morpheus-page" data-morpheus-page>
    <a id="destination" href="${name === "home" ? "/next" : "/"}">Navigate</a>
    <p>${name}</p>
    <aside id="permanent" data-morpheus-permanent>${options.permanent || "keep"}</aside>
    <section id="reactive" data-helium @data="{page: '${name}'}"></section>
  </div>
`;

const response = (name, options = {}) => new Response(page(name, options), {
  status: options.status || 200,
  headers: {
    "content-type": "text/html; charset=utf-8",
    "x-morpheus-navigation": options.navigation || "morph",
    "x-morpheus-title": name === "next" ? "Next" : "Home",
    "x-morpheus-prefetch-cache": options.cache || "store"
  }
});

const settle = (milliseconds = 0) => new Promise(resolve => setTimeout(resolve, milliseconds));

describe("Morpheus", () => {
  let navigation;

  beforeEach(() => {
    document.head.innerHTML = "<title>Home</title>";
    document.body.innerHTML = `<header id="layout">Layout</header>${page("home")}`;
    history.replaceState({}, "", "/");
    window.scrollTo = vi.fn();
    HTMLElement.prototype.scrollIntoView = vi.fn();
    HTMLElement.prototype.focus = function focus() {
      Object.defineProperty(document, "activeElement", {configurable: true, value: this});
    };
    navigation = new Morpheus({cacheSize: 2, cacheTTL: 15});
  });

  afterEach(() => navigation.stop());

  test("prefetches on intent, morphs one target, and restores history", async () => {
    const requests = [];
    globalThis.fetch = vi.fn(async (url, options) => {
      requests.push({url: String(url), options});
      return String(url).endsWith("/next") ? response("next", {permanent: "replace"}) : response("home");
    });

    const layout = document.querySelector("#layout");
    const permanent = document.querySelector("#permanent");
    const reactive = document.querySelector("#reactive");
    let observerFinished = false;
    const observer = new MutationObserver(() => { observerFinished = true; });
    observer.observe(document.querySelector("#morpheus-page"), {childList: true, subtree: true});
    const loads = [];
    document.addEventListener("morpheus:load", event => loads.push({detail: event.detail, observerFinished}), {once: false});

    navigation.start();
    await settle();
    const link = document.querySelector("#destination");
    link.dispatchEvent(new MouseEvent("mouseover", {bubbles: true}));
    await settle(90);
    link.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, button: 0}));
    await settle(30);

    expect(requests).toHaveLength(1);
    expect(requests[0].options.headers["X-Morpheus-Prefetch"]).toBe("true");
    expect(document.querySelector("#layout")).toBe(layout);
    expect(document.querySelector("#permanent")).toBe(permanent);
    expect(permanent.textContent).toBe("keep");
    expect(document.querySelector("#reactive")).not.toBe(reactive);
    expect(document.querySelector("#reactive").getAttribute("@data")).toContain("next");
    expect(document.title).toBe("Next");
    expect(location.pathname).toBe("/next");
    expect(document.activeElement).toBe(document.querySelector("#morpheus-page"));
    expect(loads.at(-1).detail.prefetched).toBe(true);
    expect(loads.at(-1).observerFinished).toBe(true);

    history.replaceState({morpheus: {scroll: {x: 4, y: 12}}}, "", "/");
    window.dispatchEvent(new PopStateEvent("popstate", {state: history.state}));
    await settle(30);

    expect(requests).toHaveLength(2);
    expect(document.title).toBe("Home");
    expect(document.querySelector("#morpheus-page").textContent).toContain("home");
    expect(window.scrollTo).toHaveBeenLastCalledWith(4, 12);
    observer.disconnect();
  });

  test("bounds and invalidates the prefetch cache", async () => {
    globalThis.fetch = vi.fn(async url => response(new URL(url).pathname.slice(1) || "home"));

    await navigation.prefetch("/one");
    await navigation.prefetch("/two");
    await navigation.prefetch("/three");

    expect(navigation.cache.size).toBe(2);
    expect(navigation.cache.has("http://localhost:3000/one")).toBe(false);
    document.dispatchEvent(new CustomEvent("morpheus:invalidate"));
    expect(navigation.cache.size).toBe(2);

    navigation.start();
    document.dispatchEvent(new CustomEvent("morpheus:invalidate"));
    expect(navigation.cache.size).toBe(0);
  });

  test("falls back for non-navigable responses and respects link opt-outs", async () => {
    document.body.innerHTML = `${page("home")}<div data-morpheus="off"><a id="native" href="/native">Native</a></div>`;
    globalThis.fetch = vi.fn(async () => response("next", {status: 500}));
    navigation.fullLoad = vi.fn();
    navigation.start();

    document.querySelector("#native").addEventListener("click", event => event.preventDefault(), {once: true});
    document.querySelector("#native").dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, button: 0}));
    expect(globalThis.fetch).not.toHaveBeenCalled();

    await navigation.navigate("/broken", {historyMode: "push", navigationType: "link"});
    expect(navigation.fullLoad).toHaveBeenCalledWith("/broken", false);
  });

  test("normalizes cache keys and rejects cross-origin URLs", () => {
    expect(navigation.cacheKey("/posts#comments")).toBe("http://localhost:3000/posts");
    expect(navigation.eligibleURL(new URL("https://example.com/posts"))).toBe(false);
    expect(navigation.eligibleURL(new URL("/posts", location.href))).toBe(true);
  });
});
