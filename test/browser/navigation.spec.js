import {expect, test} from "@playwright/test";

test("prefetches, morphs, preserves state, and handles browser history", async ({page}) => {
  await page.addInitScript(() => {
    window.haciendaEvents = [];
    document.addEventListener("hacienda:load", event => window.haciendaEvents.push(event.detail.navigationType));
  });
  await page.goto("/");
  await page.locator("#layout").evaluate(node => { node.dataset.identity = "preserved"; });
  await page.locator("#destination").hover();
  await expect.poll(async () => (await (await page.request.get("/requests")).json())["/next"]).toBe(1);
  await page.locator("#destination").click();

  await expect(page).toHaveURL(/\/next$/);
  await expect(page).toHaveTitle("next");
  await expect(page.locator("#layout")).toHaveAttribute("data-identity", "preserved");
  await expect(page.locator("#permanent")).toHaveText("keep");
  await expect(page.locator("#reactive")).toHaveAttribute("@data", /next/);
  await expect.poll(async () => (await (await page.request.get("/requests")).json())["/next"]).toBe(1);
  await expect.poll(() => page.evaluate(() => document.activeElement?.id)).toBe("hacienda-page");

  await page.goBack();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator("h1")).toHaveText("home");
  await expect.poll(() => page.evaluate(() => window.haciendaEvents.includes("popstate"))).toBe(true);
});

test("falls back to a full load for a non-2xx response", async ({page}) => {
  await page.goto("/");
  await page.locator("#broken").click();

  await expect(page).toHaveURL(/\/broken$/);
  await expect(page.locator("body")).toContainText("Full-load fallback");
});
