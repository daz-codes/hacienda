import {createReadStream} from "node:fs";
import {createServer} from "node:http";
import {fileURLToPath} from "node:url";
import {dirname, join} from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const requests = new Map();

const page = name => `<div id="hacienda-page" data-hacienda-page>
  <a id="destination" href="${name === "home" ? "/next" : "/"}">Navigate</a>
  <a id="broken" href="/broken">Broken</a>
  <h1>${name}</h1>
  <aside id="permanent" data-hacienda-permanent>keep</aside>
  <section id="reactive" data-helium @data="{page: '${name}'}"></section>
</div>`;

const document = name => `<!doctype html><html><head><title>${name}</title></head><body>
  <header id="layout">Layout</header>${page(name)}
  <script type="module" src="/assets/hacienda-navigation.js" data-hacienda-navigation data-prefetch="intent" data-cache-size="2" data-cache-ttl="15"></script>
</body></html>`;

createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1:5161");
  requests.set(url.pathname, (requests.get(url.pathname) || 0) + 1);

  if (url.pathname === "/assets/hacienda-navigation.js" || url.pathname === "/assets/idiomorph.esm.js") {
    response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"});
    createReadStream(join(root, "lib/hacienda/assets", url.pathname.split("/").at(-1))).pipe(response);
    return;
  }
  if (url.pathname === "/requests") {
    response.writeHead(200, {"content-type": "application/json"});
    response.end(JSON.stringify(Object.fromEntries(requests)));
    return;
  }
  if (url.pathname === "/broken") {
    response.writeHead(500, {"content-type": "text/html; charset=utf-8"});
    response.end("<!doctype html><title>Failure</title><p>Full-load fallback</p>");
    return;
  }

  const name = url.pathname === "/next" ? "next" : "home";
  if (request.headers["x-hacienda-navigation"] === "true") {
    response.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "x-hacienda-navigation": "morph",
      "x-hacienda-title": name,
      "x-hacienda-prefetch-cache": "store"
    });
    response.end(page(name));
  } else {
    response.writeHead(200, {"content-type": "text/html; charset=utf-8"});
    response.end(document(name));
  }
}).listen(5161, "127.0.0.1");
