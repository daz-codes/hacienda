import {afterEach, beforeEach, expect, test} from "vitest";
import helium, {heliumTeardown} from "../../lib/lunula/assets/helium-csp.js";

beforeEach(() => {
  document.body.innerHTML = `
    <div data-helium @data="{ menuOpen: false }">
      <button type="button" @click="menuOpen = !menuOpen">Menu</button>
      <nav @visible="menuOpen">Links</nav>
    </div>
  `;
});

afterEach(() => heliumTeardown());

test("the CSP-safe Helium build binds the generated menu directives", async () => {
  await helium();
  const menu = document.querySelector("nav");

  expect(menu.hidden).toBe(true);
  document.querySelector("button").click();
  expect(menu.hidden).toBe(false);
  document.querySelector("button").click();
  expect(menu.hidden).toBe(true);
});

test("an init disposer runs when its element is removed", async () => {
  let cleaned = false;
  document.body.innerHTML = `
    <div data-helium>
      <section @init="startClock()"></section>
    </div>
  `;

  await helium({startClock: () => () => { cleaned = true; }});
  document.querySelector("section").remove();
  await new Promise(resolve => setTimeout(resolve, 0));

  expect(cleaned).toBe(true);
});
